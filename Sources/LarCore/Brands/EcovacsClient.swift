import Foundation
import Security

/// Ecovacs' cloud (the Ecovacs Home app, Deebot robots), as the open deebot-client library documents it: sign-in with
/// the password (MD5, never kept) and, for a new device, a code by e-mail; then the account's token turns into a
/// portal token (renewed without the password), the robot list and each robot's commands over REST. Unofficial:
/// Ecovacs may change it.
public actor EcovacsClient {
    static let clientKey = "1520391301804", clientSecret = "6c319b2a5cd3e66e39159c2e28f2fce9"
    static let authKey = "1520391491841", authSecret = "77ef58ce3afbe337da74aa8c5ab963a9"
    static let meta = ["lang": "EN", "appCode": "global_e", "appVersion": "3.14.0", "channel": "google_play", "deviceType": "1"]
    static let realm = "ecouser.net"
    /// Ecovacs' names for a few countries.
    static let countries = ["GB": "UK", "GR": "GR"]
    /// The portal's continent; most countries (Brazil included) use the worldwide one.
    static let continents: [String: String] = ["US": "na", "CA": "na", "MX": "na", "DE": "eu", "FR": "eu", "IT": "eu", "ES": "eu",
                                               "GB": "eu", "NL": "eu", "PT": "eu", "CN": "", "JP": "as", "KR": "as", "IN": "as"]

    struct Robot: Sendable, Equatable {
        var did: String
        var name: String
        var deviceClass: String
        var resource: String
        var online: Bool
    }

    struct Config: Sendable {
        var country: String
        var deviceID: String

        var loginURL: String { "https://gl-\(country.lowercased())-api.ecovacs.com" }
        var authCodeURL: String { "https://gl-\(country.lowercased())-openapi.ecovacs.com" }
        var portalURL: String {
            let continent = EcovacsClient.continents[country] ?? "ww"
            return "https://portal\(continent.isEmpty ? "" : "-" + continent).ecouser.net"
        }

        static func current(deviceID: String? = nil) -> Config {
            let region = Locale.current.region?.identifier ?? "BR"
            return Config(country: EcovacsClient.countries[region] ?? region,
                          deviceID: deviceID ?? BrandCrypto.md5Hex(UUID().uuidString))
        }
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let http: BrandHTTP
    private var portal: (token: String, userID: String, expires: Date)?

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport) {
        self.account = account
        self.save = save
        self.http = BrandHTTP(transport: transport)
    }

    private var config: Config {
        Config(country: account["country"] ?? "BR", deviceID: account["deviceId"] ?? BrandCrypto.md5Hex(account.email))
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .ecovacs,
        hint: tr("Entre com a conta do app Ecovacs Home. Os robôs Deebot aparecem na lista para limpar, voltar à base e ver o estado e a bateria."),
        needsPassword: true,
        appName: "Ecovacs Home"
    ) { email, password in
        let config = Config.current()
        let http = BrandHTTP(transport: defaultTransport)
        let base = ["country": config.country, "deviceId": config.deviceID]
        do {
            let data = try await privateCall(config, "user/login", ["account": email, "password": BrandCrypto.md5Hex(password)], http: http)
            return .done(BrandAccount(email: email, values: base.merging(try credentials(data)) { _, new in new }))
        } catch EcovacsError.verificationNeeded {
            // A sign-in from a device Ecovacs doesn't know yet: a code by e-mail confirms it.
            let encrypted = try await encryptAccount(email, config: config, http: http)
            _ = try await privateCall(config, "user/sendEmailVerifyCode", [
                "encryptEmail": encrypted, "verifyType": "EMAIL_VERIFY_DEVICE", "supportChar": "N", "isForce": "N",
            ], http: http)
            return .code(hint: tr("A Ecovacs mandou um código para o e-mail da conta, para confirmar este aparelho.")) { code in
                let data = try await privateCall(config, "user/verifyDevice", [
                    "encryptAccount": encrypted, "backUpEmail": "", "verifyCode": code.trimmingCharacters(in: .whitespaces),
                    "model": "iPhone", "system": "iOS",
                ], http: http)
                return BrandAccount(email: email, values: base.merging(try credentials(data)) { _, new in new })
            }
        }
    }

    enum EcovacsError: Error { case verificationNeeded }

    static func credentials(_ data: Any?) throws -> [String: String] {
        guard let data = data as? [String: Any], let token = data.string("accessToken"), let uid = data.string("uid") else {
            throw ProviderError.api(tr("Resposta inesperada da Ecovacs"))
        }
        return ["accessToken": token, "uid": uid]
    }

    /// MD5 of the key, the parameters sorted by name and the secret.
    static func sign(_ params: [String: String], extra: [String: String], key: String, secret: String) -> [String: String] {
        let all = extra.merging(params) { _, new in new }
        var out = params
        out["authSign"] = BrandCrypto.md5Hex(key + all.keys.sorted().map { "\($0)=\(all[$0]!)" }.joined() + secret)
        out["authAppkey"] = key
        return out
    }

    static func privateCall(_ config: Config, _ endpoint: String, _ params: [String: String], http: BrandHTTP) async throws -> Any? {
        var meta = Self.meta
        meta["country"] = config.country.lowercased()
        meta["deviceId"] = config.deviceID
        let path = "/v1/private/\(meta["country"]!)/\(meta["lang"]!)/\(config.deviceID)/\(meta["appCode"]!)/\(meta["appVersion"]!)/\(meta["channel"]!)/\(meta["deviceType"]!)/\(endpoint)"
        let now = Date().timeIntervalSince1970
        var query = params
        query["requestId"] = BrandCrypto.md5Hex(String(now))
        query["authTimespan"] = String(Int(now * 1000))
        query["authTimeZone"] = "GMT-8"
        let response = try await http.json("GET", config.loginURL + path, query: sign(query, extra: meta, key: clientKey, secret: clientSecret))
        return try check(response)
    }

    static func check(_ response: [String: Any]) throws -> Any? {
        switch response.string("code") {
        case "0000": return response["data"]
        case "1005", "1010": throw ProviderError.api(tr("E-mail ou senha errados"))
        case "1012": throw ProviderError.api(tr("Código errado. Confira o e-mail e tente de novo."))
        case "1013": throw EcovacsError.verificationNeeded
        default: throw ProviderError.api(response.string("msg") ?? tr("Resposta inesperada da Ecovacs"))
        }
    }

    /// The account, encrypted with Ecovacs' public key (RSA, PKCS#1 v1.5), as the device check wants it.
    static func encryptAccount(_ email: String, config: Config, http: BrandHTTP) async throws -> String {
        let entries = try await privateCall(config, "common/getConfig", ["keys": "PUBLIC.KEY.CONFIG"], http: http) as? [[String: Any]] ?? []
        guard let value = entries.first(where: { $0.string("key") == "PUBLIC.KEY.CONFIG" })?.string("value"),
              let inner = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
              let encoded = inner.string("publicKey"), let der = Data(base64Encoded: encoded),
              let pkcs1 = rsaPublicKey(fromSPKI: der),
              let key = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                               kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              let sealed = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(email.utf8) as CFData, nil) as Data?
        else { throw ProviderError.api(tr("A Ecovacs pediu uma verificação que o Lar não conseguiu fazer")) }
        return sealed.base64EncodedString()
    }

    /// The PKCS#1 key inside a SubjectPublicKeyInfo (the BIT STRING's contents).
    static func rsaPublicKey(fromSPKI der: Data) -> Data? {
        let bytes = [UInt8](der)
        func length(at index: inout Int) -> Int? {
            guard index < bytes.count else { return nil }
            var count = Int(bytes[index]); index += 1
            if count & 0x80 != 0 {
                let size = count & 0x7f
                guard index + size <= bytes.count else { return nil }
                count = bytes[index..<index + size].reduce(0) { $0 << 8 | Int($1) }
                index += size
            }
            return count
        }
        var index = 0
        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard length(at: &index) != nil, index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithm = length(at: &index) else { return nil }
        index += algorithm
        guard index < bytes.count, bytes[index] == 0x03 else { return nil }
        index += 1
        guard let bits = length(at: &index), index + bits <= bytes.count, bits > 1 else { return nil }
        return Data(bytes[(index + 1)..<(index + bits)])
    }

    // MARK: Portal

    private func portalCredentials() async throws -> (token: String, userID: String) {
        if let portal, portal.expires > Date() { return (portal.token, portal.userID) }
        guard let access = account["accessToken"], let uid = account["uid"] else { throw ProviderError.unauthorized }
        let config = config
        let params = Self.sign(["uid": uid, "accessToken": access, "bizType": "ECOVACS_IOT", "deviceId": config.deviceID,
                                "authTimespan": String(Int(Date().timeIntervalSince1970 * 1000))],
                               extra: ["openId": "global"], key: Self.authKey, secret: Self.authSecret)
        let response = try await http.json("GET", config.authCodeURL + "/v1/global/auth/getAuthCode", query: params)
        let data: Any?
        do {
            data = try Self.check(response)
        } catch {
            throw ProviderError.unauthorized
        }
        guard let authCode = (data as? [String: Any])?.string("authCode") else { throw ProviderError.unauthorized }
        let login = try await http.json("POST", config.portalURL + "/api/users/user.do", body: [
            "edition": "ECOGLOBLE", "userId": uid, "token": authCode, "realm": Self.realm, "resource": config.deviceID,
            "org": config.country == "CN" ? "ECOCN" : "ECOWW", "last": "", "country": config.country, "todo": "loginByItToken",
        ])
        guard login.string("result") == "ok", let token = login.string("token") else { throw ProviderError.unauthorized }
        let userID = login.string("userId") ?? uid
        let lifetime = Double(login.int("last") ?? 604_800_000) / 1000 * 0.9
        portal = (token, userID, Date().addingTimeInterval(lifetime))
        return (token, userID)
    }

    private func post(_ path: String, _ body: [String: Any], query: [String: String] = [:]) async throws -> [String: Any] {
        let (token, userID) = try await portalCredentials()
        var body = body
        body["auth"] = ["with": "users", "userid": userID, "realm": Self.realm, "token": token, "resource": config.deviceID]
        let response = try await http.json("POST", config.portalURL + "/api/" + path, query: query, body: body,
                                           headers: ["User-Agent": "Dalvik/2.1.0 (Linux; U; Android 5.1.1; A5010 Build/LMY48Z)"])
        if response.string("errno") == "3001" || response.string("error")?.contains("auth") == true {
            portal = nil
            throw ProviderError.unauthorized
        }
        return response
    }

    // MARK: Robots

    func robots() async throws -> [Robot] {
        let (_, userID) = try await portalCredentials()
        let response = try await post("appsvr/app.do", ["userid": userID, "todo": "GetGlobalDeviceList"])
        return response.list("devices").compactMap { item in
            guard let did = item.string("did"), let deviceClass = item.string("class") else { return nil }
            let name = [item.string("nick"), item.string("deviceName"), item.string("name")].compactMap { $0 }.first { !$0.isEmpty } ?? "Deebot"
            return Robot(did: did, name: name, deviceClass: deviceClass, resource: item.string("resource") ?? "",
                         online: item.int("status").map { $0 == 1 } ?? true)
        }
    }

    /// One command to the robot; the answer's data.
    func command(_ name: String, _ data: [String: Any] = [:], on robot: Robot) async throws -> [String: Any] {
        let (_, userID) = try await portalCredentials()
        let response = try await post("iot/devmanager.do", [
            "cmdName": name,
            "payload": ["header": ["pri": "1", "ts": Date().timeIntervalSince1970, "tzm": 480, "ver": "0.0.50"], "body": ["data": data]],
            "payloadType": "j", "td": "q", "toId": robot.did, "toRes": robot.resource, "toType": robot.deviceClass,
        ], query: ["mid": robot.deviceClass, "did": robot.did, "td": "q", "u": userID, "cv": "1.67.3", "t": "a", "av": "1.3.1"])
        guard response.string("ret") == "ok" else {
            throw ProviderError.api(response.string("error") ?? tr("O robô não respondeu"))
        }
        let body = response.dict("resp")?.dict("body")
        if let code = body?.int("code"), code != 0 { throw ProviderError.api(body?.string("msg") ?? tr("O robô recusou o comando")) }
        return body?.dict("data") ?? [:]
    }

    struct Status: Sendable, Equatable {
        var state: String
        var charging: Bool
        var battery: Int?
    }

    func status(of robot: Robot) async throws -> Status {
        let clean = try await command("getCleanInfo_V2", on: robot)
        let battery = try? await command("getBattery", on: robot)
        let charge = try? await command("getChargeState", on: robot)
        let motion = clean.dict("cleanState")?.string("motionState")
        var state = clean.string("state") ?? "idle"
        if state == "clean", motion == "pause" { state = "pause" }
        return Status(state: state, charging: charge?.int("isCharging") == 1, battery: battery?.int("value"))
    }

    func clean(_ robot: Robot) async throws {
        do {
            _ = try await command("clean_V2", ["act": "start", "content": ["type": "auto"]], on: robot)
        } catch {
            _ = try await command("clean", ["act": "start", "type": "auto"], on: robot)
        }
    }

    func pause(_ robot: Robot) async throws {
        do {
            _ = try await command("clean_V2", ["act": "pause"], on: robot)
        } catch {
            _ = try await command("clean", ["act": "pause"], on: robot)
        }
    }

    func dock(_ robot: Robot) async throws {
        _ = try await command("charge", ["act": "go"], on: robot)
    }

    static func stateText(_ status: Status) -> String {
        switch status.state {
        case "clean": tr("Limpando")
        case "pause": tr("Pausado")
        case "goCharging": tr("Voltando à base")
        default: status.charging ? (status.battery == 100 ? tr("Carregado") : tr("Carregando")) : tr("Parado")
        }
    }
}

/// Ecovacs' Deebots in the list: on is cleaning, off is back to the dock.
public struct EcovacsProvider: DeviceProvider {
    public let provider = Provider.ecovacs
    let client: EcovacsClient

    public func devices() async throws -> [HomeDevice] {
        let robots = try await client.robots()
        return await withTaskGroup(of: HomeDevice.self) { group in
            for robot in robots {
                group.addTask {
                    let status = robot.online ? try? await client.status(of: robot) : nil
                    return Self.device(robot, status: status)
                }
            }
            var out: [HomeDevice] = []
            for await device in group { out.append(device) }
            return out.sorted { $0.name < $1.name }
        }
    }

    static func device(_ robot: EcovacsClient.Robot, status: EcovacsClient.Status?) -> HomeDevice {
        var parts: [String] = []
        if let status {
            parts.append(EcovacsClient.stateText(status))
            if let battery = status.battery { parts.append(tr("bateria \(battery)%")) }
        }
        return HomeDevice(provider: .ecovacs, rawID: robot.did, name: robot.name, kind: .vacuum, isOnline: robot.online,
                          isOn: status.map { $0.state == "clean" }, detail: parts.joined(separator: " · "), controls: ["pausable": "1"])
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard let robot = try await client.robots().first(where: { $0.did == device.rawID }) else { throw ProviderError.unsupported }
        switch command {
        case .power(let on): if on { try await client.clean(robot) } else { try await client.dock(robot) }
        case .pause: try await client.pause(robot)
        default: throw ProviderError.unsupported
        }
    }
}
