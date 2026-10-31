import Foundation

/// The Xbox account: Microsoft's refresh token (renewed at every use) and the gamertag Settings shows.
public struct XboxAccount: Codable, Sendable, Equatable {
    public var refreshToken: String
    public var gamertag: String

    public init(refreshToken: String, gamertag: String) {
        self.refreshToken = refreshToken
        self.gamertag = gamertag
    }
}

/// Xbox network's cloud, as the Xbox app uses it: the Microsoft account (Lar's own app registration, personal
/// accounts) → an Xbox Live user token → an XSTS token, then the consoles' remote management (xccs) and the
/// account's presence. Not a documented API for other apps: Microsoft may change it.
public actor XboxClient {
    /// Lar's registration with Microsoft (a public client: no secret).
    public static let clientID = "0938c7d7-8e69-4d5e-b1c8-2954dabee590"
    static let scope = "XboxLive.signin XboxLive.offline_access"
    static let login = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
    static let xccs = "https://xccs.xboxlive.com"

    public struct Console: Sendable, Equatable {
        public var id: String
        public var name: String
        /// On, ConnectedStandby (sleep: wakes from the cloud), Off (energy saving: doesn't), SystemUpdate, Unknown.
        public var powerState: String
        public var remoteManagementEnabled: Bool
    }

    public struct InstalledApp: Sendable, Equatable {
        public var productID: String
        public var name: String
        public var isGame: Bool
    }

    private var account: XboxAccount
    private let save: @Sendable (XboxAccount) -> Void
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var session: (header: String, xuid: String?, expires: Date)?
    private var renewal: Task<(header: String, xuid: String?, expires: Date), Error>?
    /// One per client, as the Xbox app does per run.
    private let sessionID = UUID().uuidString

    public init(account: XboxAccount, save: @escaping @Sendable (XboxAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.save = save
        self.transport = transport
        self.now = now
    }

    // MARK: Consoles

    public func consoles() async throws -> [Console] {
        let list = try await xccs("/lists/devices?queryCurrentDevice=false&includeStorageDevices=false")
        return (list["result"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Console(id: id, name: item["name"] as? String ?? "Xbox", powerState: item["powerState"] as? String ?? "Unknown",
                           remoteManagementEnabled: Self.flag(item["remoteManagementEnabled"]))
        }
    }

    /// The console's own state (fresher than the list's): power, and Playing/Paused/Stopped.
    public func status(of consoleID: String) async throws -> (power: String?, playback: String?) {
        let status = try await xccs("/consoles/\(consoleID)")
        return (status["powerState"] as? String, status["playbackState"] as? String)
    }

    /// Games and apps that can be opened (those with a store product), games last.
    public func installedApps(on consoleID: String) async throws -> [InstalledApp] {
        let list = try await xccs("/lists/installedApps?deviceId=\(consoleID)")
        var seen = Set<String>()
        let apps = (list["result"] as? [[String: Any]] ?? []).compactMap { item -> InstalledApp? in
            guard let product = item["oneStoreProductId"] as? String, !product.isEmpty,
                  let name = item["name"] as? String, seen.insert(product).inserted else { return nil }
            return InstalledApp(productID: product, name: name, isGame: Self.flag(item["isGame"]))
        }
        return apps.sorted { a, b in
            a.isGame != b.isGame ? !a.isGame : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What the account has open on a console in the foreground (nil: nothing, or only the Home screen).
    public func nowPlaying() async throws -> String? {
        let auth = try await authorization()
        guard let xuid = auth.xuid else { return nil }
        let presence = try await json(request("https://userpresence.xboxlive.com/users/xuid(\(xuid))?level=all",
                                              headers: ["Authorization": auth.header, "x-xbl-contract-version": "3"]))
        let titles = (presence["devices"] as? [[String: Any]] ?? []).flatMap { $0["titles"] as? [[String: Any]] ?? [] }
        return titles.first { ($0["placement"] as? String).map { ["Full", "Fill", "Snapped"].contains($0) } ?? false }?["name"] as? String
    }

    /// A remote management command: Power/WakeUp, Shell/InjectKey, Audio/Volume…
    public func command(_ type: String, _ command: String, parameters: [String: String] = [:], on consoleID: String) async throws {
        let body: [String: Any] = [
            "destination": "Xbox", "type": type, "command": command, "sessionId": sessionID,
            "sourceId": "com.microsoft.smartglass", "parameters": [parameters], "linkedXboxId": consoleID,
        ]
        let answer = try await xccs("/commands", body: body)
        let result = answer["result"] as? [String: Any] ?? answer["status"] as? [String: Any] ?? [:]
        if let code = result["errorCode"] as? String, code != "OK" {
            // ErrorCallingWNS: the cloud couldn't reach the console (asleep off the network, or remote features off).
            throw ProviderError.api(code == "ErrorCallingWNS"
                ? tr("O Xbox não respondeu: confira se está em Suspensão, com os recursos remotos ligados e na internet.")
                : tr("O Xbox recusou o comando (\(code))."))
        }
    }

    // MARK: Requests

    private func xccs(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let auth = try await authorization()
        let headers = ["Authorization": auth.header, "x-xbl-contract-version": "4", "skillplatform": "RemoteManagement"]
        return try await json(request(Self.xccs + path, json: body, headers: headers))
    }

    private func request(_ url: String, form: [String: String]? = nil, json body: [String: Any]? = nil,
                         headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = URL(string: url) else { throw ProviderError.unsupported }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formBody(form).utf8)
        } else if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        try await Self.send(request, transport: transport)
    }

    static func send(_ request: URLRequest, transport: HTTPTransport) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300: return object
        case 400 where object["error"] as? String == "invalid_grant", 401: throw ProviderError.unauthorized
        default:
            let message = object["error_description"] as? String ?? object["error"] as? String
            throw ProviderError.api(tr("Xbox: erro \(status)") + (message.map { " (\($0))" } ?? ""))
        }
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    static func flag(_ value: Any?) -> Bool {
        (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    // MARK: Tokens

    /// The XBL3.0 header (and the account's xuid), renewed a few minutes before it expires. One renewal at a time.
    private func authorization() async throws -> (header: String, xuid: String?, expires: Date) {
        if let session, session.expires > now().addingTimeInterval(300) { return session }
        if let renewal { return try await renewal.value }
        let task = Task { try await self.renew() }
        renewal = task
        defer { renewal = nil }
        let fresh = try await task.value
        session = fresh
        return fresh
    }

    private func renew() async throws -> (header: String, xuid: String?, expires: Date) {
        let oauth = try await json(request("\(Self.login)/token", form: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": account.refreshToken, "scope": Self.scope,
        ]))
        guard let access = oauth["access_token"] as? String else { throw ProviderError.unauthorized }
        if let refresh = oauth["refresh_token"] as? String, refresh != account.refreshToken {
            account.refreshToken = refresh
            save(account)
        }
        let xsts = try await Self.xsts(accessToken: access, transport: transport)
        if let gamertag = xsts.gamertag, gamertag != account.gamertag {
            account.gamertag = gamertag
            save(account)
        }
        return (xsts.header, xsts.xuid, xsts.expires ?? now().addingTimeInterval(3600))
    }

    struct XSTS {
        var header: String
        var xuid: String?
        var gamertag: String?
        var expires: Date?
    }

    /// Microsoft's access token → Xbox Live user token → XSTS for xboxlive.com.
    static func xsts(accessToken: String, transport: HTTPTransport) async throws -> XSTS {
        func post(_ url: String, _ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
                return try await send(request, transport: transport)
            } catch ProviderError.unauthorized {
                // XSTS says 401 for an account without an Xbox profile or a child's account too.
                throw ProviderError.api(tr("A conta Microsoft não tem perfil do Xbox, ou é de uma criança (precisa ser de um adulto)."))
            }
        }
        let user = try await post("https://user.auth.xboxlive.com/user/authenticate", [
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT",
            "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=\(accessToken)"],
        ])
        guard let userToken = user["Token"] as? String else { throw ProviderError.unauthorized }
        let xsts = try await post("https://xsts.auth.xboxlive.com/xsts/authorize", [
            "RelyingParty": "http://xboxlive.com", "TokenType": "JWT",
            "Properties": ["UserTokens": [userToken], "SandboxId": "RETAIL"],
        ])
        guard let token = xsts["Token"] as? String,
              let claims = ((xsts["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]])?.first,
              let hash = claims["uhs"] as? String else { throw ProviderError.unauthorized }
        let expires = (xsts["NotAfter"] as? String).flatMap { ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return XSTS(header: "XBL3.0 x=\(hash);\(token)", xuid: claims["xid"] as? String, gamertag: claims["gtg"] as? String,
                    expires: expires)
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Signing in with a code typed at microsoft.com/link: the same on every device, the Apple TV included (no
/// browser there), and the password never goes through Lar.
public enum XboxSignIn {
    public struct Code: Sendable, Equatable {
        public var userCode: String
        public var verificationURL: URL
        var deviceCode: String
        var interval: Int
        public var expires: Date
    }

    public static func start(transport: @escaping HTTPTransport = defaultTransport) async throws -> Code {
        var request = URLRequest(url: URL(string: "\(XboxClient.login)/devicecode")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(XboxClient.formBody(["client_id": XboxClient.clientID, "scope": XboxClient.scope]).utf8)
        let answer = try await XboxClient.send(request, transport: transport)
        guard let userCode = answer["user_code"] as? String, let deviceCode = answer["device_code"] as? String else {
            throw ProviderError.api(tr("A Microsoft não deu um código para entrar."))
        }
        let url = (answer["verification_uri"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://www.microsoft.com/link")!
        let seconds = (answer["expires_in"] as? NSNumber)?.doubleValue ?? 900
        return Code(userCode: userCode, verificationURL: url, deviceCode: deviceCode,
                    interval: (answer["interval"] as? NSNumber)?.intValue ?? 5, expires: Date().addingTimeInterval(seconds))
    }

    /// Waits for the code to be entered and approved; the account, or an error (declined, expired, cancelled).
    public static func finish(_ code: Code, transport: @escaping HTTPTransport = defaultTransport) async throws -> XboxAccount {
        var interval = max(code.interval, 1)
        while Date() < code.expires {
            try await Task.sleep(for: .seconds(interval))
            var request = URLRequest(url: URL(string: "\(XboxClient.login)/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(XboxClient.formBody([
                "client_id": XboxClient.clientID, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": code.deviceCode,
            ]).utf8)
            let (data, _) = try await transport(request)
            let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let access = answer["access_token"] as? String, let refresh = answer["refresh_token"] as? String {
                let xsts = try await XboxClient.xsts(accessToken: access, transport: transport)
                return XboxAccount(refreshToken: refresh, gamertag: xsts.gamertag ?? "Xbox")
            }
            switch answer["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "authorization_declined": throw ProviderError.api(tr("O acesso foi recusado na página da Microsoft."))
            case "expired_token": throw ProviderError.api(tr("O código expirou: peça outro."))
            default:
                throw ProviderError.api((answer["error_description"] as? String) ?? tr("A Microsoft não confirmou o login."))
            }
        }
        throw ProviderError.api(tr("O código expirou: peça outro."))
    }
}
