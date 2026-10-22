import Foundation

/// SmartThings through its REST API, with either a personal access token (those made after Dec 2024 last 24 h, so
/// only good for trying it out) or an OAuth integration whose refresh token turns over at every use.
public actor SmartThingsClient: DeviceProvider {
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
    private var accessToken: String?
    private var accessExpires = Date.distantPast

    public init(
        credentials: Credentials, transport: @escaping HTTPTransport = defaultTransport,
        now: @escaping @Sendable () -> Date = Date.init, saveRefreshToken: @escaping @Sendable (String) -> Void = { _ in }
    ) {
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
        var out: [HomeDevice] = []
        for item in items {
            guard var device = Self.device(from: item) else { continue }
            do {
                let status = try await get(Self.api.appendingPathComponent("devices/\(device.rawID)/components/main/status"))
                device = Self.applyStatus(status, to: device)
                // Switched off isn't offline: whether the device is reachable is its health, read on its own.
                let health = try? await get(Self.api.appendingPathComponent("devices/\(device.rawID)/health"))
                if Self.isOffline(health: health) { device.isOnline = false }
            } catch let error as ProviderError where error == .unauthorized {
                throw error
            } catch {
                device.isOnline = false
            }
            out.append(device)
        }
        return out
    }

    /// The main component's capabilities decide the kind; devices with nothing to show or change are skipped.
    static func device(from json: JSONValue) -> HomeDevice? {
        let main = json["components"]?.array?.first { $0["id"]?.string == "main" }
        let capabilities = Set(main?["capabilities"]?.array?.compactMap { $0["id"]?.string } ?? [])
        let hasSwitch = capabilities.contains("switch")
        let hasTemperature = capabilities.contains("temperatureMeasurement")
        let laundry = capabilities.contains("washerOperatingState") || capabilities.contains("dryerOperatingState")
        guard hasSwitch || hasTemperature || laundry else { return nil }
        // OCF says what the thing is ("oic.d.tv", "oic.d.networkaudio"); capabilities fill in when it doesn't.
        let ocf = json["ocf"]?["ocfDeviceType"]?.string ?? ""
        let kind: DeviceKind = ocf == "oic.d.tv" || capabilities.contains("tvChannel") ? .tv
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
        for capability in ["washerOperatingState", "dryerOperatingState"] {
            if let machine = status[capability]?["machineState"]?["value"]?.string { parts.append(HomeText.cycle(machine)) }
        }
        if let temperature = status["temperatureMeasurement"]?["temperature"]?["value"]?.double {
            parts.append("\(Int(temperature.rounded()))°")
        }
        if status["healthCheck"]?["DeviceWatch-DeviceStatus"]?["value"]?.string == "offline" { device.isOnline = false }
        device.detail = parts.joined(separator: " · ")
        return device
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
            return ["component": "main", "capability": "switch", "command": .string(on ? "on" : "off")]
        case .brightness(let level):
            guard device.controls["level"] != nil else { throw ProviderError.unsupported }
            let percent = (min(max(level, 0.01), 1) * 100).rounded()
            return ["component": "main", "capability": "switchLevel", "command": "setLevel", "arguments": [.number(percent)]]
        case .color(let color):
            guard device.controls["color"] != nil else { throw ProviderError.unsupported }
            let value: JSONValue = ["hue": .number((color.hue / 3.6).rounded()), "saturation": .number((color.saturation * 100).rounded())]
            return ["component": "main", "capability": "colorControl", "command": "setColor", "arguments": [value]]
        }
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
        case .oauth(let clientID, let secret, let refreshToken):
            if let accessToken, now() < accessExpires { return accessToken }
            var lastError = ProviderError.api("SmartThings: sem resposta")
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
