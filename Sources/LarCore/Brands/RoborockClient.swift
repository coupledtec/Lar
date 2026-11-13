import Foundation

/// Roborock's cloud, as the Roborock app uses it (the open python-roborock library documents it): sign-in with a code
/// sent by e-mail, the robots from the home's data (Hawk-signed), and each robot's status and commands over Roborock's
/// MQTT, in messages encrypted with the robot's own key. Unofficial: Roborock may change it.
///
/// The home's data is limited to a few reads an hour, so the robot list is kept in the account and read again at most
/// once an hour; the status comes from the robots themselves at every read.
public actor RoborockClient {
    static let baseURLs = ["https://usiot.roborock.com", "https://euiot.roborock.com", "https://cniot.roborock.com",
                           "https://ruiot.roborock.com"]
    static let listLifetime: TimeInterval = 3600

    /// The keys the sign-in gives (`rriot`): the user and session ids, the HMAC key and the MQTT key, and the two servers.
    struct Rriot: Codable, Sendable, Equatable {
        var u: String
        var s: String
        var h: String
        var k: String
        var r: Servers

        struct Servers: Codable, Sendable, Equatable {
            /// The REST server (home data).
            var a: String
            /// The MQTT broker ("ssl://mqtt-us.roborock.com:8883").
            var m: String
        }
    }

    struct Robot: Codable, Sendable, Equatable {
        var duid: String
        var name: String
        var localKey: String
        /// The robot's protocol: "1.0" (most of them, the only one supported here), "A01", "B01".
        var version: String
        var model: String?
        var online: Bool
        /// State and battery as the home's data last had them (121 and 122).
        var state: Int?
        var battery: Int?
        /// The home's rooms (their id → name), for cleaning one.
        var rooms: [String: String]?
    }

    struct Status: Sendable, Equatable {
        var state: Int
        var battery: Int?
        /// The suction (101 quiet … 104 max), when the robot says it.
        var fanPower: Int?
        /// What went wrong (0: nothing).
        var error: Int = 0
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let http: BrandHTTP
    private var mqtt: MQTTClient?

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport) {
        self.account = account
        self.save = save
        self.http = BrandHTTP(transport: transport)
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .roborock,
        hint: tr("Entre com o e-mail da conta do app Roborock: o Lar recebe um código por e-mail. Os robôs aparecem na lista para limpar, voltar à base e ver o estado e a bateria."),
        needsPassword: false,
        appName: "Roborock"
    ) { email, _ in
        let http = BrandHTTP(transport: defaultTransport)
        let session = try await RoborockSignIn.start(email: email, http: http)
        return .code(hint: tr("Digite o código que a Roborock mandou para \(email).")) { code in
            try await session.finish(code: code)
        }
    }

    // MARK: Robots

    func robots() async throws -> [Robot] {
        let cached = account.decoded([Robot].self, "robots")
        let at = account["robotsAt"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        if let cached, Date().timeIntervalSince(at) < Self.listLifetime { return cached }
        do {
            let fresh = try await fetchRobots()
            account.encode(fresh, "robots")
            account["robotsAt"] = String(Date().timeIntervalSince1970)
            save(account)
            return fresh
        } catch ProviderError.unauthorized {
            throw ProviderError.unauthorized
        } catch {
            // Over the hourly limit or the server away: the robots seen before still answer over MQTT.
            if let cached { return cached }
            throw error
        }
    }

    private func fetchRobots() async throws -> [Robot] {
        guard let rriot = account.decoded(Rriot.self, "rriot"), let base = account["base"], let token = account["token"] else {
            throw ProviderError.unauthorized
        }
        let detail = try await http.json("GET", base + "/api/v1/getHomeDetail", headers: ["Authorization": token])
        guard detail.int("code") == 200, let homeID = detail.dict("data")?.string("rrHomeId") else {
            if detail.int("code") == 2010 { throw ProviderError.unauthorized }
            throw ProviderError.api(Self.message(detail))
        }
        let path = "/v3/user/homes/\(homeID)"
        let home = try await http.json("GET", rriot.r.a + path, headers: ["Authorization": Self.hawk(rriot, path: path)])
        guard home["success"] as? Bool == true, let result = home.dict("result") else { throw ProviderError.api(Self.message(home)) }
        return Self.robots(fromHome: result)
    }

    static func robots(fromHome result: [String: Any]) -> [Robot] {
        let products = Dictionary(result.list("products").compactMap { product -> (String, [String: Any])? in
            product.string("id").map { ($0, product) }
        }, uniquingKeysWith: { first, _ in first })
        let rooms = Dictionary(result.list("rooms").compactMap { room -> (String, String)? in
            guard let id = room["id"].map({ "\($0)" }), let name = room.string("name") else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        return (result.list("devices") + result.list("receivedDevices")).compactMap { device in
            guard let duid = device.string("duid"), let key = device.string("localKey") else { return nil }
            let product = device.string("productId").flatMap { products[$0] }
            // Only the vacuums: the brand also has washers and wet-dry vacuums (other protocols).
            if let category = product?.string("category"), !category.contains("vacuum") { return nil }
            let status = device.dict("deviceStatus") ?? [:]
            return Robot(duid: duid, name: device.string("name") ?? "Roborock", localKey: key,
                         version: device.string("pv") ?? "1.0", model: product?.string("model"),
                         online: device["online"] as? Bool ?? true, state: status.int("121"), battery: status.int("122"),
                         rooms: rooms.isEmpty ? nil : rooms)
        }
    }

    // MARK: Status and commands

    func status(of robot: Robot) async throws -> Status {
        let result = try await call("get_status", on: robot)
        let first = (result as? [[String: Any]])?.first ?? (result as? [String: Any]) ?? [:]
        guard let state = first.int("state") else { throw ProviderError.api(tr("Estado do robô ilegível")) }
        return Status(state: state, battery: first.int("battery"), fanPower: first.int("fan_power"), error: first.int("error_code") ?? 0)
    }

    /// The robot's map segments with their room's name ("17=Sala"), for cleaning one.
    func segments(of robot: Robot) async -> [String] {
        guard let mapping = try? await call("get_room_mapping", on: robot) as? [[Any]] else { return [] }
        return mapping.compactMap { entry in
            guard let segment = entry.first.flatMap({ $0 as? Int ?? Int("\($0)") }) else { return nil }
            let room = entry.count > 1 ? "\(entry[1])" : ""
            return "\(segment)=\(robot.rooms?[room] ?? tr("Cômodo \(segment)"))"
        }
    }

    /// The robot's error, in words (the common ones; the rest by number).
    static func errorText(_ code: Int) -> String? {
        switch code {
        case 0: nil
        case 2: tr("Para-choque preso")
        case 3, 4: tr("Rodas no ar ou sensor de queda")
        case 5: tr("Escova principal travada")
        case 6: tr("Escova lateral travada")
        case 7: tr("Rodas travadas")
        case 8: tr("Robô preso")
        case 9: tr("Sem o reservatório de pó")
        case 12: tr("Bateria fraca")
        case 13: tr("Não está carregando")
        case 34, 35: tr("Base cheia: esvazie o saco de pó")
        case 38: tr("Tanque de água limpa vazio")
        case 39: tr("Tanque de água suja cheio")
        default: tr("Robô com problema (erro \(code))")
        }
    }

    /// app_start (clean), app_pause, app_charge (back to the dock).
    func command(_ method: String, params: Any = [Any](), on robot: Robot) async throws {
        _ = try await call(method, params: params, on: robot)
    }

    private func call(_ method: String, params: Any = [Any](), on robot: Robot) async throws -> Any {
        guard robot.version == "1.0" else { throw ProviderError.unsupported }
        guard let rriot = account.decoded(Rriot.self, "rriot") else { throw ProviderError.unauthorized }
        let client = try mqttClient(rriot)
        let user = Self.mqttUser(rriot)
        try await client.subscribe(["rr/m/o/\(rriot.u)/\(user)/\(robot.duid)"])
        let id = Int.random(in: 10_000...32_767)
        let now = Int(Date().timeIntervalSince1970)
        let message = try RoborockMessage.request(id: id, method: method, params: params, timestamp: now)
        let frame = try RoborockMessage.encode(message, localKey: robot.localKey)
        let key = robot.localKey
        let reply = try await client.request("rr/m/i/\(rriot.u)/\(user)/\(robot.duid)", frame) { incoming in
            guard incoming.topic.hasSuffix(robot.duid) else { return false }
            return (try? RoborockMessage.decode(incoming.payload, localKey: key))?.contains { $0.responseID == id } == true
        }
        guard let response = try RoborockMessage.decode(reply.payload, localKey: key).first(where: { $0.responseID == id }) else {
            throw ProviderError.api(tr("Resposta do robô ilegível"))
        }
        if let error = response.responseError { throw ProviderError.api(tr("O robô recusou: \(error)")) }
        return response.responseResult ?? [String: Any]()
    }

    private func mqttClient(_ rriot: Rriot) throws -> MQTTClient {
        if let mqtt { return mqtt }
        guard let url = URL(string: rriot.r.m), let host = url.host, let port = url.port else {
            throw ProviderError.api(tr("Servidor da Roborock desconhecido"))
        }
        let client = MQTTClient(.init(host: host, port: UInt16(port), tls: url.scheme == "ssl",
                                      clientID: BrandCrypto.randomHex(8), username: Self.mqttUser(rriot),
                                      password: String(BrandCrypto.md5Hex("\(rriot.s):\(rriot.k)").dropFirst(16))))
        mqtt = client
        return client
    }

    static func mqttUser(_ rriot: Rriot) -> String {
        String(BrandCrypto.md5Hex("\(rriot.u):\(rriot.k)").dropFirst(2).prefix(8))
    }

    /// Hawk authorization for the REST server: an HMAC-SHA256 of the ids, a nonce, the time and the path's MD5.
    static func hawk(_ rriot: Rriot, path: String, timestamp: Int = Int(Date().timeIntervalSince1970),
                     nonce: String = BrandCrypto.randomAlphanumeric(8)) -> String {
        let text = [rriot.u, rriot.s, nonce, String(timestamp), BrandCrypto.md5Hex(path), "", ""].joined(separator: ":")
        let mac = BrandCrypto.hmacSHA256(key: Data(rriot.h.utf8), Data(text.utf8)).base64EncodedString()
        return "Hawk id=\"\(rriot.u)\",s=\"\(rriot.s)\",ts=\"\(timestamp)\",nonce=\"\(nonce)\",mac=\"\(mac)\""
    }

    static func message(_ response: [String: Any]) -> String {
        response.string("msg") ?? response.string("message") ?? tr("Resposta inesperada da Roborock")
    }

    /// The v1 robots' states, as the Roborock app names them.
    static func stateText(_ state: Int) -> String {
        switch state {
        case 5, 7, 11, 16, 17, 18: tr("Limpando")
        case 6, 15: tr("Voltando à base")
        case 8: tr("Carregando")
        case 100: tr("Carregado")
        case 10: tr("Pausado")
        case 3, 2, 1: tr("Parado")
        case 9, 12: tr("Com problema")
        case 14: tr("Atualizando")
        case 22: tr("Esvaziando o reservatório")
        case 23, 26: tr("Lavando o pano")
        case 101: tr("Offline")
        default: tr("Parado")
        }
    }

    static func isCleaning(_ state: Int) -> Bool { [5, 7, 11, 16, 17, 18, 23, 26].contains(state) }
}

/// The Roborock sign-in, between sending the code and typing it: the regional server and the client id must match.
struct RoborockSignIn: Sendable {
    let email: String
    let base: String
    let country: String?
    let countryCode: String?
    let clientID: String
    let http: BrandHTTP

    static func start(email: String, http: BrandHTTP) async throws -> RoborockSignIn {
        var found: (String, String?, String?)?
        for base in RoborockClient.baseURLs {
            let response = try await http.json("POST", base + "/api/v1/getUrlByEmail",
                                               query: ["email": email, "needtwostepauth": "false"])
            guard response.int("code") == 200, let data = response.dict("data") else {
                if response.int("code") == 2003 { throw ProviderError.api(tr("E-mail inválido")) }
                continue
            }
            if data.string("countrycode") != nil || data.string("country") != nil {
                found = (data.string("url") ?? base, data.string("country"), data.string("countrycode"))
                break
            }
        }
        guard let (base, country, countryCode) = found else {
            throw ProviderError.api(tr("Nenhuma conta Roborock com esse e-mail"))
        }
        let clientID = BrandCrypto.md5(Data((email + BrandCrypto.randomHex(16)).utf8)).base64EncodedString()
        let session = RoborockSignIn(email: email, base: base, country: country, countryCode: countryCode,
                                     clientID: clientID, http: http)
        try await session.sendCode()
        return session
    }

    func sendCode() async throws {
        let response = try await http.json("POST", base + "/api/v4/email/code/send",
                                           form: ["email": email, "type": "login", "platform": ""],
                                           headers: ["header_clientid": clientID, "header_clientlang": "en"])
        switch response.int("code") {
        case 200: return
        case 2008: throw ProviderError.api(tr("Nenhuma conta Roborock com esse e-mail"))
        case 9002: throw ProviderError.api(tr("Códigos pedidos demais. Tente de novo mais tarde."))
        default:
            // The older endpoint, for the servers without the new one.
            let old = try await http.json("POST", base + "/api/v1/sendEmailCode", query: ["username": email, "type": "auth"],
                                          headers: ["header_clientid": clientID])
            guard old.int("code") == 200 else { throw ProviderError.api(RoborockClient.message(old)) }
        }
    }

    func finish(code: String) async throws -> BrandAccount {
        let code = code.trimmingCharacters(in: .whitespaces)
        var data: [String: Any]?
        if let country, let countryCode {
            let ks = BrandCrypto.randomAlphanumeric(16)
            let signed = try await http.json("POST", base + "/api/v3/key/sign", query: ["s": ks],
                                             headers: ["header_clientid": clientID])
            if let k = signed.dict("data")?.string("k") {
                let agreement = try? await http.json("GET", base + "/api/v3/app/agreement/latest", query: ["country": country],
                                                     headers: ["header_clientlang": "en"])
                let version = agreement?.dict("data")
                let response = try await http.json("POST", base + "/api/v4/auth/email/login/code", form: [
                    "country": country, "countryCode": countryCode, "email": email, "code": code,
                    "majorVersion": version?.string("majorVersion") ?? "14", "minorVersion": version?.string("minorVersion") ?? "0",
                ], headers: ["header_clientid": clientID, "x-mercy-ks": ks, "x-mercy-k": k, "header_clientlang": "en",
                             "header_appversion": "4.54.02", "header_phonesystem": "iOS", "header_phonemodel": "iPhone16,1"])
                try Self.check(response)
                data = response.dict("data")
            }
        }
        if data == nil {
            let response = try await http.json("POST", base + "/api/v1/loginWithCode", query: [
                "username": email, "verifycode": code, "verifycodetype": "AUTH_EMAIL_CODE",
            ], headers: ["header_clientid": clientID])
            try Self.check(response)
            data = response.dict("data")
        }
        guard let data, let token = data.string("token"), let rriot = data.dict("rriot"),
              let rriotData = try? JSONSerialization.data(withJSONObject: rriot),
              (try? JSONDecoder().decode(RoborockClient.Rriot.self, from: rriotData)) != nil else {
            throw ProviderError.api(tr("Resposta inesperada da Roborock"))
        }
        return BrandAccount(email: email, values: ["base": base, "token": token,
                                                   "rriot": String(decoding: rriotData, as: UTF8.self)])
    }

    static func check(_ response: [String: Any]) throws {
        switch response.int("code") {
        case 200: return
        case 2018: throw ProviderError.api(tr("Código errado. Confira o e-mail e tente de novo."))
        case 3009, 3006: throw ProviderError.api(tr("Aceite os termos de uso no app Roborock e tente de novo."))
        case 3039, 2008: throw ProviderError.api(tr("Nenhuma conta Roborock com esse e-mail"))
        default: throw ProviderError.api(RoborockClient.message(response))
        }
    }
}

/// Roborock's "1.0" messages: a header (version, sequence, random, time, protocol), the payload encrypted with
/// AES-128-ECB under MD5(time scrambled + the robot's key + a salt), and a CRC-32 of it all.
struct RoborockMessage {
    static let salt = "TXdfu$jyZ#TZHsg4"
    static let rpcRequest: UInt16 = 101, rpcResponse: UInt16 = 102

    var sequence: UInt32
    var random: UInt32
    var timestamp: UInt32
    var `protocol`: UInt16
    var payload: Data

    static func request(id: Int, method: String, params: Any, timestamp: Int) throws -> RoborockMessage {
        let inner = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params], options: [.sortedKeys])
        let outer = try JSONSerialization.data(withJSONObject: ["dps": ["101": String(decoding: inner, as: UTF8.self)],
                                                               "t": timestamp], options: [.sortedKeys])
        return RoborockMessage(sequence: UInt32.random(in: 100_000...999_999), random: UInt32.random(in: 10_000...99_999),
                               timestamp: UInt32(timestamp), protocol: rpcRequest, payload: outer)
    }

    /// The time's hexadecimal digits in Roborock's order.
    static func scrambledTimestamp(_ timestamp: UInt32) -> String {
        let hex = Array(String(format: "%08x", timestamp))
        return String([5, 6, 3, 7, 1, 2, 0, 4].map { hex[$0] })
    }

    static func key(timestamp: UInt32, localKey: String) -> Data {
        BrandCrypto.md5(Data((scrambledTimestamp(timestamp) + localKey + salt).utf8))
    }

    static func encode(_ message: RoborockMessage, localKey: String) throws -> Data {
        var out = Data("1.0".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) } }
        append(message.sequence)
        append(message.random)
        append(message.timestamp)
        append(message.protocol)
        let encrypted = message.payload.isEmpty ? Data()
            : try BrandCrypto.aes(true, key: key(timestamp: message.timestamp, localKey: localKey), message.payload)
        append(UInt16(encrypted.count))
        out.append(encrypted)
        append(BrandCrypto.crc32(out))
        return out
    }

    static func decode(_ data: Data, localKey: String) throws -> [RoborockMessage] {
        var messages: [RoborockMessage] = []
        var index = data.startIndex
        func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard index + size <= data.endIndex else { throw ProviderError.api(tr("Mensagem do aparelho cortada")) }
            let value = data[index..<index + size].reduce(T(0)) { $0 << 8 | T($1) }
            index += size
            return value
        }
        while index + 17 <= data.endIndex {
            let start = index
            guard String(decoding: data[index..<index + 3], as: UTF8.self) == "1.0" else { throw ProviderError.unsupported }
            index += 3
            let sequence = try read(UInt32.self), random = try read(UInt32.self), timestamp = try read(UInt32.self)
            let proto = try read(UInt16.self), length = Int(try read(UInt16.self))
            guard index + length <= data.endIndex else { throw ProviderError.api(tr("Mensagem do aparelho cortada")) }
            let encrypted = data[index..<index + length]
            index += length
            if index + 4 <= data.endIndex {
                let crc = try read(UInt32.self)
                guard crc == BrandCrypto.crc32(data[start..<index - 4]) else { throw ProviderError.api(tr("Mensagem do aparelho corrompida")) }
            }
            let payload = encrypted.isEmpty ? Data()
                : try BrandCrypto.aes(false, key: key(timestamp: timestamp, localKey: localKey), Data(encrypted))
            messages.append(RoborockMessage(sequence: sequence, random: random, timestamp: timestamp, protocol: proto, payload: payload))
        }
        return messages
    }

    /// The RPC answer inside a 102 message: `dps["102"]` is JSON text with the id and the result.
    private var rpcAnswer: [String: Any]? {
        guard self.protocol == Self.rpcResponse,
              let outer = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let text = outer.dict("dps")?["102"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return inner
    }

    var responseID: Int? { rpcAnswer?.int("id") }
    var responseResult: Any? {
        guard let result = rpcAnswer?["result"] else { return nil }
        if let text = result as? String { return text == "ok" ? [String: Any]() : nil }
        return result
    }

    var responseError: String? {
        guard let answer = rpcAnswer else { return nil }
        if let error = answer.dict("error") { return error.string("message") ?? error.string("code") }
        if let text = answer["result"] as? String, text != "ok" { return text }
        return nil
    }
}
