import CryptoKit
import Foundation

#if !os(watchOS)
/// One SmartThings integration (OAuth app) per device, made by the app itself: the refresh token turns over at every
/// renewal, so two devices sharing an integration log each other out. With a personal token (made once, at
/// account.smartthings.com/tokens, with the Apps permission; it isn't kept), the app creates its own integration,
/// then signs in with it.
public enum SmartThingsSetup {
    static let appsURL = SmartThingsClient.api.appendingPathComponent("apps")
    /// Where the personal token is made (with the Apps permission).
    public static let tokensPage = URL(string: "https://account.smartthings.com/tokens")!

    public struct Integration: Sendable, Equatable {
        public let clientID: String
        public let secret: String
    }

    /// Creates an integration named after this device ("Lar (iPhone)"), with the sign-in's scopes and redirect.
    public static func createIntegration(personalToken: String, deviceName: String,
                                         transport: HTTPTransport = { try await URLSession.shared.data(for: $0) })
        async throws -> Integration {
        var request = URLRequest(url: appsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(personalToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body(deviceName: deviceName))
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        if status == 401 || status == 403 {
            throw ProviderError.api(tr("Token recusado: crie um com a permissão de apps (Apps)"))
        }
        guard (200..<300).contains(status), let json else {
            let reason = json?["error"]?["message"]?.string ?? "HTTP \(status)"
            throw ProviderError.api(tr("SmartThings não criou a integração: \(reason)"))
        }
        guard let integration = integration(in: json) else { throw ProviderError.api(tr("SmartThings não mandou o client ID")) }
        return integration
    }

    static func body(deviceName: String) -> JSONValue {
        [
            // Unique, lowercase: the device's name goes in the display name.
            "appName": .string("lar-" + UUID().uuidString.lowercased()),
            "displayName": .string("Lar (\(deviceName))"),
            "description": .string("Lar no \(deviceName): uma integração só deste aparelho."),
            "appType": "API_ONLY",
            "classifications": ["CONNECTED_SERVICE"],
            "singleInstance": true,
            "oauth": [
                "clientName": .string("Lar (\(deviceName))"),
                "scope": .array(SmartThingsSignIn.scopes.split(separator: " ").map { .string(String($0)) }),
                "redirectUris": [.string(SmartThingsSignIn.redirect)],
            ],
        ]
    }

    /// The new client's ID and secret ({"app": …, "oauthClientId": …, "oauthClientSecret": …}).
    static func integration(in json: JSONValue) -> Integration? {
        guard let id = json["oauthClientId"]?.string ?? json["app"]?["oauthClientId"]?.string,
              let secret = json["oauthClientSecret"]?.string ?? json["app"]?["oauthClientSecret"]?.string,
              !id.isEmpty, !secret.isEmpty else { return nil }
        return Integration(clientID: id, secret: secret)
    }
}

#endif

/// Which integration each of the owner's devices uses, so none signs in with another's. Only a fingerprint of the
/// client ID goes between devices (with the Mac sync), never the ID or the secret.
public enum SmartThingsClaims {
    public struct Claim: Codable, Sendable, Equatable {
        public var device: String
        public var fingerprint: String

        public init(device: String, fingerprint: String) {
            self.device = device
            self.fingerprint = fingerprint
        }
    }

    public static func fingerprint(_ clientID: String) -> String {
        let digest = SHA256.hash(data: Data(("lar-smartthings:" + clientID.lowercased()).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// This install, for the others' records (kept across launches).
    public static var installID: String {
        if let id = Preferences.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        Preferences.set(id, forKey: "installID")
        return id
    }

    /// This device's claim: the integration it signs in with (nil: none, or a personal token).
    public static func own(_ settings: any AccountSettings, device: String) -> Claim? {
        guard case .oauth(let clientID, _, _)? = settings.smartThings else { return nil }
        return Claim(device: device, fingerprint: fingerprint(clientID))
    }

    /// The other devices' claims, by install, as last heard.
    public static var others: [String: Claim] {
        get {
            (Preferences.object(forKey: "smartThingsClaims") as? Data)
                .flatMap { try? JSONDecoder().decode([String: Claim].self, from: $0) } ?? [:]
        }
        set { Preferences.set(try? JSONEncoder().encode(newValue), forKey: "smartThingsClaims") }
    }

    /// Records another device's claim (nil: it has none now).
    public static func record(_ claim: Claim?, install: String) {
        guard install != installID else { return }
        var all = others
        all[install] = claim
        others = all
    }

    /// The device already using this integration, if another one is.
    public static func user(of clientID: String) -> String? {
        let mine = fingerprint(clientID)
        return others.values.first { $0.fingerprint == mine }?.device
    }

    /// Why this client ID can't be used here, or nil when it's free.
    public static func problem(with clientID: String) -> String? {
        user(of: clientID).map { tr("Esta integração já é a do \($0). Crie uma só para este aparelho.") }
    }
}
