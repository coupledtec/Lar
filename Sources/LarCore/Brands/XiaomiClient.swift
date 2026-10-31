import Foundation

/// Xiaomi's cloud (Mi Home), as the Mi Home app uses it (the open Xiaomi-cloud-tokens-extractor documents it):
/// sign-in with the password and, when Xiaomi asks, a code sent by e-mail; requests wrapped in RC4 and signed; the
/// robots' and locks' state and actions through MIoT (`MIoTMap`). The password isn't kept: the pass token renews
/// the session. Unofficial: Xiaomi may change it.
public actor XiaomiClient {
    /// Xiaomi's regional servers; an account's devices live in one of them (the one chosen in Mi Home).
    static let servers = ["us", "de", "sg", "i2", "ru", "cn", "in"]

    struct Device: Codable, Sendable, Equatable {
        var did: String
        var name: String
        var model: String
        var online: Bool
        var server: String
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let session = XiaomiSession()

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in }) {
        self.account = account
        self.save = save
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .xiaomi,
        hint: tr("Entre com a conta do app Mi Home (Xiaomi Home). Robôs aspiradores da Xiaomi e de outras marcas no Mi Home (Dreame, Roborock antigos) e fechaduras com Wi-Fi aparecem na lista."),
        needsPassword: true,
        appName: "Mi Home"
    ) { email, password in
        let session = XiaomiSession()
        switch try await session.login(user: email, password: password) {
        case .done(let values): return .done(BrandAccount(email: email, values: values))
        case .code(let finish):
            return .code(hint: tr("A Xiaomi mandou um código para o e-mail da conta. Digite aqui.")) { code in
                BrandAccount(email: email, values: try await finish(code))
            }
        }
    }

    // MARK: Devices

    func devices() async throws -> [Device] {
        var found: [Device] = []
        let known = account["servers"]?.split(separator: ",").map(String.init)
        for server in known ?? Self.servers {
            let result = try await call(server, "/home/device_list",
                                        ["getVirtualModel": true, "getHuamiDevices": 1, "get_split_device": false, "support_smart_home": true])
            let list = (result["result"] as? [String: Any])?.list("list") ?? []
            found += list.compactMap { item in
                guard let did = item.string("did"), let model = item.string("model") else { return nil }
                return Device(did: did, name: item.string("name") ?? model, model: model,
                              online: item["isOnline"] as? Bool ?? true, server: server)
            }
        }
        if known == nil {
            // Asking every server takes a while: remember the ones that have devices.
            let used = Set(found.map(\.server))
            account["servers"] = (used.isEmpty ? ["us"] : Self.servers.filter(used.contains)).joined(separator: ",")
            save(account)
        }
        return found
    }

    /// The robot and lock maps of these models, read from miot-spec.org once and kept in the account ("" for models
    /// that are neither).
    func maps(for models: Set<String>) async throws -> [String: MIoTMap] {
        var known = account.decoded([String: MIoTMap?].self, "maps") ?? [:]
        let missing = models.subtracting(known.keys)
        if !missing.isEmpty {
            let found = try await MIoTSpecs.maps(for: missing, http: BrandHTTP(transport: defaultTransport))
            for model in missing { known[model] = .some(found[model]) }
            account.encode(known, "maps")
            save(account)
        }
        return known.compactMapValues { $0 }
    }

    func read(_ properties: [MIoTMap.Property], of device: Device) async throws -> [MIoTMap.Property: MIoTValue] {
        guard !properties.isEmpty else { return [:] }
        let result = try await call(device.server, "/miotspec/prop/get", [
            "params": properties.map { ["did": device.did, "siid": $0.siid, "piid": $0.piid] },
        ])
        var out: [MIoTMap.Property: MIoTValue] = [:]
        for item in result["result"] as? [[String: Any]] ?? [] where item.int("code") == 0 {
            if let siid = item.int("siid"), let piid = item.int("piid"), let value = item["value"].flatMap(MIoTValue.init) {
                out[MIoTMap.Property(siid: siid, piid: piid)] = value
            }
        }
        return out
    }

    func run(_ action: MIoTMap.Action, on device: Device) async throws {
        let result = try await call(device.server, "/miotspec/action", [
            "params": ["did": device.did, "siid": action.siid, "aiid": action.aiid, "in": [Any]()],
        ])
        if let code = (result["result"] as? [String: Any])?.int("code"), code != 0 {
            throw ProviderError.api(tr("O aparelho recusou o comando (\(code))"))
        }
    }

    // MARK: Requests

    private func call(_ server: String, _ path: String, _ data: [String: Any]) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self)
        do {
            return try await session.call(server: server, path: path, json: json, account: account.values)
        } catch ProviderError.unauthorized {
            // The service token expired: a new one from the pass token, without the password.
            let renewed = try await session.renew(account.values)
            account.values.merge(renewed) { _, new in new }
            save(account)
            return try await session.call(server: server, path: path, json: json, account: account.values)
        }
    }
}

/// Xiaomi's sign-in and requests: cookies of its own and redirects followed only when asked.
final class XiaomiSession: @unchecked Sendable {
    enum Login {
        case done([String: String])
        case code(@Sendable (String) async throws -> [String: String])
    }

    private let cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: UUID().uuidString)
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookies
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    let deviceID = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    let agent = String((0..<18).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! }) + "-"
        + String((0..<13).map { _ in "ABCDE".randomElement()! }) + " APP/com.xiaomi.mihome APPV/10.5.201"

    private func setCookie(_ name: String, _ value: String, domain: String) {
        if let cookie = HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"]) {
            cookies.setCookie(cookie)
        }
    }

    private func cookie(_ name: String) -> String? {
        cookies.cookies?.first { $0.name == name && !$0.value.isEmpty }?.value
    }

    private func get(_ url: String, query: [String: String] = [:], follow: Bool = true) async throws -> (Data, HTTPURLResponse) {
        try await send("GET", url, query: query, form: nil, follow: follow)
    }

    private func send(_ method: String, _ url: String, query: [String: String] = [:], form: [String: String]?,
                      follow: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: url) else { throw ProviderError.api("URL") }
        if !query.isEmpty {
            components.percentEncodedQuery = [components.percentEncodedQuery, BrandHTTP.formEncoded(query)]
                .compactMap { $0 }.joined(separator: "&")
        }
        guard let address = components.url else { throw ProviderError.api("URL") }
        var request = URLRequest(url: address)
        request.httpMethod = method
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let form { request.httpBody = Data(BrandHTTP.formEncoded(form).utf8) }
        do {
            let (data, response) = try await urlSession.data(for: request, delegate: follow ? nil : NoRedirect())
            guard let http = response as? HTTPURLResponse else { throw ProviderError.network("HTTP") }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }

    /// Stops at a redirect, to read where it goes (and the headers that come with it).
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func json(_ data: Data) -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "&&&START&&&", with: "")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: Sign-in

    func login(user: String, password: String) async throws -> Login {
        for domain in ["mi.com", "xiaomi.com"] {
            setCookie("sdkVersion", "accountsdk-18.8.15", domain: domain)
            setCookie("deviceId", deviceID, domain: domain)
        }
        setCookie("userId", user, domain: "account.xiaomi.com")
        let (first, _) = try await get("https://account.xiaomi.com/pass/serviceLogin", query: ["sid": "xiaomiio", "_json": "true"])
        guard let sign = Self.json(first).string("_sign") else { throw ProviderError.api(tr("Conta Xiaomi não encontrada")) }
        let (second, _) = try await send("POST", "https://account.xiaomi.com/pass/serviceLoginAuth2", query: [
            "sid": "xiaomiio", "hash": BrandCrypto.md5Hex(password).uppercased(), "callback": "https://sts.api.io.mi.com/sts",
            "qs": "%3Fsid%3Dxiaomiio%26_json%3Dtrue", "user": user, "_sign": sign, "_json": "true",
        ], form: [:], follow: false)
        let answer = Self.json(second)
        if let ssecurity = answer.string("ssecurity"), ssecurity.count > 4, let location = answer.string("location") {
            return .done(try await finish(ssecurity: ssecurity, location: location, answer: answer))
        }
        if let notification = answer.string("notificationUrl") {
            try await startEmailCheck(notification)
            return .code { code in try await self.finishEmailCheck(notification, code: code) }
        }
        if answer.string("captchaUrl") != nil {
            throw ProviderError.api(tr("A Xiaomi pediu um captcha. Entre uma vez no app Mi Home neste aparelho e tente de novo mais tarde."))
        }
        throw ProviderError.api(tr("E-mail ou senha errados"))
    }

    /// The service token, from the location the sign-in returned.
    private func finish(ssecurity: String, location: String, answer: [String: Any]) async throws -> [String: String] {
        _ = try await get(location)
        guard let token = cookie("serviceToken") else { throw ProviderError.api(tr("A Xiaomi não devolveu a sessão")) }
        return ["ssecurity": ssecurity, "serviceToken": token, "deviceId": deviceID,
                "userId": answer.string("userId") ?? cookie("userId") ?? "",
                "cUserId": answer.string("cUserId") ?? cookie("cUserId") ?? "",
                "passToken": answer.string("passToken") ?? cookie("passToken") ?? ""]
    }

    private func context(_ notification: String) -> String {
        URLComponents(string: notification)?.queryItems?.first { $0.name == "context" }?.value ?? ""
    }

    private func startEmailCheck(_ notification: String) async throws {
        _ = try await get(notification)
        let context = context(notification)
        _ = try await get("https://account.xiaomi.com/identity/list", query: ["sid": "xiaomiio", "context": context, "_locale": "en_US"])
        _ = try await send("POST", "https://account.xiaomi.com/identity/auth/sendEmailTicket", query: [
            "_dc": String(Int(Date().timeIntervalSince1970 * 1000)), "sid": "xiaomiio", "context": context, "mask": "0", "_locale": "en_US",
        ], form: ["retry": "0", "icode": "", "_json": "true", "ick": cookie("ick") ?? ""])
    }

    private func finishEmailCheck(_ notification: String, code: String) async throws -> [String: String] {
        let context = context(notification)
        let (verified, response) = try await send("POST", "https://account.xiaomi.com/identity/auth/verifyEmail", query: [
            "_flag": "8", "_json": "true", "sid": "xiaomiio", "context": context, "mask": "0", "_locale": "en_US",
        ], form: ["_flag": "8", "ticket": code.trimmingCharacters(in: .whitespaces), "trust": "true", "_json": "true", "ick": cookie("ick") ?? ""])
        var next = Self.json(verified).string("location") ?? response.value(forHTTPHeaderField: "Location")
        if Self.json(verified).int("code").map({ $0 != 0 }) == true, next == nil {
            throw ProviderError.api(tr("Código errado. Confira o e-mail e tente de novo."))
        }
        if next == nil {
            let (_, check) = try await get("https://account.xiaomi.com/identity/result/check",
                                           query: ["sid": "xiaomiio", "context": context, "_locale": "en_US"], follow: false)
            next = check.value(forHTTPHeaderField: "Location")
        }
        guard var end = next else { throw ProviderError.api(tr("A Xiaomi não confirmou o código")) }
        if end.contains("identity/result/check") {
            let (_, hop) = try await get(end, follow: false)
            end = hop.value(forHTTPHeaderField: "Location") ?? end
        }
        var (body, last) = try await get(end, follow: false)
        if last.statusCode == 200, String(decoding: body, as: UTF8.self).contains("Tips") {
            (body, last) = try await get(end, follow: false)
        }
        let pragma = last.value(forHTTPHeaderField: "extension-pragma").map { Self.json(Data($0.utf8)) } ?? [:]
        guard let ssecurity = pragma.string("ssecurity") else { throw ProviderError.api(tr("A Xiaomi não devolveu a sessão")) }
        guard let sts = last.value(forHTTPHeaderField: "Location") else { throw ProviderError.api(tr("A Xiaomi não devolveu a sessão")) }
        return try await finish(ssecurity: ssecurity, location: sts, answer: [:])
    }

    /// A new service token from the pass token (no password, no code).
    func renew(_ values: [String: String]) async throws -> [String: String] {
        guard let pass = values["passToken"], !pass.isEmpty, let user = values["userId"] else { throw ProviderError.unauthorized }
        for (name, value) in [("passToken", pass), ("userId", user), ("deviceId", values["deviceId"] ?? deviceID)] {
            setCookie(name, value, domain: "account.xiaomi.com")
        }
        let (data, _) = try await get("https://account.xiaomi.com/pass/serviceLogin", query: ["sid": "xiaomiio", "_json": "true"])
        let answer = Self.json(data)
        guard let ssecurity = answer.string("ssecurity"), let location = answer.string("location") else { throw ProviderError.unauthorized }
        var renewed = try await finish(ssecurity: ssecurity, location: location, answer: answer)
        if renewed["passToken"]?.isEmpty != false { renewed["passToken"] = pass }
        return renewed
    }

    // MARK: Encrypted requests

    func call(server: String, path: String, json: String, account: [String: String]) async throws -> sending [String: Any] {
        guard let ssecurity = account["ssecurity"], let token = account["serviceToken"] else { throw ProviderError.unauthorized }
        let base = "https://" + (server == "cn" ? "" : server + ".") + "api.io.mi.com/app"
        let nonce = XiaomiSigner.nonce()
        let fields = try XiaomiSigner.encryptedParams(path: path, nonce: nonce, ssecurity: ssecurity, params: [("data", json)])
        guard var components = URLComponents(string: base + path) else { throw ProviderError.api("URL") }
        components.percentEncodedQuery = fields.map { "\($0.0)=\(BrandHTTP.formEncoded([$0.0: $0.1]).dropFirst($0.0.count + 1))" }
            .joined(separator: "&")
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "POST"
        for (key, value) in ["Accept-Encoding": "identity", "User-Agent": agent, "Content-Type": "application/x-www-form-urlencoded",
                             "x-xiaomi-protocal-flag-cli": "PROTOCAL-HTTP2", "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4"] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let cookieHeader = ["userId": account["userId"] ?? "", "yetAnotherServiceToken": token, "serviceToken": token,
                            "locale": "en_GB", "timezone": "GMT-03:00", "is_daylight": "0", "dst_offset": "0", "channel": "MI_APP_STORE"]
            .map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ProviderError.unauthorized }
        guard status == 200 else { throw ProviderError.api(tr("A Xiaomi respondeu \(status)")) }
        let decrypted = try XiaomiSigner.decrypt(String(decoding: body, as: UTF8.self), nonce: nonce, ssecurity: ssecurity)
        guard let object = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
            throw ProviderError.api(tr("Resposta inesperada da Xiaomi"))
        }
        if let code = object.int("code"), code == 2 || code == 3 { throw ProviderError.unauthorized }
        return object
    }
}

/// Xiaomi's request signing: a nonce (random bytes and the minute), the "signed nonce" (SHA-256 of the session's
/// secret and the nonce), RC4 over each parameter and a SHA-1 signature of it all.
enum XiaomiSigner {
    static func nonce(random: Data = Data((0..<8).map { _ in UInt8.random(in: 0...255) }), millis: Int = Int(Date().timeIntervalSince1970 * 1000)) -> String {
        var data = random
        let minutes = UInt32(millis / 60000)
        withUnsafeBytes(of: minutes.bigEndian) { data.append(contentsOf: $0) }
        return data.base64EncodedString()
    }

    static func signedNonce(_ nonce: String, ssecurity: String) throws -> String {
        guard let secret = Data(base64Encoded: ssecurity), let once = Data(base64Encoded: nonce) else { throw ProviderError.unauthorized }
        return BrandCrypto.sha256(secret + once).base64EncodedString()
    }

    static func signature(method: String = "POST", path: String, params: [(String, String)], signedNonce: String) -> String {
        let text = ([method.uppercased(), path] + params.map { "\($0.0)=\($0.1)" } + [signedNonce]).joined(separator: "&")
        return BrandCrypto.sha1(Data(text.utf8)).base64EncodedString()
    }

    static func rc4(_ signedNonce: String, _ data: Data) -> Data {
        BrandCrypto.rc4(key: Data(base64Encoded: signedNonce) ?? Data(), data)
    }

    /// The query of an encrypted call: each parameter and its hash in RC4, the signature, the secret and the nonce.
    static func encryptedParams(path: String, nonce: String, ssecurity: String, params: [(String, String)]) throws -> [(String, String)] {
        let signed = try signedNonce(nonce, ssecurity: ssecurity)
        var all = params
        all.append(("rc4_hash__", signature(path: path, params: params, signedNonce: signed)))
        let encrypted = all.map { ($0.0, rc4(signed, Data($0.1.utf8)).base64EncodedString()) }
        return encrypted + [("signature", signature(path: path, params: encrypted, signedNonce: signed)),
                            ("ssecurity", ssecurity), ("_nonce", nonce)]
    }

    static func decrypt(_ body: String, nonce: String, ssecurity: String) throws -> Data {
        guard let data = Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProviderError.api(tr("Resposta inesperada da Xiaomi"))
        }
        return rc4(try signedNonce(nonce, ssecurity: ssecurity), data)
    }
}
