import Foundation

/// Yale Access (the August platform), as the open yalexs library documents it: a session with the e-mail and the
/// password, confirmed once by a code sent by e-mail; then the locks, locked or not, the door and the battery. The
/// password isn't kept: the session's token is renewed at each use. Yale Home's newer accounts only sign in through
/// partners (OAuth), so they aren't reachable. Unofficial: Yale may change it.
public actor YaleClient {
    static let base = "https://api-production.august.com"
    static let apiKey = "d9984f29-07a6-816e-e1c9-44ec9d1be431"

    struct Lock: Sendable, Equatable {
        var id: String
        var name: String
        var locked: Bool?
        var doorOpen: Bool?
        var battery: Int?
        var online: Bool
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let transport: HTTPTransport

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport) {
        self.account = account
        self.save = save
        self.transport = transport
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .yale,
        hint: tr("Entre com a conta do app Yale Access. As fechaduras aparecem na lista, trancadas ou não, com a porta e a bateria. Contas do app Yale Home novo não entram: a Yale só libera esse login para parceiros."),
        needsPassword: true,
        appName: "Yale Access"
    ) { email, password in
        let install = UUID().uuidString
        let (session, token) = try await openSession(email: email, password: password, install: install)
        guard session["vPassword"] as? Bool == true else { throw ProviderError.api(tr("E-mail ou senha errados")) }
        if session["vInstallId"] as? Bool == true {
            return .done(BrandAccount(email: email, values: ["install": install, "token": token]))
        }
        // A new install: Yale confirms it with a code by e-mail.
        _ = try await request("POST", "/validation/email", token: token, body: ["value": email])
        return .code(hint: tr("A Yale mandou um código para \(email).")) { code in
            let (answer, _) = try await request("POST", "/validate/email", token: token,
                                                body: ["email": email, "code": code.trimmingCharacters(in: .whitespaces)])
            if answer["code"] != nil, answer.string("message") != nil {
                throw ProviderError.api(tr("Código errado. Confira o e-mail e tente de novo."))
            }
            let (_, fresh) = try await openSession(email: email, password: password, install: install)
            return BrandAccount(email: email, values: ["install": install, "token": fresh])
        }
    }

    static func openSession(email: String, password: String, install: String) async throws -> ([String: Any], String) {
        let (body, token) = try await request("POST", "/session", token: nil,
                                              body: ["installId": install, "identifier": "email:" + email, "password": password])
        guard let token else { throw ProviderError.api(tr("E-mail ou senha errados")) }
        return (body, token)
    }

    /// One call; the answer and the renewed token Yale sends back in a header.
    static func request(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil,
                        transport: HTTPTransport = defaultTransport) async throws -> ([String: Any], String?) {
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 20)
        request.httpMethod = method
        for (key, value) in ["x-august-api-key": apiKey, "x-august-branding": "yale", "Accept-Version": "0.0.1",
                             "Content-Type": "application/json; charset=UTF-8", "x-august-country": "US",
                             "User-Agent": "August/Luna-22.17.0 (Android; SDK 31; gphone64_arm64)"] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let token { request.setValue(token, forHTTPHeaderField: "x-august-access-token") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        if http?.statusCode == 401 { throw ProviderError.unauthorized }
        if let status = http?.statusCode, status >= 400 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.string("message")
            throw ProviderError.api(message ?? tr("A Yale respondeu \(status)"))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (object, http?.value(forHTTPHeaderField: "x-august-access-token"))
    }

    private func call(_ method: String, _ path: String) async throws -> [String: Any] {
        guard let token = account["token"] else { throw ProviderError.unauthorized }
        let (body, renewed) = try await Self.request(method, path, token: token, transport: transport)
        if let renewed, renewed != token {
            account["token"] = renewed
            save(account)
        }
        return body
    }

    // MARK: Locks

    func locks() async throws -> [Lock] {
        let mine = try await call("GET", "/users/locks/mine")
        var out: [Lock] = []
        for id in mine.keys.sorted() {
            let summary = mine.dict(id)
            let detail = (try? await call("GET", "/locks/\(id)")) ?? [:]
            out.append(Self.lock(id: id, name: summary?.string("LockName") ?? detail.string("LockName") ?? "Yale", detail: detail))
        }
        return out
    }

    static func lock(id: String, name: String, detail: [String: Any]) -> Lock {
        let status = detail.dict("LockStatus")
        let state = status?.string("status")?.lowercased() ?? ""
        let door = status?.string("doorState")?.lowercased() ?? ""
        let locked: Bool? = state.contains("unlock") || state.contains("unlatch") ? false
            : state.contains("lock") || state.contains("securemode") ? true : nil
        let doorOpen: Bool? = door.hasSuffix("open") ? true : door.hasSuffix("closed") ? false : nil
        let battery = (detail["battery"] as? NSNumber).map { Int(($0.doubleValue * 100).rounded()) }
        let bridge = detail.dict("Bridge")?.dict("status")?.string("current")
        return Lock(id: id, name: name, locked: locked, doorOpen: doorOpen, battery: battery, online: bridge.map { $0 == "online" } ?? true)
    }
}

/// Yale's locks in the list, like the other locks: locked or not, the door and the battery in the detail; no switch.
public struct YaleProvider: DeviceProvider {
    public let provider = Provider.yale
    let client: YaleClient

    public func devices() async throws -> [HomeDevice] {
        try await client.locks().map(Self.device)
    }

    static func device(_ lock: YaleClient.Lock) -> HomeDevice {
        var parts: [String] = []
        if let locked = lock.locked { parts.append(locked ? tr("Trancada") : tr("Destrancada")) }
        if let open = lock.doorOpen { parts.append(open ? tr("Porta aberta") : tr("Porta fechada")) }
        if let battery = lock.battery { parts.append(tr("bateria \(battery)%")) }
        return HomeDevice(provider: .yale, rawID: lock.id, name: lock.name, kind: .lock, isOnline: lock.online,
                          detail: parts.joined(separator: " · "),
                          controls: lock.locked.map { ["locked": $0 ? "1" : "0"] } ?? [:])
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        throw ProviderError.unsupported
    }
}
