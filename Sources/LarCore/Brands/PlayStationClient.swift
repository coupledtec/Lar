import Foundation

/// PlayStation Network, as the PlayStation app and the open psn-api and PSNAWP libraries use it: signing in takes the
/// "npsso" token of a browser session on playstation.com (Sony has no login for other apps), exchanged for a code and
/// then for an access token, renewed by its refresh token (about two months). Then the consoles on the account (PS5
/// and PS4) and the owner's presence: online or not, on which console, and the game being played. Read only: turning
/// a console on or off takes Remote Play's pairing. Unofficial: Sony may change it.
public actor PlayStationClient {
    static let auth = "https://ca.account.sony.com/api/authz/v3/oauth"
    static let clientID = "09515159-7237-4370-9b40-3806e67c0891"
    /// The PlayStation app's client (public, the same in every library): "client id:secret" in Base64.
    static let basic = "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="
    static let redirect = "com.scee.psxandroid.scecompcall://redirect"
    static let scope = "psn:mobile.v2.core psn:clientapp"
    static let tokenPage = "https://ca.account.sony.com/api/v1/ssocookie"

    struct Console: Sendable, Equatable {
        var id: String
        /// "PS5", "PS4".
        var type: String
    }

    struct Presence: Sendable, Equatable {
        var online: Bool
        /// The console it's online on ("PS5", "PS4", "PSPC", "MOBILE_APP").
        var platform: String?
        var game: String?
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let http: BrandHTTP

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport) {
        self.account = account
        self.save = save
        self.http = BrandHTTP(transport: transport)
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .playstation,
        hint: tr("1. Entre na sua conta em playstation.com no navegador. 2. Na mesma janela, abra ca.account.sony.com/api/v1/ssocookie. 3. Copie o valor de \"npsso\" (64 letras e números) e cole aqui. O PS5 e o PS4 aparecem em Jogos, com o jogo do momento."),
        needsPassword: true,
        appName: "PlayStation",
        token: BrandToken(label: tr("Token npsso"), link: tokenPage)
    ) { _, npsso in
        let npsso = npsso.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\""))
        let code = try await accessCode(npsso: npsso)
        var account = BrandAccount(email: "PlayStation")
        try await tokens(["code": code, "redirect_uri": redirect, "grant_type": "authorization_code", "token_format": "jwt"],
                         into: &account, http: BrandHTTP(transport: defaultTransport))
        // The account's name for the settings (the online ID), and its id for the presence.
        let client = PlayStationClient(account: account)
        let me = try await client.me()
        account.email = me.onlineID ?? "PlayStation"
        account["accountID"] = me.accountID
        return .done(account)
    }

    /// The npsso token for a one-time code: Sony answers with a redirect to the PlayStation app carrying it.
    static func accessCode(npsso: String) async throws -> String {
        guard npsso.count >= 32 else { throw ProviderError.api(tr("Cole o valor de \"npsso\" inteiro.")) }
        var components = URLComponents(string: auth + "/authorize")!
        components.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect())
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
        guard let code = code(fromRedirect: location) else {
            throw ProviderError.api(tr("A Sony não aceitou o token. Pegue um npsso novo (ele vale por pouco tempo) e tente de novo."))
        }
        return code
    }

    /// The code in "com.scee…://redirect/?code=v3.XXXX&cid=…".
    static func code(fromRedirect location: String) -> String? {
        guard let query = location.components(separatedBy: "?").dropFirst().first else { return nil }
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2, parts[0] == "code", !parts[1].isEmpty { return parts[1].removingPercentEncoding ?? parts[1] }
        }
        return nil
    }

    /// Stops at the redirect, to read where it goes.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// A token call (from the code or the refresh token), kept in the account.
    static func tokens(_ form: [String: String], into account: inout BrandAccount, http: BrandHTTP) async throws {
        let answer = try await http.json("POST", auth + "/token", form: form, headers: ["Authorization": basic])
        guard let access = answer.string("access_token") else {
            throw ProviderError.api(answer.string("error_description") ?? tr("A Sony não devolveu o acesso."))
        }
        account["access"] = access
        account["expires"] = String(Int(Date().timeIntervalSince1970) + (answer.int("expires_in") ?? 3600) - 60)
        if let refresh = answer.string("refresh_token") { account["refresh"] = refresh }
    }

    private func accessToken() async throws -> String {
        if let access = account["access"], let expires = account["expires"].flatMap(Int.init),
           Int(Date().timeIntervalSince1970) < expires {
            return access
        }
        guard let refresh = account["refresh"] else { throw ProviderError.unauthorized }
        var renewed = account
        do {
            try await Self.tokens(["refresh_token": refresh, "grant_type": "refresh_token", "token_format": "jwt", "scope": Self.scope],
                                  into: &renewed, http: http)
            account = renewed
        } catch ProviderError.api {
            // The refresh token ran out (about two months): a new npsso is needed.
            throw ProviderError.unauthorized
        }
        save(account)
        return account["access"] ?? ""
    }

    private func get(_ url: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let token = try await accessToken()
        return try await http.json("GET", url, query: query, headers: ["Authorization": "Bearer \(token)", "Accept-Language": "pt-BR"])
    }

    // MARK: Consoles and presence

    func me() async throws -> (accountID: String, onlineID: String?) {
        let answer = try await get("https://dms.api.playstation.com/api/v1/devices/accounts/me")
        guard let id = answer.string("accountId") else { throw ProviderError.api(tr("A Sony não devolveu a conta.")) }
        let profile = try? await get("https://m.np.playstation.com/api/userProfile/v1/internal/users/\(id)/profiles")
        return (id, profile?.string("onlineId"))
    }

    func consoles() async throws -> [Console] {
        let answer = try await get("https://dms.api.playstation.com/api/v1/devices/accounts/me",
                                   query: ["includeFields": "device,systemData", "platform": "PS5,PS4"])
        return Self.consoles(answer)
    }

    static func consoles(_ answer: [String: Any]) -> [Console] {
        answer.list("accountDevices").compactMap { device in
            guard let id = device.string("deviceId"), let type = device.string("deviceType"), type == "PS5" || type == "PS4" else { return nil }
            return Console(id: id, type: type)
        }
    }

    func presence() async throws -> Presence {
        var id = account["accountID"]
        if id == nil {
            id = try await me().accountID
            account["accountID"] = id
            save(account)
        }
        let answer = try await get("https://m.np.playstation.com/api/userProfile/v1/internal/users/\(id ?? "me")/basicPresences",
                                   query: ["type": "primary"])
        return Self.presence(answer)
    }

    static func presence(_ answer: [String: Any]) -> Presence {
        let basic = answer.dict("basicPresence") ?? answer
        let platform = basic.dict("primaryPlatformInfo")
        let online = platform?.string("onlineStatus") == "online"
        let game = basic.list("gameTitleInfoList").first?.string("titleName")
        return Presence(online: online, platform: platform?.string("platform")?.uppercased(), game: online ? game : nil)
    }
}

/// The consoles in "Jogos": on (the owner online on it) with the game, or off/at rest. No switch: Sony only turns
/// them on and off through Remote Play.
public struct PlayStationProvider: DeviceProvider {
    public let provider = Provider.playstation
    let client: PlayStationClient

    public func devices() async throws -> [HomeDevice] {
        let consoles = try await client.consoles()
        let presence = try await client.presence()
        return Self.devices(consoles, presence: presence)
    }

    static func devices(_ consoles: [PlayStationClient.Console], presence: PlayStationClient.Presence) -> [HomeDevice] {
        var seen: [String: Int] = [:]
        return consoles.map { console in
            seen[console.type, default: 0] += 1
            let count = seen[console.type] ?? 1
            let name = count == 1 ? console.type : "\(console.type) (\(count))"
            // The presence names the platform, not which console: the first of that type is the one in use.
            let inUse = presence.online && presence.platform == console.type && count == 1
            let detail = inUse ? (presence.game ?? tr("Ligado")) : tr("Desligado ou em repouso")
            return HomeDevice(provider: .playstation, rawID: console.id, name: name, kind: .gameConsole,
                              detail: detail, controls: ["playing": inUse ? "1" : "0"])
        }
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        throw ProviderError.unsupported
    }
}
