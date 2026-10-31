import CryptoKit
import Foundation
import os

// Alexa has no public API for the Echos: this follows what the Alexa app itself does, as the open-source
// aioamazondevices (Simone Chemelli and contributors, Apache-2.0; the base of Home Assistant's "Alexa Devices") and
// alexa-remote (Apollon77, MIT) do. Amazon can change it at any time.

/// The Amazon account the Lar signed in to, registered as one of the account's devices (like the Alexa app): the
/// refresh token gets fresh cookies whenever the old ones stop working. Kept in the keychain.
public struct AlexaAccount: Codable, Sendable, Equatable {
    /// "com.br", "com", "co.uk"…: the account's Amazon site.
    public var domain: String
    /// The serial the Lar registered with (it stays the same across sign-ins).
    public var serial: String
    public var refreshToken: String
    /// The website cookies the Alexa site takes (session-token, at-main, ubid-main…).
    public var cookies: [String: String]
    public var customerID: String?
    public var language: String

    public init(domain: String, serial: String, refreshToken: String, cookies: [String: String], customerID: String?,
                language: String) {
        self.domain = domain
        self.serial = serial
        self.refreshToken = refreshToken
        self.cookies = cookies
        self.customerID = customerID
        self.language = language
    }

    var alexaSite: URL { URL(string: "https://alexa.amazon.\(domain)")! }
    var retailHost: String { "www.amazon.\(domain)" }
}

/// What the Alexa app says it is (Amazon gives a mobile app's registration these values).
enum AlexaApp {
    static let deviceType = "A2IVLV5VM2W81"
    static let appVersion = "2.2.663733.0"
    static let softwareVersion = "35602678"
    static let osVersion = "18.5"
    static let appName = "Lar"
    static let bundleID = "com.amazon.echo"
    static let appID = "MAPiOSLib/6.0/ToHideRetailLink"
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let appAgent = "AmazonWebView/AmazonAlexa/\(appVersion)/iOS/\(osVersion)/iPhone"
    static let api = URL(string: "https://api.amazon.com")!
}

/// The Amazon site of a country (the Alexa site is "alexa.amazon." + this).
public enum AlexaRegion {
    public static func domain(for country: String = HomeRegion.country) -> String {
        switch country.uppercased() {
        case "BR": "com.br"
        case "GB", "UK": "co.uk"
        case "JP": "co.jp"
        case "MX": "com.mx"
        case "AU": "com.au"
        case "DE", "AT": "de"
        case "FR", "BE": "fr"
        case "IT": "it"
        case "ES": "es"
        case "CA": "ca"
        case "IN": "in"
        case "NL": "nl"
        default: "com"
        }
    }

    public static func language(for country: String = HomeRegion.country) -> String {
        switch country.uppercased() {
        case "BR": "pt-BR"
        case "GB", "UK": "en-GB"
        case "JP": "ja-JP"
        case "MX": "es-MX"
        case "AU": "en-AU"
        case "DE", "AT": "de-DE"
        case "FR", "BE": "fr-FR"
        case "IT": "it-IT"
        case "ES": "es-ES"
        case "CA": "en-CA"
        case "IN": "en-IN"
        case "NL": "nl-NL"
        default: "en-US"
        }
    }
}

// MARK: - Signing in

/// The sign-in: Amazon's own page (it asks for the password and the second step, any kind), then the answer's code
/// registers the Lar as a device of the account.
public enum AlexaSignIn {
    /// One sign-in attempt: the PKCE pair and the cookies Amazon's mobile login expects.
    public struct Attempt: Sendable {
        public let domain: String
        public let language: String
        public let serial: String
        let verifier: String
        /// A random device fingerprint cookie, repeated at the registration.
        let frc: String
        let mapMD: String

        public init(domain: String = AlexaRegion.domain(), language: String = AlexaRegion.language(), serial: String? = nil) {
            self.domain = domain
            self.language = language
            self.serial = serial ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
            verifier = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            frc = Data((0..<313).map { _ in UInt8.random(in: 0...255) }).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let metadata = #"{"device_user_dictionary":[],"device_registration_data":{"software_version":"\#(AlexaApp.softwareVersion)"},"app_identifier":{"app_version":"\#(AlexaApp.appVersion)","bundle_id":"\#(AlexaApp.bundleID)"}}"#
            mapMD = Data(metadata.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        var clientID: String { Data("\(serial)#\(AlexaApp.deviceType)".utf8).map { String(format: "%02x", $0) }.joined() }
        var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

        /// The cookies to set on Amazon's domains before opening the page (they spare most captchas).
        public var cookies: [(name: String, value: String)] {
            [("frc", frc), ("map-md", mapMD), ("amzn-app-id", AlexaApp.appID)]
        }

        /// The Alexa app's sign-in handle: the US one, or with the country's suffix ("…_br"): the country's site
        /// answers "page not found" to the plain one.
        var handle: String {
            let country = domain.split(separator: ".").last.map(String.init) ?? "com"
            return country == "com" ? "amzn_dp_project_dee_ios" : "amzn_dp_project_dee_ios_\(country)"
        }

        public var url: URL {
            var components = URLComponents(string: "https://www.amazon.\(domain)/ap/signin")!
            components.queryItems = [
                URLQueryItem(name: "openid.return_to", value: "https://www.amazon.\(domain)/ap/maplanding"),
                URLQueryItem(name: "openid.oa2.code_challenge_method", value: "S256"),
                URLQueryItem(name: "openid.assoc_handle", value: handle),
                URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
                URLQueryItem(name: "pageId", value: handle),
                URLQueryItem(name: "accountStatusPolicy", value: "P1"),
                URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select"),
                URLQueryItem(name: "openid.mode", value: "checkid_setup"),
                URLQueryItem(name: "openid.ns.oa2", value: "http://www.amazon.com/ap/ext/oauth/2"),
                URLQueryItem(name: "openid.oa2.client_id", value: "device:\(clientID)"),
                URLQueryItem(name: "language", value: language.replacingOccurrences(of: "-", with: "_")),
                URLQueryItem(name: "openid.ns.pape", value: "http://specs.openid.net/extensions/pape/1.0"),
                URLQueryItem(name: "openid.oa2.code_challenge", value: challenge),
                URLQueryItem(name: "openid.oa2.scope", value: "device_auth_access"),
                URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
                URLQueryItem(name: "openid.pape.max_auth_age", value: "0"),
                URLQueryItem(name: "openid.oa2.response_type", value: "code"),
            ]
            return components.url!
        }
    }

    /// The code in the landing address, when the sign-in got that far.
    public static func code(in url: URL) -> String? {
        guard url.path.hasSuffix("/ap/maplanding") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "openid.oa2.authorization_code" }?.value
    }

    public static func isLanding(_ url: URL?) -> Bool { url?.path.hasSuffix("/ap/maplanding") == true }

    /// Registers the Lar as a device of the account with the code, then reads the cookies and the customer.
    /// - Parameter transport: a stand-in for the network (tests); by default each call has its own session.
    public static func register(code: String, attempt: Attempt, transport: HTTPTransport? = nil) async throws -> AlexaAccount {
        let body: JSONValue = [
            "requested_extensions": ["device_info", "customer_info"],
            "cookies": ["website_cookies": [], "domain": .string(".amazon.\(attempt.domain)")],
            "registration_data": [
                "domain": "Device",
                "app_version": .string(AlexaApp.appVersion),
                "device_type": .string(AlexaApp.deviceType),
                "device_name": .string("%FIRST_NAME%\u{0027}s%DUPE_STRATEGY_1ST%\(AlexaApp.appName)"),
                "os_version": .string(AlexaApp.osVersion),
                "device_serial": .string(attempt.serial),
                "device_model": "iPhone",
                "app_name": .string(AlexaApp.appName),
                "software_version": .string(AlexaApp.softwareVersion),
            ],
            "auth_data": [
                "use_global_authentication": "true",
                "client_id": .string(attempt.clientID),
                "authorization_code": .string(code),
                "code_verifier": .string(attempt.verifier),
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            ],
            "user_context_map": ["frc": .string(attempt.frc)],
            "requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
        ]
        var request = URLRequest(url: AlexaApp.api.appendingPathComponent("auth/register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(attempt.language, forHTTPHeaderField: "Accept-Language")
        request.setValue(AlexaApp.browserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await (transport ?? { try await URLSession.shared.data(for: $0) })(request)
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let success = json?["response"]?["success"], let tokens = success["tokens"],
              let refresh = tokens["bearer"]?["refresh_token"]?.string else {
            let reason = json?["response"]?["error"]?["message"]?.string ?? "sem resposta"
            throw ProviderError.api(tr("A Amazon não registrou o Lar: \(reason)"))
        }
        var cookies: [String: String] = [:]
        for cookie in tokens["website_cookies"]?.array ?? [] {
            if let name = cookie["Name"]?.string, let value = cookie["Value"]?.string {
                cookies[name] = value.replacingOccurrences(of: "\"", with: "")
            }
        }
        if let session = tokens["store_authentication_cookie"]?["cookie"]?.string { cookies["session-token"] = session }
        let account = AlexaAccount(domain: attempt.domain, serial: attempt.serial, refreshToken: refresh, cookies: cookies,
                                   customerID: nil, language: attempt.language)
        // The account's own site may want its cookies again; then who the customer is.
        let client = AlexaClient(account: account, transport: transport)
        try? await client.refreshCookies()
        try await client.loadCustomer()
        return await client.account
    }
}

// MARK: - The Echos

/// An Echo (or another device with Alexa built in) of the account.
public struct AlexaDevice: Sendable, Equatable {
    public var serial: String
    public var type: String
    public var name: String
    public var family: String
    public var online: Bool
    /// The members of a speaker group (itself for one device).
    public var members: [String]
}

public struct AlexaRoutine: Sendable, Equatable {
    /// The routine's automation id (stays the same when it's renamed).
    public var id: String
    public var name: String
    /// The routine's first node, as Amazon keeps it.
    let startNode: JSONValue
}

/// Talks to the account's Alexa site with the website cookies (and the CSRF token it hands out), renewing them with
/// the refresh token when they stop working.
public actor AlexaClient {
    static let log = Logger(subsystem: "com.coupled.lar", category: "alexa")
    public private(set) var account: AlexaAccount
    private let transport: HTTPTransport?
    private let save: @Sendable (AlexaAccount) -> Void
    private var csrf: String?
    private var session: URLSession

    /// Virtual devices and the Alexa app on phones: never in the list.
    static let ignoredTypes: Set<String> = [AlexaApp.deviceType, "A3C9PE6TNYLTCH"]

    public init(account: AlexaAccount, transport: HTTPTransport? = nil, save: @escaping @Sendable (AlexaAccount) -> Void = { _ in }) {
        self.account = account
        self.transport = transport
        self.save = save
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        Self.install(account, in: session)
    }

    /// The account's cookies on Amazon's domains (the account's and amazon.com, which the global endpoints read).
    private static func install(_ account: AlexaAccount, in session: URLSession) {
        guard let storage = session.configuration.httpCookieStorage else { return }
        var all = account.cookies
        all["lc-acbit"] = account.language
        for domain in Set([".amazon.\(account.domain)", ".amazon.com"]) {
            for (name, value) in all {
                if let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE"]) {
                    storage.setCookie(cookie)
                }
            }
        }
    }

    // MARK: Requests

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        if let transport {
            (data, response) = try await transport(request)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network(tr("Sem resposta da Amazon")) }
        if let cookie = session.configuration.httpCookieStorage?.cookies(for: request.url!)?.first(where: { $0.name == "csrf" }) {
            csrf = cookie.value
        }
        return (data, http)
    }

    /// A call to the Alexa site; a refused one renews the cookies and goes once more.
    func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil,
              retry: Bool = true) async throws -> JSONValue? {
        if method != "GET", csrf == nil { _ = try? await call("GET", "api/language", retry: false) }
        var components = URLComponents(url: account.alexaSite.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(AlexaApp.browserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.language, forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "csrf") }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await send(request)
        if [401, 403].contains(response.statusCode), retry {
            Self.log.notice("alexa \(path, privacy: .public): \(response.statusCode), renewing cookies")
            try await refreshCookies()
            return try await call(method, path, query: query, body: body, retry: false)
        }
        guard (200..<300).contains(response.statusCode) else {
            Self.log.error("alexa \(method, privacy: .public) \(path, privacy: .public): \(response.statusCode)")
            if [401, 403].contains(response.statusCode) { throw ProviderError.unauthorized }
            throw ProviderError.api("Alexa: HTTP \(response.statusCode)")
        }
        return data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// New website cookies from the refresh token (they last days; the refresh token, until signing out).
    public func refreshCookies() async throws {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "app_name", value: AlexaApp.appName),
            URLQueryItem(name: "app_version", value: AlexaApp.appVersion),
            URLQueryItem(name: "di.sdk.version", value: "6.12.4"),
            URLQueryItem(name: "source_token", value: account.refreshToken),
            URLQueryItem(name: "package_name", value: AlexaApp.bundleID),
            URLQueryItem(name: "di.hw.version", value: "iPhone"),
            URLQueryItem(name: "platform", value: "iOS"),
            URLQueryItem(name: "requested_token_type", value: "auth_cookies"),
            URLQueryItem(name: "source_token_type", value: "refresh_token"),
            URLQueryItem(name: "di.os.name", value: "iOS"),
            URLQueryItem(name: "di.os.version", value: AlexaApp.osVersion),
            URLQueryItem(name: "current_version", value: "6.12.4"),
            URLQueryItem(name: "previous_version", value: "6.12.4"),
            URLQueryItem(name: "domain", value: account.retailHost),
        ]
        var request = URLRequest(url: AlexaApp.api.appendingPathComponent("auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(AlexaApp.browserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await send(request)
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard response.statusCode == 200, case .object(let domains)? = json?["response"]?["tokens"]?["cookies"] else {
            // The refresh token itself was refused: signed out, or the device removed from the account.
            throw ProviderError.unauthorized
        }
        var cookies: [String: String] = [:]
        for (_, list) in domains {
            for cookie in list.array ?? [] {
                if let name = cookie["Name"]?.string, let value = cookie["Value"]?.string {
                    cookies[name] = value.replacingOccurrences(of: "\"", with: "")
                }
            }
        }
        guard !cookies.isEmpty else { throw ProviderError.unauthorized }
        account.cookies = cookies
        csrf = nil
        session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        Self.install(account, in: session)
        save(account)
    }

    func loadCustomer() async throws {
        guard let me = try await call("GET", "api/users/me"), let id = me["id"]?.string else {
            throw ProviderError.api(tr("A Amazon não disse quem é a conta"))
        }
        account.customerID = id
        save(account)
    }

    // MARK: Devices

    public func devices() async throws -> [AlexaDevice] {
        guard let json = try await call("GET", "api/devices-v2/device", query: [URLQueryItem(name: "cached", value: "false")]) else {
            return []
        }
        return Self.devices(from: json)
    }

    static func devices(from json: JSONValue) -> [AlexaDevice] {
        (json["devices"]?.array ?? []).compactMap { item in
            guard let serial = item["serialNumber"]?.string, let type = item["deviceType"]?.string,
                  !ignoredTypes.contains(type),
                  item["capabilities"]?.array?.contains(where: { $0.string == "MICROPHONE" }) == true else { return nil }
            let members = item["clusterMembers"]?.array?.compactMap(\.string) ?? []
            return AlexaDevice(serial: serial, type: type, name: item["accountName"]?.string ?? serial,
                               family: item["deviceFamily"]?.string ?? "", online: item["online"]?.bool ?? true,
                               members: members.isEmpty ? [serial] : members)
        }
    }

    /// Each Echo's volume (0–100), by serial.
    public func volumes() async throws -> [String: Int] {
        let json = try await call("GET", "api/devices/deviceType/dsn/audio/v1/allDeviceVolumes")
        var out: [String: Int] = [:]
        for item in json?["volumes"]?.array ?? [] {
            if let serial = item["dsn"]?.string, let volume = item["speakerVolume"]?.double { out[serial] = Int(volume) }
        }
        return out
    }

    /// Which Echos have Do Not Disturb on, by serial.
    public func doNotDisturb() async throws -> [String: Bool] {
        let json = try await call("GET", "api/dnd/device-status-list")
        var out: [String: Bool] = [:]
        for item in json?["doNotDisturbDeviceStatusList"]?.array ?? [] {
            if let serial = item["deviceSerialNumber"]?.string { out[serial] = item["enabled"]?.bool ?? false }
        }
        return out
    }

    public func setDoNotDisturb(_ on: Bool, on device: AlexaDevice) async throws {
        _ = try await call("PUT", "api/dnd/status", body: [
            "deviceSerialNumber": .string(device.serial), "deviceType": .string(device.type), "enabled": .bool(on),
        ])
    }

    public enum Media: String, Sendable { case play = "PlayCommand", pause = "PauseCommand", next = "NextCommand", previous = "PreviousCommand" }

    public func media(_ command: Media, on device: AlexaDevice) async throws {
        _ = try await call("POST", "api/np/command", query: [
            URLQueryItem(name: "deviceSerialNumber", value: device.serial), URLQueryItem(name: "deviceType", value: device.type),
        ], body: ["type": .string(command.rawValue)])
    }

    // MARK: Sequences (what a routine's steps are made of)

    /// Speaks the text on the Echo, as if Alexa said it.
    public func speak(_ text: String, on device: AlexaDevice) async throws {
        try await run([operation("Alexa.Speak", device, [
            "textToSpeak": .string(text),
            "target": ["customerId": customer, "devices": [["deviceSerialNumber": .string(device.serial), "deviceTypeId": .string(device.type)]]],
            "skillId": "amzn1.ask.1p.saysomething",
        ])])
    }

    /// An announcement (the chime, then the text) on these Echos at once.
    public func announce(_ text: String, title: String = "Lar", on devices: [AlexaDevice]) async throws {
        guard let first = devices.first else { return }
        let targets: [JSONValue] = devices.map { ["deviceSerialNumber": .string($0.serial), "deviceTypeId": .string($0.type)] }
        try await run([operation("AlexaAnnouncement", first, [
            "expireAfter": "PT5S",
            "content": [[
                "locale": .string(account.language),
                "display": ["title": .string(title), "body": .string(text)],
                "speak": ["type": "text", "value": .string(text)],
            ]],
            "target": ["customerId": customer, "devices": .array(targets)],
            "skillId": "amzn1.ask.1p.routines.messaging",
        ])])
    }

    /// Asks Alexa something as if it were said to this Echo ("apague a luz da sala"): anything Alexa controls.
    public func command(_ text: String, on device: AlexaDevice) async throws {
        try await run([operation("Alexa.TextCommand", device, ["skillId": "amzn1.ask.1p.tellalexa", "text": .string(text)])])
    }

    public func setVolume(_ volume: Int, on device: AlexaDevice) async throws {
        let value = min(max(volume, 0), 100)
        try await run(device.members.map { serial in
            operation("Alexa.DeviceControls.Volume", AlexaDevice(serial: serial, type: device.type, name: device.name,
                                                                family: device.family, online: true, members: [serial]),
                      ["value": .string(String(value))])
        })
    }

    public func stop(_ device: AlexaDevice) async throws {
        try await run([operation("Alexa.DeviceControls.Stop", device, [
            "devices": [["deviceSerialNumber": .string(device.serial), "deviceType": .string(device.type)]],
            "skillId": "amzn1.ask.1p.alexadevicecontrols",
        ])])
    }

    /// The routines that are on (ENABLED) in the Alexa app; turned-off ones never come.
    public func routines() async throws -> [AlexaRoutine] {
        Self.routines(from: try await call("GET", "api/behaviors/v2/automations"))
    }

    static func routines(from json: JSONValue?) -> [AlexaRoutine] {
        let list = json?.array ?? json?["generatedArrayWrapper"]?.array ?? json?["list"]?.array ?? []
        return list.compactMap { routine in
            guard routine["status"]?.string == "ENABLED", let name = routine["name"]?.string else { return nil }
            var sequence = routine["sequence"]
            // Some answers keep the sequence as JSON in a string.
            if let text = sequence?.string { sequence = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
            guard let start = sequence?["startNode"] else { return nil }
            return AlexaRoutine(id: routine["automationId"]?.string ?? name, name: name, startNode: start)
        }
    }

    /// Runs a routine (a device is needed to run it on: the steps that say "this device" go to it).
    public func run(_ routine: AlexaRoutine, on device: AlexaDevice) async throws {
        try await run([Self.fill(routine.startNode, device: device, customer: account.customerID ?? "")])
    }

    /// Steps kept from a routine (the ones a converted scene leaves to Alexa).
    public func run(steps node: JSONValue, on device: AlexaDevice) async throws {
        try await run([Self.fill(node, device: device, customer: account.customerID ?? "")])
    }

    /// The names Alexa gives the smart home devices, by every id a routine may use for them.
    public func smartHomeNames() async throws -> [String: String] {
        let query = """
        query getDevicesBaseData { listEndpoints(listEndpointsInput: { includeHouseholdDevices: true }) { endpoints { \
        endpointId: id friendlyNameObject { value { text } } legacyIdentifiers { chrsIdentifier { entityId } } \
        legacyAppliance { applianceId } } } }
        """
        let json = try await call("POST", "nexus/v1/graphql", body: ["query": .string(query)])
        return Self.names(from: json)
    }

    static func names(from json: JSONValue?) -> [String: String] {
        var out: [String: String] = [:]
        for endpoint in json?["data"]?["listEndpoints"]?["endpoints"]?.array ?? [] {
            guard let name = endpoint["friendlyNameObject"]?["value"]?["text"]?.string else { continue }
            for id in [endpoint["endpointId"]?.string, endpoint["legacyIdentifiers"]?["chrsIdentifier"]?["entityId"]?.string,
                       endpoint["legacyAppliance"]?["applianceId"]?.string].compactMap({ $0 }) {
                out[id] = name
            }
        }
        return out
    }

    /// The routine's placeholders for "the device it runs on" and the customer.
    static func fill(_ node: JSONValue, device: AlexaDevice, customer: String) -> JSONValue {
        switch node {
        case .string(let text):
            return .string(text.replacingOccurrences(of: "ALEXA_CURRENT_DEVICE_TYPE", with: device.type)
                .replacingOccurrences(of: "ALEXA_CURRENT_DSN", with: device.serial)
                .replacingOccurrences(of: "ALEXA_CUSTOMER_ID", with: customer))
        case .array(let items): return .array(items.map { fill($0, device: device, customer: customer) })
        case .object(let fields): return .object(fields.mapValues { fill($0, device: device, customer: customer) })
        default: return node
        }
    }

    private var customer: JSONValue { .string(account.customerID ?? "") }

    private func operation(_ type: String, _ device: AlexaDevice, _ payload: [String: JSONValue]) -> JSONValue {
        var all: [String: JSONValue] = [
            "deviceType": .string(device.type), "deviceSerialNumber": .string(device.serial),
            "locale": .string(account.language), "customerId": customer,
        ]
        all.merge(payload) { _, new in new }
        return ["@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode", "type": .string(type),
                "operationPayload": .object(all)]
    }

    /// The steps one after the other, as a routine preview.
    private func run(_ nodes: [JSONValue]) async throws {
        let sequence: JSONValue = [
            "@type": "com.amazon.alexa.behaviors.model.Sequence",
            "startNode": ["@type": "com.amazon.alexa.behaviors.model.SerialNode", "nodesToExecute": .array(nodes)],
        ]
        let text = String(decoding: try JSONEncoder().encode(sequence), as: UTF8.self)
        _ = try await call("POST", "api/behaviors/preview", body: [
            "behaviorId": "PREVIEW", "sequenceJson": .string(text), "status": "ENABLED",
        ])
    }
}
