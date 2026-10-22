import Foundation
import Security

/// Generic-password storage in the login keychain.
public enum Keychain {
    public static let service = "com.coupled.lar"

    public static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func write(_ value: String, account: String, label: String = "Lar – LG ThinQ token") -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            // Keep the token on this Mac: no iCloud Keychain sync, no backups.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the app keeps its configuration. Abstracted so tests and snapshots don't touch the keychain.
public protocol SettingsStorage: AnyObject {
    var token: String? { get set }
    var clientID: String { get }
    var deviceID: String? { get set }
    var temperatureLimits: TemperatureLimits { get set }
}

public final class AppSettings: SettingsStorage {
    private let defaults: UserDefaults
    private static let tokenAccount = "thinq-pat"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `LAR_PAT` overrides the keychain, for development runs from the terminal.
    public var token: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["LAR_PAT"], !env.isEmpty { return env }
            return Keychain.read(Self.tokenAccount)
        }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: Self.tokenAccount)
            } else {
                Keychain.delete(Self.tokenAccount)
            }
        }
    }

    public var clientID: String {
        if let id = defaults.string(forKey: "clientID") { return id }
        let id = "lar-\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: "clientID")
        return id
    }

    public var deviceID: String? {
        get { defaults.string(forKey: "deviceID") }
        set { defaults.set(newValue, forKey: "deviceID") }
    }

    public var temperatureLimits: TemperatureLimits {
        get {
            defaults.data(forKey: "temperatureLimits")
                .flatMap { try? JSONDecoder().decode(TemperatureLimits.self, from: $0) } ?? .standard
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "temperatureLimits") }
    }
}

public final class InMemorySettings: SettingsStorage {
    public var tuya: TuyaClient.Credentials?
    public var smartThings: SmartThingsClient.Credentials?
    public var tvHost: String?
    public var tvDiscovery = false
    public var knownTVs: [AndroidTVProvider.KnownTV] = []
    public var token: String?
    public var clientID = "lar-test"
    public var deviceID: String?
    public var temperatureLimits: TemperatureLimits

    public init(token: String? = nil, deviceID: String? = nil, temperatureLimits: TemperatureLimits = .standard) {
        self.token = token
        self.deviceID = deviceID
        self.temperatureLimits = temperatureLimits
    }
}

// MARK: - Other accounts

/// The Tuya and SmartThings keys. Secrets live in the keychain; the Tuya region is not secret.
public protocol AccountSettings: AnyObject {
    var tuya: TuyaClient.Credentials? { get set }
    var smartThings: SmartThingsClient.Credentials? { get set }
    /// An Android TV address typed by hand, for a TV that doesn't advertise itself (not a secret).
    var tvHost: String? { get set }
    /// Look for Android TVs on the network by themselves (on unless turned off).
    var tvDiscovery: Bool { get set }
    /// TVs seen before, so one that's off the network still shows (offline).
    var knownTVs: [AndroidTVProvider.KnownTV] { get set }
}

extension AppSettings: AccountSettings {
    private static func secret(_ account: String) -> String? {
        Keychain.read(account).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func setSecret(_ value: String?, _ account: String, label: String) {
        if let value, !value.isEmpty {
            Keychain.write(value, account: account, label: label)
        } else {
            Keychain.delete(account)
        }
    }

    public var tuya: TuyaClient.Credentials? {
        get {
            guard let id = Self.secret("tuya-client-id"), let secret = Self.secret("tuya-secret") else { return nil }
            return TuyaClient.Credentials(clientID: id, secret: secret, region: UserDefaults.standard.string(forKey: "tuyaRegion") ?? "us")
        }
        set {
            Self.setSecret(newValue?.clientID, "tuya-client-id", label: "Lar – Tuya Access ID")
            Self.setSecret(newValue?.secret, "tuya-secret", label: "Lar – Tuya Access Secret")
            UserDefaults.standard.set(newValue?.region, forKey: "tuyaRegion")
        }
    }

    public var smartThings: SmartThingsClient.Credentials? {
        get {
            if let id = Self.secret("st-client-id"), let secret = Self.secret("st-client-secret"),
               let refresh = Self.secret("st-refresh-token") {
                return .oauth(clientID: id, secret: secret, refreshToken: refresh)
            }
            return Self.secret("st-token").map { .personalToken($0) }
        }
        set {
            switch newValue {
            case .personalToken(let token)?:
                Self.setSecret(token, "st-token", label: "Lar – SmartThings token")
                for account in ["st-client-id", "st-client-secret", "st-refresh-token"] { Keychain.delete(account) }
            case .oauth(let id, let secret, let refresh)?:
                Self.setSecret(id, "st-client-id", label: "Lar – SmartThings client ID")
                Self.setSecret(secret, "st-client-secret", label: "Lar – SmartThings client secret")
                Self.setSecret(refresh, "st-refresh-token", label: "Lar – SmartThings refresh token")
                Keychain.delete("st-token")
            case nil:
                for account in ["st-token", "st-client-id", "st-client-secret", "st-refresh-token"] { Keychain.delete(account) }
            }
        }
    }

    public var tvHost: String? {
        get { UserDefaults.standard.string(forKey: "tvHost").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "tvHost") }
    }

    public var tvDiscovery: Bool {
        get { UserDefaults.standard.object(forKey: "tvDiscovery") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tvDiscovery") }
    }

    public var knownTVs: [AndroidTVProvider.KnownTV] {
        get { Self.loadKnownTVs() }
        set { Self.saveKnownTVs(newValue) }
    }

    static func loadKnownTVs() -> [AndroidTVProvider.KnownTV] {
        UserDefaults.standard.data(forKey: "knownTVs")
            .flatMap { try? JSONDecoder().decode([AndroidTVProvider.KnownTV].self, from: $0) } ?? []
    }

    public static func saveKnownTVs(_ tvs: [AndroidTVProvider.KnownTV]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(tvs), forKey: "knownTVs")
    }

    /// SmartThings hands out a new refresh token at every renewal and the old one stops working at once.
    public static func saveSmartThingsRefreshToken(_ token: String) {
        setSecret(token, "st-refresh-token", label: "Lar – SmartThings refresh token")
    }
}

extension InMemorySettings: AccountSettings {}
