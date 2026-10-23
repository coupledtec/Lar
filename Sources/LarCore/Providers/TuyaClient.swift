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

        public init(clientID: String, secret: String, region: String = "us") {
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

    static func device(from json: JSONValue) -> HomeDevice {
        let id = json["id"]?.string ?? ""
        let category = json["category"]?.string ?? ""
        let kind: DeviceKind = category == "sp" ? .camera
            : lightCategories.contains(category) ? .light
            : plugCategories.contains(category) ? .plug
            : climateCategories.contains(category) ? .climateSensor
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
        }
        if kind == .camera { device.isOn = nil }
        if let temperature {
            device.detail = "\(Int(temperature.rounded()))°" + (humidity.map { " · \(Int($0))%" } ?? "")
        }
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
        case .temperature:
            throw ProviderError.unsupported
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
        let result = try await call("POST", "/v1.0/devices/\(device.rawID)/stream/actions/allocate", body: ["type": "hls"])
        guard let link = result["url"]?.string, let url = URL(string: link) else {
            throw ProviderError.api("A câmera não mandou o vídeo")
        }
        return url
    }

    // MARK: Signed calls

    /// A signed call with the project's token; a token the cloud dropped is renewed once.
    private func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        for attempt in 0..<2 {
            if token == nil || now() >= tokenExpires {
                let result = try await signed("GET", "/v1.0/token?grant_type=1", body: nil, token: nil)
                guard let access = result["access_token"]?.string else { throw ProviderError.api("Tuya: sem token") }
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
            throw ProviderError.api("Resposta inesperada da Tuya")
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
