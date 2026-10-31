import Foundation
import Security

/// Eufy's cloud (the eufy Clean and Eufy apps), as the open eufy-clean library documents it: sign-in with the
/// password, the robots and their last state (data points) over REST, and commands over Eufy's MQTT with the client
/// certificate the account hands out. Newer robots (X and later) code their state and commands in protocol
/// buffers; older ones use plain values. Eufy has no renewal token, so the password stays in the keychain to sign in
/// again. Unofficial: Eufy may change it.
public actor EufyClient {
    static let aiot = "https://aiot-clean-api-pr.eufylife.com"
    static let logins: [(url: String, clientID: String, secret: String, category: String)] = [
        ("https://home-api.eufylife.com/v1/user/v2/email/login", "eufy-app", "8FHf22gaTKu7MZXqz5zytw", "Health"),
        ("https://home-api.eufylife.com/v1/user/email/login", "eufyhome-app", "GQCpr9dSp3uQpsOMgJ4xQ", "Home"),
    ]
    static let agent = "EufyHome-Android-3.1.3-753"

    struct Robot: Sendable, Equatable {
        var serial: String
        var name: String
        var model: String
        var online: Bool
        var dps: [String: String]
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let http: BrandHTTP
    private var mqtt: (client: MQTTClient, userID: String, appName: String)?

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport) {
        self.account = account
        self.save = save
        self.http = BrandHTTP(transport: transport)
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .eufy,
        hint: tr("Entre com a conta do app eufy Clean (ou Eufy). Os robôs RoboVac aparecem na lista para limpar, voltar à base e ver o estado e a bateria. A Eufy não renova a sessão sozinha: a senha fica no Porta-chaves deste aparelho para entrar de novo."),
        needsPassword: true,
        appName: "eufy Clean",
        keepsPassword: true
    ) { email, password in
        let values = try await login(email: email, password: password, openudid: BrandCrypto.randomHex(16),
                                     http: BrandHTTP(transport: defaultTransport))
        return .done(BrandAccount(email: email, values: values.merging(["password": password]) { _, new in new }))
    }

    static func login(email: String, password: String, openudid: String, http: BrandHTTP) async throws -> [String: String] {
        var token: String?
        for login in logins {
            let response = try? await http.json("POST", login.url, body: [
                "email": email, "password": password, "client_id": login.clientID, "client_secret": login.secret,
            ], headers: ["category": login.category, "openudid": openudid, "clientType": "1", "User-Agent": agent,
                         "language": "en", "country": "BR", "timezone": "America/Sao_Paulo"])
            token = response?.string("access_token") ?? response?.dict("data")?.string("access_token")
            if token != nil { break }
        }
        guard let token else { throw ProviderError.api(tr("E-mail ou senha errados")) }
        let info = try await http.json("GET", "https://api.eufylife.com/v1/user/user_center_info", headers: [
            "token": token, "openudid": openudid, "User-Agent": agent, "category": "Home", "clienttype": "2",
        ])
        guard let center = info.string("user_center_token"), let centerID = info.string("user_center_id") else {
            throw ProviderError.api(tr("Resposta inesperada da Eufy"))
        }
        return ["token": token, "center": center, "gtoken": BrandCrypto.md5Hex(centerID), "openudid": openudid]
    }

    private var headers: [String: String] {
        ["User-Agent": Self.agent, "openudid": account["openudid"] ?? "", "os-version": "Android", "model-type": "PHONE",
         "app-name": "eufy_home", "x-auth-token": account["center"] ?? "", "gtoken": account["gtoken"] ?? "",
         "language": "en", "country": "BR", "timezone": "America/Sao_Paulo"]
    }

    /// A call to the robots' API, signing in again with the kept password when the session ended.
    private func aiotCall(_ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var response = try? await http.json("POST", Self.aiot + path, body: body, headers: headers)
        if response == nil || [401, 10001, 26006].contains(response?.int("code") ?? 0) {
            guard let password = account["password"] else { throw ProviderError.unauthorized }
            let renewed = try await Self.login(email: account.email, password: password,
                                               openudid: account["openudid"] ?? BrandCrypto.randomHex(16), http: http)
            account.values.merge(renewed) { _, new in new }
            save(account)
            response = try await http.json("POST", Self.aiot + path, body: body, headers: headers)
        }
        return response ?? [:]
    }

    // MARK: Robots

    func robots() async throws -> [Robot] {
        let response = try await aiotCall("/app/devicerelation/get_device_list", ["attribute": 3])
        let list = (response.dict("data") ?? response).list("devices")
        return list.compactMap { entry in
            let device = entry.dict("device") ?? entry
            guard let serial = device.string("device_sn") else { return nil }
            let dps = (device.dict("dps") ?? [:]).compactMapValues { value -> String? in
                if let text = value as? String { return text }
                if let number = value as? NSNumber {
                    return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
                }
                return nil
            }
            let name = [device.string("alias_name"), device.string("device_name"), device.string("name")]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "RoboVac"
            return Robot(serial: serial, name: name, model: device.string("device_model") ?? device.string("product_code") ?? "",
                         online: (device["online"] as? Bool) ?? (device.int("online_status").map { $0 != 0 } ?? true), dps: dps)
        }
    }

    // MARK: State

    struct Status: Sendable, Equatable {
        var state: String
        var battery: Int?
    }

    /// The newer robots' data points (protocol buffers) or the older ones' plain values.
    static func status(_ dps: [String: String]) -> Status? {
        if let work = dps["153"], let state = workState(work) {
            return Status(state: state, battery: dps["163"].flatMap { Int($0) })
        }
        if let legacy = dps["15"] {
            return Status(state: legacy.lowercased(), battery: dps["104"].flatMap { Int($0) })
        }
        return nil
    }

    /// WorkStatus.state (field 2) and, while cleaning, whether it's paused (cleaning, field 6, state 1).
    static func workState(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), let message = try? delimited(data),
              let reader = try? ProtoReader(message) else { return nil }
        let names = ["standby", "sleep", "fault", "charging", "mapping", "cleaning", "remote", "gohome", "cruising"]
        let state = Int(reader.int(2) ?? 0)
        if state == 5, (try? reader.message(6))??.int(1) == 1 { return "paused" }
        if state == 3, (try? reader.message(3))??.int(1) == 1 { return "charged" }
        return state < names.count ? names[state] : nil
    }

    /// A protocol buffer preceded by its length (varint), as Eufy's data points carry them.
    static func delimited(_ data: Data) throws -> Data {
        var index = data.startIndex
        guard let length = try ProtoReader.readVarint(data, at: &index), index + Int(length) <= data.endIndex else {
            throw ProviderError.api(tr("Mensagem do aparelho cortada"))
        }
        return Data(data[index..<index + Int(length)])
    }

    static func stateText(_ status: Status) -> String {
        let state = status.state
        if state.contains("paused") || state == "pause" { return tr("Pausado") }
        if state.contains("gohome") || state.contains("recharge") || state.contains("go home") { return tr("Voltando à base") }
        if state == "charged" || state.contains("completed") { return tr("Carregado") }
        if state.contains("charg") { return tr("Carregando") }
        if state.contains("clean") || state.contains("running") || state == "mapping" { return tr("Limpando") }
        if state.contains("fault") || state.contains("error") { return tr("Com problema") }
        if state == "sleep" { return tr("Em repouso") }
        return tr("Parado")
    }

    static func isCleaning(_ status: Status) -> Bool {
        stateText(status) == tr("Limpando")
    }

    // MARK: Commands

    /// ModeCtrlRequest in the newer robots: start (auto clean, once) or back to the dock.
    static func control(start: Bool) -> String {
        var message = ProtoWriter()
        if start {
            message.message(3) { $0.varint(1, 1) }
        } else {
            message.varint(1, 6)
        }
        var out = Data()
        ProtoWriter.appendVarint(UInt64(message.data.count), to: &out)
        out.append(message.data)
        return out.base64EncodedString()
    }

    func send(start: Bool, to robot: Robot) async throws {
        let novel = robot.dps["153"] != nil || robot.dps["152"] != nil
        let data: [String: Any] = novel ? ["152": Self.control(start: start)]
            : (start ? ["5": "auto", "2": true] : ["101": true])
        let (client, userID, appName) = try await mqttSession()
        let clientID = "android-\(appName)-eufy_android_\(account["openudid"] ?? "")_\(userID)"
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
            "account_id": userID, "data": data, "device_sn": robot.serial, "protocol": 2, "t": now,
        ]), as: UTF8.self)
        let message = try JSONSerialization.data(withJSONObject: [
            "head": ["client_id": clientID, "cmd": 65537, "cmd_status": 1, "msg_seq": 2, "seed": "", "sess_id": clientID,
                     "sign_code": 0, "timestamp": now, "version": "1.0.0.1"],
            "payload": payload,
        ])
        try await client.publish("cmd/eufy_home/\(robot.model)/\(robot.serial)/req", message, qos: 1)
    }

    private func mqttSession() async throws -> (MQTTClient, String, String) {
        if let mqtt { return mqtt }
        let response = try await aiotCall("/app/devicemanage/get_user_mqtt_info")
        guard let info = response.dict("data"), let endpoint = info.string("endpoint_addr"), let thing = info.string("thing_name"),
              let certificate = info.string("certificate_pem"), let key = info.string("private_key"),
              let userID = info.string("user_id") else { throw ProviderError.api(tr("A Eufy não liberou o controle remoto")) }
        guard let identity = ClientIdentity.make(certificatePEM: certificate, keyPEM: key, label: "Lar – Eufy \(thing)") else {
            throw ProviderError.api(tr("Não deu para usar o certificado da Eufy neste aparelho"))
        }
        let host = endpoint.split(separator: ":").first.map(String.init) ?? endpoint
        let client = MQTTClient(.init(host: host, port: 8883, clientID: "android-\(info.string("app_name") ?? "eufy_home")-eufy_android_\(account["openudid"] ?? "")_\(userID)-\(Int(Date().timeIntervalSince1970 * 1000))",
                                      username: thing, identity: identity))
        mqtt = (client, userID, info.string("app_name") ?? "eufy_home")
        return mqtt!
    }
}

/// A TLS client identity (certificate and private key, from PEM) for the brands that sign in to MQTT with one. Made
/// through the keychain, the only way Apple's systems pair a key with its certificate.
enum ClientIdentity {
    static func make(certificatePEM: String, keyPEM: String, label: String) -> SecIdentity? {
        guard let certificateDER = der(certificatePEM),
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let keyDER = der(keyPEM) else { return nil }
        // PKCS#8 wraps the RSA key; Apple takes the PKCS#1 inside.
        let pkcs1 = keyPEM.contains("BEGIN RSA PRIVATE KEY") ? keyDER : (pkcs8Inner(keyDER) ?? keyDER)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { return nil }
        let tag = Data(label.utf8)
        let common: [CFString: Any] = [kSecUseDataProtectionKeychain: true]
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag].merging(common) { $1 } as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label].merging(common) { $1 } as CFDictionary)
        SecItemAdd([kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrApplicationTag: tag, kSecAttrLabel: label,
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly].merging(common) { $1 } as CFDictionary, nil)
        SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label,
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly].merging(common) { $1 } as CFDictionary, nil)
        var identity: CFTypeRef?
        SecIdentityCreateWithCertificateIfPossible(certificate, &identity)
        return identity.map { $0 as! SecIdentity }
    }

    /// The identity the keychain forms from the certificate and its key, once both are in.
    private static func SecIdentityCreateWithCertificateIfPossible(_ certificate: SecCertificate, _ out: inout CFTypeRef?) {
        let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll,
                                      kSecUseDataProtectionKeychain: true]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let identities = items as? [SecIdentity] else { return }
        let wanted = SecCertificateCopyData(certificate) as Data
        for identity in identities {
            var found: SecCertificate?
            if SecIdentityCopyCertificate(identity, &found) == errSecSuccess, let found, SecCertificateCopyData(found) as Data == wanted {
                out = identity
                return
            }
        }
    }

    static func der(_ pem: String) -> Data? {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The private key inside PKCS#8: SEQUENCE { version, algorithm, OCTET STRING { key } }.
    static func pkcs8Inner(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        func length(_ index: inout Int) -> Int? {
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
        var index = 1
        guard bytes.first == 0x30, length(&index) != nil, index < bytes.count, bytes[index] == 0x02 else { return nil }
        index += 1
        guard let version = length(&index) else { return nil }
        index += version
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithm = length(&index) else { return nil }
        index += algorithm
        guard index < bytes.count, bytes[index] == 0x04 else { return nil }
        index += 1
        guard let key = length(&index), index + key <= bytes.count else { return nil }
        return Data(bytes[index..<index + key])
    }
}

/// Eufy's RoboVacs in the list: on is cleaning, off is back to the dock.
public struct EufyProvider: DeviceProvider {
    public let provider = Provider.eufy
    let client: EufyClient

    public func devices() async throws -> [HomeDevice] {
        try await client.robots().map(Self.device).sorted { $0.name < $1.name }
    }

    static func device(_ robot: EufyClient.Robot) -> HomeDevice {
        let status = EufyClient.status(robot.dps)
        var parts: [String] = []
        if let status {
            parts.append(EufyClient.stateText(status))
            if let battery = status.battery { parts.append(tr("bateria \(battery)%")) }
        }
        return HomeDevice(provider: .eufy, rawID: robot.serial, name: robot.name, kind: .vacuum, isOnline: robot.online,
                          isOn: status.map(EufyClient.isCleaning), detail: parts.joined(separator: " · "))
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command, let robot = try await client.robots().first(where: { $0.serial == device.rawID }) else {
            throw ProviderError.unsupported
        }
        try await client.send(start: on, to: robot)
    }
}
