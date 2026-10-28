import Foundation

/// SmartThings through its REST API, with either a personal access token (those made after Dec 2024 last 24 h, so
/// only good for trying it out) or an OAuth integration whose refresh token turns over at every use.
public actor SmartThingsClient: TVRemoteProvider {
    public nonisolated let provider = Provider.smartThings

    public enum Credentials: Sendable, Equatable {
        case personalToken(String)
        case oauth(clientID: String, secret: String, refreshToken: String)
    }

    static let api = URL(string: "https://api.smartthings.com/v1")!
    /// Where refresh tokens are exchanged: the documented API host first, then the older global auth host
    /// (accounts differ in which one answers).
    static let authHosts = [
        URL(string: "https://api.smartthings.com/oauth/token")!,
        URL(string: "https://auth-global.api.smartthings.com/oauth/token")!,
    ]

    private var credentials: Credentials
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    /// The old refresh token stops working as soon as a new one is issued, so it must be saved right away.
    private let saveRefreshToken: @Sendable (String) -> Void
    /// The refresh token as saved now: another process (a widget) may have renewed it since this client read it.
    private let loadRefreshToken: @Sendable () -> String?
    private var accessToken: String?
    private var accessExpires = Date.distantPast

    public init(
        credentials: Credentials, transport: @escaping HTTPTransport = defaultTransport,
        now: @escaping @Sendable () -> Date = Date.init, saveRefreshToken: @escaping @Sendable (String) -> Void = { _ in },
        loadRefreshToken: @escaping @Sendable () -> String? = { nil }
    ) {
        self.loadRefreshToken = loadRefreshToken
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.saveRefreshToken = saveRefreshToken
    }

    // MARK: Devices

    public func devices() async throws -> [HomeDevice] {
        var items: [JSONValue] = []
        var next: URL? = Self.api.appendingPathComponent("devices")
        for _ in 0..<5 {
            guard let url = next else { break }
            let page = try await get(url)
            items += page["items"]?.array ?? []
            next = page["_links"]?["next"]?["href"]?.string.flatMap(URL.init(string:))
        }
        // Every device at once, and each one's status and health together.
        return try await items.compactMap(Self.device(from:)).concurrentMap { device in
            var device = device
            let path = "devices/\(device.rawID)"
            do {
                async let status = self.get(Self.api.appendingPathComponent("\(path)/components/main/status"))
                // Switched off isn't offline: whether the device is reachable is its health, read on its own.
                async let health = try? self.get(Self.api.appendingPathComponent("\(path)/health"))
                device = Self.applyStatus(try await status, to: device)
                if Self.isOffline(health: await health) { device.isOnline = false }
            } catch let error as ProviderError where error == .unauthorized {
                throw error
            } catch {
                device.isOnline = false
            }
            return device
        }
    }

    /// The main component's capabilities decide the kind; devices with nothing to show or change are skipped.
    static func device(from json: JSONValue) -> HomeDevice? {
        let main = json["components"]?.array?.first { $0["id"]?.string == "main" }
        let capabilities = Set(main?["capabilities"]?.array?.compactMap { $0["id"]?.string } ?? [])
        let hasSwitch = capabilities.contains("switch")
        let hasTemperature = capabilities.contains("temperatureMeasurement")
        let laundry = capabilities.contains("washerOperatingState") || capabilities.contains("dryerOperatingState")
        let vacuum = capabilities.contains("robotCleanerMovement")
        let lock = capabilities.contains("lock")
        guard hasSwitch || hasTemperature || laundry || vacuum || lock else { return nil }
        // OCF says what the thing is ("oic.d.tv", "oic.d.networkaudio"); capabilities fill in when it doesn't.
        let ocf = json["ocf"]?["ocfDeviceType"]?.string ?? ""
        let kind: DeviceKind = vacuum ? .vacuum
            : lock ? .lock
            : ocf == "oic.d.tv" || capabilities.contains("tvChannel") ? .tv
            : ocf == "oic.d.networkaudio" || ocf == "oic.d.speaker"
                || (capabilities.contains("audioVolume") && capabilities.contains("mediaPlayback")) ? .speaker
            : laundry ? .laundry
            : capabilities.contains("airConditionerMode") ? .airConditioner
            : capabilities.contains("refrigeration") ? .kitchen
            : capabilities.contains("colorControl") || capabilities.contains("switchLevel")
                || capabilities.contains("colorTemperature") ? .light
            : capabilities.contains("fanSpeed") ? .fan
            : hasSwitch ? .plug : .climateSensor
        let id = json["deviceId"]?.string ?? ""
        var device = HomeDevice(
            provider: .smartThings, rawID: id, name: json["label"]?.string ?? json["name"]?.string ?? id, kind: kind
        )
        if capabilities.contains("switchLevel") { device.controls["level"] = "1" }
        if capabilities.contains("colorControl") { device.controls["color"] = "1" }
        // A Samsung TV's or soundbar's remote: what each one has.
        for (capability, flag) in Self.remoteCapabilities where capabilities.contains(capability) { device.controls[flag] = "1" }
        return device
    }

    static func applyStatus(_ status: JSONValue, to device: HomeDevice) -> HomeDevice {
        var device = device
        if let value = status["switch"]?["switch"]?["value"]?.string { device.isOn = value == "on" }
        if device.controls["level"] != nil {
            device.brightness = (status["switchLevel"]?["level"]?["value"]?.double ?? 100) / 100
        }
        if device.controls["color"] != nil {
            let hue = status["colorControl"]?["hue"]?["value"]?.double ?? 0
            let saturation = status["colorControl"]?["saturation"]?["value"]?.double ?? 0
            // SmartThings counts hue in percent of the circle.
            device.color = LightColor(hue: hue * 3.6, saturation: saturation / 100)
        }
        var parts: [String] = []
        // A Samsung Jet Bot or another robot: cleaning is on, going home is off.
        if let movement = status["robotCleanerMovement"]?["robotCleanerMovement"]?["value"]?.string {
            device.isOn = movement == "cleaning"
            parts.append(Self.vacuumMovement(movement))
        }
        if device.kind == .lock {
            device.isOn = nil
            if let lock = status["lock"]?["lock"]?["value"]?.string {
                device.controls["locked"] = lock == "locked" ? "1" : "0"
                parts.append(lock == "locked" ? tr("Trancada") : lock == "unlocked" ? tr("Destrancada") : lock)
            }
        }
        if device.kind == .vacuum || device.kind == .lock, let battery = status["battery"]?["battery"]?["value"]?.double {
            parts.append(tr("bateria \(Int(battery))%"))
        }
        for capability in ["washerOperatingState", "dryerOperatingState"] {
            if let machine = status[capability]?["machineState"]?["value"]?.string { parts.append(HomeText.cycle(machine)) }
        }
        if device.kind == .airConditioner {
            // Like LG's: the room, and the set point while it runs (both in °C; Samsung answers in °F in the US).
            let room = Self.celsius(status["temperatureMeasurement"]?["temperature"])
            let target = Self.celsius(status["thermostatCoolingSetpoint"]?["coolingSetpoint"])
            if let room {
                parts.append("Ambiente \(HomeText.degrees(room))")
                device.controls["roomTemperature"] = HomeText.degrees(room)
                device.controls["roomTemperatureValue"] = HomeText.number(room)
            }
            if let target {
                if device.isOn == true { parts.append(tr("ajustado em \(HomeText.degrees(target))")) }
                device.controls["targetTemperature"] = HomeText.number(target)
            }
        } else if let temperature = status["temperatureMeasurement"]?["temperature"]?["value"]?.double {
            parts.append("\(Int(temperature.rounded()))°")
        }
        if device.controls["st.volume"] != nil, let volume = status["audioVolume"]?["volume"]?["value"]?.double {
            let muted = status["audioMute"]?["mute"]?["value"]?.string == "muted"
            device.controls["volume"] = muted ? "0" : String(Int(volume))
            device.controls["maxVolume"] = "100"
        }
        if let playback = status["mediaPlayback"]?["playbackStatus"]?["value"]?.string { device.controls["playback"] = playback }
        if let inputs = status["samsungvd.mediaInputSource"]?["supportedInputSourcesMap"]?["value"]?.array {
            device.controls["inputs"] = inputs.compactMap { $0["id"]?.string }.joined(separator: ",")
            let current = status["samsungvd.mediaInputSource"]?["inputSource"]?["value"]?.string
            device.controls["input"] = current ?? ""
            if device.isOn == true, let name = inputs.first(where: { $0["id"]?.string == current })?["name"]?.string,
               current != "dtv" {
                parts.append(name)
            } else if device.isOn == true, let channel = status["tvChannel"]?["tvChannelName"]?["value"]?.string, !channel.isEmpty {
                parts.append(channel)
            }
        }
        if status["healthCheck"]?["DeviceWatch-DeviceStatus"]?["value"]?.string == "offline" { device.isOnline = false }
        device.detail = parts.joined(separator: " · ")
        return device
    }

    /// SmartThings' robotCleanerMovement values as the list says them.
    static func vacuumMovement(_ movement: String) -> String {
        switch movement {
        case "cleaning": tr("Limpando")
        case "homing": tr("Voltando à base")
        case "charging": tr("Carregando")
        case "idle", "powerOff": tr("Parado")
        case "pause": tr("Pausado")
        case "alarm": tr("Com problema")
        default: movement
        }
    }

    /// An attribute's value in °C ({"value": 75, "unit": "F"} too).
    static func celsius(_ attribute: JSONValue?) -> Double? {
        guard let value = attribute?["value"]?.double else { return nil }
        return attribute?["unit"]?.string == "F" ? ((value - 32) * 5 / 9 * 2).rounded() / 2 : value
    }

    /// `GET devices/{id}/health` answers {"state": "ONLINE" | "OFFLINE"}; no answer leaves the device as it was.
    static func isOffline(health: JSONValue?) -> Bool {
        health?["state"]?.string?.uppercased() == "OFFLINE"
    }

    // MARK: Commands

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        let body: JSONValue = ["commands": .array([try Self.command(for: command, device: device)])]
        _ = try await request("POST", Self.api.appendingPathComponent("devices/\(device.rawID)/commands"), body: body)
    }

    static func command(for command: HomeCommand, device: HomeDevice) throws -> JSONValue {
        switch command {
        case .power(let on):
            if device.kind == .vacuum {
                return ["component": "main", "capability": "robotCleanerMovement", "command": "setRobotCleanerMovement",
                        "arguments": [.string(on ? "cleaning" : "homing")]]
            }
            guard device.kind != .lock else { throw ProviderError.unsupported }
            return ["component": "main", "capability": "switch", "command": .string(on ? "on" : "off")]
        case .brightness(let level):
            guard device.controls["level"] != nil else { throw ProviderError.unsupported }
            let percent = (min(max(level, 0.01), 1) * 100).rounded()
            return ["component": "main", "capability": "switchLevel", "command": "setLevel", "arguments": [.number(percent)]]
        case .color(let color):
            guard device.controls["color"] != nil else { throw ProviderError.unsupported }
            let value: JSONValue = ["hue": .number((color.hue / 3.6).rounded()), "saturation": .number((color.saturation * 100).rounded())]
            return ["component": "main", "capability": "colorControl", "command": "setColor", "arguments": [value]]
        case .temperature(let value):
            guard device.kind == .airConditioner else { throw ProviderError.unsupported }
            return ["component": "main", "capability": "thermostatCoolingSetpoint", "command": "setCoolingSetpoint",
                    "arguments": [.number(value)]]
        }
    }

    // MARK: Remote (Samsung TVs and soundbars)

    static let remoteCapabilities: [(String, String)] = [
        ("samsungvd.remoteControl", "st.keys"), ("custom.launchapp", "st.apps"), ("tvChannel", "st.channel"),
        ("audioVolume", "st.volume"), ("audioMute", "st.mute"), ("mediaPlayback", "st.playback"),
        ("samsungvd.mediaInputSource", "st.inputs"), ("samsungvd.audioInputSource", "st.audioInput"),
    ]

    /// Tizen's ids for the big apps (custom.launchapp opens by id).
    static let tizenApps: [(id: String, name: String)] = [
        ("3201907018807", "Netflix"), ("111299001912", "YouTube"), ("3201910019365", "Prime Video"),
        ("3201901017640", "Disney+"), ("3201807016597", "Apple TV"), ("3201606009684", "Spotify"),
    ]

    public func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {
        try await sendCommand(Self.command(for: key, device: device), to: device)
    }

    /// One remote key as a SmartThings command, by what the device has.
    static func command(for key: AndroidTVProvider.Key, device: HomeDevice) throws -> JSONValue {
        func has(_ flag: String) -> Bool { device.controls[flag] != nil }
        func main(_ capability: String, _ command: String, _ arguments: [JSONValue] = []) -> JSONValue {
            arguments.isEmpty ? ["component": "main", "capability": .string(capability), "command": .string(command)]
                : ["component": "main", "capability": .string(capability), "command": .string(command), "arguments": .array(arguments)]
        }
        switch key {
        case .volumeUp where has("st.volume"): return main("audioVolume", "volumeUp")
        case .volumeDown where has("st.volume"): return main("audioVolume", "volumeDown")
        case .mute where has("st.mute"): return main("audioMute", device.controls["volume"] == "0" ? "unmute" : "mute")
        case .channelUp where has("st.channel"): return main("tvChannel", "channelUp")
        case .channelDown where has("st.channel"): return main("tvChannel", "channelDown")
        case .playPause where has("st.playback"): return main("mediaPlayback", device.controls["playback"] == "playing" ? "pause" : "play")
        case .inputs where has("st.inputs"):
            // The next input in the TV's list.
            let inputs = (device.controls["inputs"] ?? "").split(separator: ",").map(String.init)
            guard !inputs.isEmpty else { throw ProviderError.unsupported }
            let index = inputs.firstIndex(of: device.controls["input"] ?? "") ?? -1
            return main("samsungvd.mediaInputSource", "setInputSource", [.string(inputs[(index + 1) % inputs.count])])
        case .inputs where has("st.audioInput"): return main("samsungvd.audioInputSource", "setNextInputSource")
        case .up, .down, .left, .right, .select, .back, .home:
            guard has("st.keys") else { throw ProviderError.unsupported }
            let names: [AndroidTVProvider.Key: String] = [.up: "UP", .down: "DOWN", .left: "LEFT", .right: "RIGHT",
                                                           .select: "OK", .back: "BACK", .home: "HOME"]
            return main("samsungvd.remoteControl", "send", [.string(names[key]!), "PRESS_AND_RELEASED"])
        default: throw ProviderError.unsupported
        }
    }

    public func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] {
        guard device.controls["st.apps"] != nil else { return [] }
        return Self.tizenApps.map { AndroidTVProvider.App(package: $0.id, name: $0.name) }
    }

    public func openApp(_ package: String, on device: HomeDevice) async throws {
        guard device.controls["st.apps"] != nil else { throw ProviderError.unsupported }
        let name = Self.tizenApps.first { $0.id == package }?.name ?? ""
        try await sendCommand(["component": "main", "capability": "custom.launchapp", "command": "launchApp",
                               "arguments": [.string(package), .string(name)]], to: device)
    }

    /// SmartThings has no text input for TVs.
    public func type(_ text: String, on device: HomeDevice) async throws {
        throw ProviderError.unsupported
    }

    private func sendCommand(_ command: JSONValue, to device: HomeDevice) async throws {
        _ = try await request("POST", Self.api.appendingPathComponent("devices/\(device.rawID)/commands"),
                              body: ["commands": .array([command])])
    }

    /// A valid access token (about 24 h), for a device that may use it but must never renew it (the watch): only
    /// the owner of the refresh token renews, so two devices don't invalidate each other's token.
    public func currentAccessToken() async throws -> String {
        try await token()
    }

    // MARK: HTTP

    private func get(_ url: URL) async throws -> JSONValue {
        try await request("GET", url, body: nil)
    }

    private func request(_ method: String, _ url: URL, body: JSONValue?) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            accessToken = nil
            throw ProviderError.unauthorized
        }
        guard (200..<300).contains(status) else { throw ProviderError.api("SmartThings: HTTP \(status)") }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }

    /// The personal token, or OAuth's access token (24 h), renewed with the newest refresh token near expiry.
    private func token() async throws -> String {
        switch credentials {
        case .personalToken(let token):
            return token
        case .oauth(let clientID, let secret, let saved):
            if let accessToken, now() < accessExpires { return accessToken }
            let refreshToken = loadRefreshToken() ?? saved
            var lastError = ProviderError.api(tr("SmartThings: sem resposta"))
            for host in Self.authHosts {
                do {
                    return try await renew(host: host, clientID: clientID, secret: secret, refreshToken: refreshToken)
                } catch let error as ProviderError where error == .unauthorized {
                    throw error
                } catch let error as ProviderError {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private func renew(host: URL, clientID: String, secret: String, refreshToken: String) async throws -> String {
        var request = URLRequest(url: host)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let access = json["access_token"]?.string
        else { throw status == 400 || status == 401 ? ProviderError.unauthorized : ProviderError.api("SmartThings: HTTP \(status)") }
        if let newRefresh = json["refresh_token"]?.string, newRefresh != refreshToken {
            credentials = .oauth(clientID: clientID, secret: secret, refreshToken: newRefresh)
            saveRefreshToken(newRefresh)
        }
        accessToken = access
        accessExpires = now().addingTimeInterval((json["expires_in"]?.double ?? 86400) - 600)
        return access
    }
}
