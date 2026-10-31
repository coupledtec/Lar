import CryptoKit
import Foundation

/// Smart Life (and every Tuya-made brand moved into it) through a Cloud project on iot.tuya.com, with the app
/// account linked to it. Every call is signed with HMAC-SHA256 using the project's secret and a token that lasts
/// two hours.
public actor TuyaClient: DeviceProvider, LiveVideoProvider {
    public nonisolated let provider = Provider.tuya

    public struct Credentials: Sendable, Equatable {
        public var clientID: String
        public var secret: String
        /// "us" (the Americas, where Brazilian accounts live), "eu", "cn" or "in".
        public var region: String

        public init(clientID: String, secret: String, region: String = HomeRegion.tuyaRegion()) {
            self.clientID = clientID
            self.secret = secret
            self.region = region
        }

        var host: URL {
            let region = region.lowercased()
            return URL(string: "https://openapi.tuya\(["eu", "cn", "in"].contains(region) ? region : "us").com")!
        }
    }

    private let credentials: Credentials
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var token: String?
    private var tokenExpires = Date.distantPast
    /// Each light's brightness and color ranges, read once from its function list.
    private var specs: [String: LightSpec] = [:]

    public init(credentials: Credentials, transport: @escaping HTTPTransport = defaultTransport,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    // MARK: Devices

    public func devices() async throws -> [HomeDevice] {
        var out: [HomeDevice] = []
        var lastRow = ""
        for _ in 0..<5 {
            // The query in alphabetical order: it's part of what gets signed.
            let query = (lastRow.isEmpty ? "" : "last_row_key=\(lastRow)&") + "size=100"
            let result = try await call("GET", "/v1.0/iot-01/associated-users/devices?\(query)")
            // The lights' specifications, all at once.
            out += try await (result["devices"]?.array ?? []).concurrentMap { json in
                let device = Self.device(from: json)
                if device.kind == .light, device.isOnline, let spec = try? await self.spec(for: device.rawID) {
                    return Self.applySpec(spec, to: device, json: json)
                }
                return device
            }
            lastRow = result["last_row_key"]?.string ?? ""
            if result["has_more"]?.bool != true || lastRow.isEmpty { break }
        }
        return out
    }

    static let lightCategories: Set = ["dj", "dd", "fwd", "xdd", "dc", "tgq", "tgkg"]
    static let plugCategories: Set = ["cz", "pc", "kg", "tdq", "qjdcz"]
    static let climateCategories: Set = ["wk", "wsdcg", "wkf"]
    static let fanCategories: Set = ["fs", "fsd", "kj"]
    /// Air conditioners (kt) and their Wi-Fi controllers (ktkzq).
    static let airConditionerCategories: Set = ["kt", "ktkzq"]
    /// Robot vacuums.
    static let vacuumCategories: Set = ["sd"]
    /// Door locks: Wi-Fi (ms, wf_ms), Bluetooth through a hub (jtmspro, jtmsbh), with a camera (videolock, sp_lock).
    static let lockCategories: Set = ["ms", "wf_ms", "jtmspro", "jtmsbh", "gyms", "videolock", "sp_lock"]

    static func device(from json: JSONValue) -> HomeDevice {
        let id = json["id"]?.string ?? ""
        let category = json["category"]?.string ?? ""
        let kind: DeviceKind = category == "sp" ? .camera
            : lightCategories.contains(category) ? .light
            : plugCategories.contains(category) ? .plug
            : airConditionerCategories.contains(category) ? .airConditioner
            : climateCategories.contains(category) ? .climateSensor
            : vacuumCategories.contains(category) ? .vacuum
            : lockCategories.contains(category) ? .lock
            : fanCategories.contains(category) ? .fan : .other
        var device = HomeDevice(
            provider: .tuya, rawID: id, name: json["name"]?.string ?? id, kind: kind,
            isOnline: json["online"]?.bool ?? true
        )
        var temperature: Double?
        var humidity: Double?
        for status in json["status"]?.array ?? [] {
            guard let code = status["code"]?.string else { continue }
            let value = status["value"]
            if device.controls["switch"] == nil, ["switch_led", "switch", "switch_1"].contains(code), let on = value?.bool {
                device.controls["switch"] = code
                device.isOn = on
            }
            if code == "va_temperature", let raw = value?.double { temperature = raw / 10 }
            if code == "va_humidity", let raw = value?.double { humidity = raw }
            if kind == .airConditioner, let raw = value?.double {
                if code == "temp_set" { device.controls["tuyaTarget"] = HomeText.number(raw) }
                if code == "temp_current" || (code == "temp_indoor" && device.controls["tuyaRoom"] == nil) {
                    device.controls["tuyaRoom"] = HomeText.number(raw)
                }
            }
        }
        if kind == .camera { device.isOn = nil }
        if kind == .airConditioner { return airConditioner(device) }
        if kind == .vacuum || kind == .lock {
            let statuses = (json["status"]?.array ?? []).compactMap { status -> (String, JSONValue)? in
                guard let code = status["code"]?.string, let value = status["value"] else { return nil }
                return (code, value)
            }
            // For the Diagnostics report (codes and values only, no names): how this brand reports its state.
            device.controls["tuyaCategory"] = category
            device.controls["tuyaStatus"] = statuses.map { "\($0.0)=\($0.1.string ?? $0.1.bool.map(String.init) ?? $0.1.double.map { HomeText.number($0) } ?? "?")" }
                .joined(separator: ", ")
            return kind == .vacuum ? vacuum(device, statuses: statuses) : lock(device, statuses: statuses, video: category == "videolock" || category == "sp_lock")
        }
        if let temperature {
            device.detail = "\(Int(temperature.rounded()))°" + (humidity.map { " · \(Int($0))%" } ?? "")
            device.controls["temperatureValue"] = HomeText.number(temperature)
        }
        if let humidity { device.controls["humidityValue"] = HomeText.number(humidity) }
        return device
    }

    // MARK: Robot vacuums

    /// Tuya's standard robot vacuum: power_go (cleaning), status, electricity_left (battery), switch_charge (dock).
    static func vacuum(_ device: HomeDevice, statuses: [(String, JSONValue)]) -> HomeDevice {
        var device = device
        let values = Dictionary(statuses, uniquingKeysWith: { first, _ in first })
        let status = values["status"]?.string
        let cleaning = values["power_go"]?.bool ?? status.map { $0.contains("clean") } ?? false
        device.isOn = cleaning
        device.controls["switch"] = "power_go"
        if values["switch_charge"] != nil { device.controls["dock"] = "switch_charge" }
        var parts: [String] = []
        if let status { parts.append(vacuumStatus(status)) } else { parts.append(cleaning ? tr("Limpando") : tr("Parado")) }
        if let battery = values["electricity_left"]?.double ?? values["residual_electricity"]?.double {
            parts.append(tr("bateria \(Int(battery))%"))
        }
        device.detail = parts.joined(separator: " · ")
        return device
    }

    static func vacuumStatus(_ status: String) -> String {
        switch status {
        case "standby", "idle": tr("Parado")
        case "paused", "pause": tr("Pausado")
        case "goto_charge", "docking", "back_charge": tr("Voltando à base")
        case "charging": tr("Carregando")
        case "charge_done", "fully_charged", "chargecompleted": tr("Carregado")
        case "sleep": tr("Em repouso")
        case "fault", "error": tr("Com problema")
        case let other where other.contains("clean"): tr("Limpando")
        default: status
        }
    }

    // MARK: Locks

    /// What's certain from Tuya's lock codes: the door open or closed and the battery. Locked or unlocked comes once
    /// it's confirmed with a real lock (the codes' meaning varies by brand; they're in the Diagnostics report).
    static func lock(_ device: HomeDevice, statuses: [(String, JSONValue)], video: Bool) -> HomeDevice {
        var device = device
        device.isOn = nil
        let values = Dictionary(statuses, uniquingKeysWith: { first, _ in first })
        var parts: [String] = []
        if let door = values["closed_opened"]?.string {
            parts.append(door == "open" ? tr("Porta aberta") : door == "closed" ? tr("Porta fechada") : door)
        }
        if let battery = values["residual_electricity"]?.double ?? values["battery_percentage"]?.double {
            parts.append(tr("bateria \(Int(battery))%"))
        } else if let state = values["battery_state"]?.string {
            parts.append(state == "low" || state == "poweroff" ? tr("bateria fraca") : tr("bateria boa"))
        }
        if video { device.controls["tuyaVideo"] = "1" }
        device.detail = parts.joined(separator: " · ")
        return device
    }

    // MARK: Air conditioners

    /// The set point and the room as °C. Units send whole degrees or tenths ("temp_set": 240): above 50 it's tenths.
    static func airConditioner(_ device: HomeDevice) -> HomeDevice {
        var device = device
        var parts: [String] = []
        if let raw = device.controls["tuyaRoom"].flatMap(Double.init) {
            let room = raw > 50 ? raw / 10 : raw
            parts.append("Ambiente \(HomeText.degrees(room))")
            device.controls["roomTemperature"] = HomeText.degrees(room)
            device.controls["roomTemperatureValue"] = HomeText.number(room)
        }
        if let raw = device.controls["tuyaTarget"].flatMap(Double.init) {
            let tenths = raw > 50
            let target = tenths ? raw / 10 : raw
            if device.isOn == true { parts.append(tr("ajustado em \(HomeText.degrees(target))")) }
            device.controls["targetTemperature"] = HomeText.number(target)
            device.controls["tempScale"] = tenths ? "10" : "1"
        }
        device.detail = parts.joined(separator: " · ")
        return device
    }

    // MARK: Lights

    struct LightSpec: Sendable, Equatable {
        var brightnessCode: String?
        var brightnessRange: ClosedRange<Double> = 10...1000
        var colorCode: String?
        /// colour_data_v2 counts saturation and value to 1000; the old colour_data to 255.
        var colorScale: Double = 1000
    }

    private func spec(for id: String) async throws -> LightSpec {
        if let cached = specs[id] { return cached }
        let result = try await call("GET", "/v1.0/iot-03/devices/\(id)/functions")
        let spec = Self.spec(fromFunctions: result["functions"]?.array ?? [])
        specs[id] = spec
        return spec
    }

    static func spec(fromFunctions functions: [JSONValue]) -> LightSpec {
        var spec = LightSpec()
        for function in functions {
            guard let code = function["code"]?.string else { continue }
            // "values" is JSON inside a string.
            let values = function["values"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            switch code {
            case "bright_value_v2", "bright_value":
                guard spec.brightnessCode != "bright_value_v2" else { continue }
                spec.brightnessCode = code
                if let min = values?["min"]?.double, let max = values?["max"]?.double, min < max {
                    spec.brightnessRange = min...max
                } else {
                    spec.brightnessRange = code == "bright_value" ? 25...255 : 10...1000
                }
            case "colour_data_v2", "colour_data":
                guard spec.colorCode != "colour_data_v2" else { continue }
                spec.colorCode = code
                spec.colorScale = code == "colour_data" ? 255 : 1000
            default: break
            }
        }
        return spec
    }

    /// Fills in brightness and color from the device's status, now that its ranges are known.
    static func applySpec(_ spec: LightSpec, to device: HomeDevice, json: JSONValue) -> HomeDevice {
        var device = device
        var values: [String: JSONValue] = [:]
        for status in json["status"]?.array ?? [] {
            if let code = status["code"]?.string, let value = status["value"] { values[code] = value }
        }
        let mode = values["work_mode"]?.string ?? "white"
        device.controls["mode"] = mode
        if let code = spec.brightnessCode {
            device.controls["bright"] = code
            device.controls["brightMin"] = String(spec.brightnessRange.lowerBound)
            device.controls["brightMax"] = String(spec.brightnessRange.upperBound)
            let raw = values[code]?.double ?? spec.brightnessRange.upperBound
            device.brightness = normalized(raw, in: spec.brightnessRange)
        }
        if let code = spec.colorCode {
            device.controls["colour"] = code
            device.controls["colourScale"] = String(spec.colorScale)
            let color = colorValue(values[code], scale: spec.colorScale)
            device.color = color?.color ?? LightColor(hue: 0, saturation: 0)
            // In color mode the brightness is the color's value, not bright_value.
            if mode == "colour", let value = color?.value { device.brightness = value }
        }
        return device
    }

    static func normalized(_ raw: Double, in range: ClosedRange<Double>) -> Double {
        min(max((raw - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    /// Reads {"h": 0–360, "s": 0–scale, "v": 0–scale}, which the status sends as JSON in a string.
    static func colorValue(_ value: JSONValue?, scale: Double) -> (color: LightColor, value: Double)? {
        var json = value
        if let text = value?.string { json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        guard let hue = json?["h"]?.double, let saturation = json?["s"]?.double else { return nil }
        let value = json?["v"]?.double ?? scale
        return (LightColor(hue: hue, saturation: saturation / scale), value / scale)
    }

    // MARK: Commands

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        let commands = try Self.commands(for: command, device: device)
        let body: JSONValue = ["commands": .array(commands)]
        _ = try await call("POST", "/v1.0/iot-03/devices/\(device.rawID)/commands", body: body)
    }

    static func commands(for command: HomeCommand, device: HomeDevice) throws -> [JSONValue] {
        let controls = device.controls
        switch command {
        case .power(let on):
            // A robot vacuum: off is back to the dock (its own command when it has one).
            if device.kind == .vacuum, !on, let dock = controls["dock"] {
                return [["code": .string(dock), "value": true]]
            }
            guard let code = controls["switch"] else { throw ProviderError.unsupported }
            return [["code": .string(code), "value": .bool(on)]]
        case .brightness(let level):
            // In color mode, brightness is the color's value; otherwise the white brightness.
            if controls["mode"] == "colour", let code = controls["colour"], let color = device.color {
                return [colorCommand(code: code, color: color, value: level, scale: scale(controls))]
            }
            guard let code = controls["bright"] else { throw ProviderError.unsupported }
            let low = Double(controls["brightMin"] ?? "") ?? 10, high = Double(controls["brightMax"] ?? "") ?? 1000
            let raw = (low + (high - low) * min(max(level, 0), 1)).rounded()
            return [["code": .string(code), "value": .number(raw)]]
        case .color(let color):
            guard let code = controls["colour"] else { throw ProviderError.unsupported }
            return [
                ["code": "work_mode", "value": "colour"],
                colorCommand(code: code, color: color, value: device.brightness ?? 1, scale: scale(controls)),
            ]
        case .temperature(let value):
            guard device.kind == .airConditioner, controls["targetTemperature"] != nil else { throw ProviderError.unsupported }
            let scale = Double(controls["tempScale"] ?? "") ?? 1
            return [["code": "temp_set", "value": .number((value * scale).rounded())]]
        }
    }

    private static func scale(_ controls: [String: String]) -> Double {
        Double(controls["colourScale"] ?? "") ?? 1000
    }

    private static func colorCommand(code: String, color: LightColor, value: Double, scale: Double) -> JSONValue {
        let hsv: JSONValue = [
            "h": .number(color.hue.rounded()),
            "s": .number((color.saturation * scale).rounded()),
            "v": .number((max(value, 0.01) * scale).rounded()),
        ]
        return ["code": .string(code), "value": hsv]
    }

    // MARK: Cameras

    public func liveStreamURL(for device: HomeDevice) async throws -> URL {
        let result: JSONValue
        do {
            result = try await call("POST", "/v1.0/devices/\(device.rawID)/stream/actions/allocate", body: ["type": "hls"])
        } catch ProviderError.api(let message) where Self.videoNotSubscribed(message) {
            throw ProviderError.api(Self.videoServiceMessage)
        }
        guard let link = result["url"]?.string, let url = URL(string: link) else {
            throw ProviderError.api(tr("A câmera não mandou o vídeo"))
        }
        return url
    }

    /// "No permissions. This API is not subscribed": the project's video service isn't on (its trial ended or it
    /// was never authorized), though the device list still works.
    static func videoNotSubscribed(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("not subscribed") || text.contains("no permission")
    }

    static var videoServiceMessage: String {
        tr("O vídeo ao vivo não está ativo no seu projeto da Tuya. Em iot.tuya.com → Cloud → o seu projeto → Service API, autorize ou renove o IoT Video Live Stream (grátis para uso pessoal) e tente de novo.")
    }

    // MARK: Signed calls

    /// A signed call with the project's token; a token the cloud dropped is renewed once.
    private func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        for attempt in 0..<2 {
            if token == nil || now() >= tokenExpires {
                let result = try await signed("GET", "/v1.0/token?grant_type=1", body: nil, token: nil)
                guard let access = result["access_token"]?.string else { throw ProviderError.api(tr("Tuya: sem token")) }
                token = access
                let seconds = result["expire_time"]?.double ?? 7200
                tokenExpires = now().addingTimeInterval(seconds - 120)
            }
            do {
                return try await signed(method, path, body: body, token: token)
            } catch TuyaFailure.tokenInvalid where attempt == 0 {
                token = nil
            }
        }
        throw ProviderError.unauthorized
    }

    enum TuyaFailure: Error { case tokenInvalid }

    private func signed(_ method: String, _ path: String, body: JSONValue?, token: String?) async throws -> JSONValue {
        let bodyData = try body.map { try JSONEncoder().encode($0) } ?? Data()
        var request = URLRequest(url: URL(string: credentials.host.absoluteString + path)!)
        request.httpMethod = method
        request.timeoutInterval = 15
        let headers = Self.signatureHeaders(
            method: method, path: path, body: bodyData, credentials: credentials, token: token,
            timestamp: String(Int64(now().timeIntervalSince1970 * 1000)), nonce: UUID().uuidString.lowercased()
        )
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        let data: Data
        do {
            (data, _) = try await transport(request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ProviderError.api(tr("Resposta inesperada da Tuya"))
        }
        guard json["success"]?.bool == true else {
            let code = Int(json["code"]?.double ?? 0)
            let message = json["msg"]?.string ?? "Erro \(code)"
            if token != nil, code == 1010 || code == 1011 { throw TuyaFailure.tokenInvalid }
            if [1004, 1106, 2009, 2017].contains(code) { throw ProviderError.unauthorized }
            throw ProviderError.api("Tuya: \(message)")
        }
        return json["result"] ?? .null
    }

    /// Tuya's request signature: HMAC-SHA256 of clientID + token + t + nonce + (method, body hash, path), in
    /// upper-case hex.
    static func signatureHeaders(
        method: String, path: String, body: Data, credentials: Credentials, token: String?, timestamp: String, nonce: String
    ) -> [String: String] {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let stringToSign = "\(method)\n\(bodyHash)\n\n\(path)"
        let message = credentials.clientID + (token ?? "") + timestamp + nonce + stringToSign
        let key = SymmetricKey(data: Data(credentials.secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        var headers = [
            "client_id": credentials.clientID,
            "sign": mac.map { String(format: "%02X", $0) }.joined(),
            "sign_method": "HMAC-SHA256",
            "t": timestamp,
            "nonce": nonce,
        ]
        if let token { headers["access_token"] = token }
        return headers
    }
}
