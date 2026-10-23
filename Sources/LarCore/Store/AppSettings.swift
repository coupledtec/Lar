import Foundation
import Security

/// Generic-password storage: the login keychain on the Mac; on the iPhone and the watch, the keychain group the app
/// shares with its widgets (`LarKeychainGroup` in Info.plist), so they read the same accounts.
public enum Keychain {
    public static let service = "com.coupled.lar"

    /// The shared access group, or nil (the Mac, tests): items then go to the app's own.
    public static let sharedGroup: String? = {
        #if os(macOS)
        return nil
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "LarKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
        #endif
    }()

    public static func read(_ account: String) -> String? {
        #if os(macOS)
        return Vault.read(account)
        #else
        return readData(account).flatMap { String(data: $0, encoding: .utf8) }
        #endif
    }

    @discardableResult
    public static func write(_ value: String, account: String, label: String = "Lar – LG ThinQ token") -> Bool {
        #if os(macOS)
        return Vault.write(value, account: account)
        #else
        return writeData(Data(value.utf8), account: account, label: label)
        #endif
    }

    public static func delete(_ account: String, service: String = service) {
        #if os(macOS)
        if service == Self.service { return Vault.delete(account) }
        #endif
        deleteItem(account, service: service)
    }

    static func deleteItem(_ account: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func readData(_ account: String, service: String = service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func writeData(_ data: Data, account: String, service: String = service, label: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            // Keep it on this device: no iCloud Keychain sync, no backups.
            item[kSecAttrAccessible as String] = accessibility
            if let sharedGroup { item[kSecAttrAccessGroup as String] = sharedGroup }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Readable once the device has been unlocked after starting up: the iPhone app is woken in the background by
    /// the watch and CarPlay, often while locked, and must still read its keys then.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// Moves keys saved by older versions to `accessibility` and into the shared group. Run while unlocked.
    public static func migrateAccessibility() {
        #if !os(macOS)
        var update: [String: Any] = [kSecAttrAccessible as String: accessibility]
        if let sharedGroup { update[kSecAttrAccessGroup as String] = sharedGroup }
        for service in [service, Preferences.service] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        #endif
        TVRemoteIdentity.migrateAccessibility()
    }
}

/// The app's preferences (not secrets): UserDefaults on the Mac; on the iPhone and the watch, items in the shared
/// keychain group, so the widgets see the same scenes, favorites and TVs. Values saved by older versions in
/// UserDefaults move over the first time they're read.
public enum Preferences {
    static let service = "com.coupled.lar.prefs"

    private static var shared: Bool { Keychain.sharedGroup != nil }

    public static func object(forKey key: String) -> Any? {
        guard shared else { return UserDefaults.standard.object(forKey: key) }
        if let data = Keychain.readData(key, service: service),
           let box = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return box["value"]
        }
        guard let old = UserDefaults.standard.object(forKey: key) else { return nil }
        set(old, forKey: key)
        return old
    }

    public static func set(_ value: Any?, forKey key: String) {
        guard shared else { return UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        guard let value else { return Keychain.delete(key, service: service) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0) else { return }
        Keychain.writeData(data, account: key, service: service, label: "Lar – \(key)")
    }

    public static func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public static func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public static func bool(forKey key: String) -> Bool? { object(forKey: key) as? Bool }

    static func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func setEncoded<T: Encodable>(_ value: T, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
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
        if let id = Preferences.string(forKey: "clientID") { return id }
        let id = "lar-\(UUID().uuidString.lowercased())"
        Preferences.set(id, forKey: "clientID")
        return id
    }

    public var deviceID: String? {
        get { defaults.string(forKey: "deviceID") }
        set { defaults.set(newValue, forKey: "deviceID") }
    }

    public var temperatureLimits: TemperatureLimits {
        get { Preferences.decoded(TemperatureLimits.self, forKey: "temperatureLimits") ?? .standard }
        set { Preferences.setEncoded(newValue, forKey: "temperatureLimits") }
    }
}

public final class InMemorySettings: SettingsStorage {
    public var tuya: TuyaClient.Credentials?
    public var smartThings: SmartThingsClient.Credentials?
    public var tvHost: String?
    public var tvDiscovery = false
    public var knownTVs: [AndroidTVProvider.KnownTV] = []
    public var pairedTVs: [String] = []
    public var tvPins: [String: String] = [:]
    public var scenes: [HomeScene] = []
    public var customizations: [String: DeviceCustomization] = [:]
    public var grouping: DeviceGrouping = .kind
    public var syncUpdatedAt = Date.distantPast
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
    /// TVs paired with the Google TV remote protocol, by advertised name (or address).
    var pairedTVs: [String] { get set }
    /// The paired TVs' certificates (SHA-256), pinned at the first connection (public data, not secrets).
    var tvPins: [String: String] { get set }
    /// The scenes made on this device (or, on the watch, received from the iPhone).
    var scenes: [HomeScene] { get set }
    /// Names, favorites, rooms and hidden devices, by device id.
    var customizations: [String: DeviceCustomization] { get set }
    var grouping: DeviceGrouping { get set }
    /// When the scenes or the list's organization last changed here (or came from the other side).
    var syncUpdatedAt: Date { get set }
}

extension AccountSettings {
    /// Loads the list preferences into the store and saves them back whenever they change there.
    @MainActor
    public func bindListPreferences(to home: HomeStore, afterChange: @escaping () -> Void = {}) {
        home.customizations = customizations
        home.grouping = grouping
        home.onListPreferencesChange = { [weak self] customizations, grouping in
            self?.customizations = customizations
            self?.grouping = grouping
            self?.markSyncChange()
            afterChange()
        }
    }
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
            return TuyaClient.Credentials(clientID: id, secret: secret, region: Preferences.string(forKey: "tuyaRegion") ?? "us")
        }
        set {
            Self.setSecret(newValue?.clientID, "tuya-client-id", label: "Lar – Tuya Access ID")
            Self.setSecret(newValue?.secret, "tuya-secret", label: "Lar – Tuya Access Secret")
            Preferences.set(newValue?.region, forKey: "tuyaRegion")
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
        get { Preferences.string(forKey: "tvHost").flatMap { $0.isEmpty ? nil : $0 } }
        set { Preferences.set(newValue, forKey: "tvHost") }
    }

    public var tvDiscovery: Bool {
        get { Preferences.bool(forKey: "tvDiscovery") ?? true }
        set { Preferences.set(newValue, forKey: "tvDiscovery") }
    }

    public var knownTVs: [AndroidTVProvider.KnownTV] {
        get { Self.loadKnownTVs() }
        set { Self.saveKnownTVs(newValue) }
    }

    public var pairedTVs: [String] {
        get { Preferences.object(forKey: "pairedTVs") as? [String] ?? [] }
        set { Self.savePairedTVs(newValue) }
    }

    public var customizations: [String: DeviceCustomization] {
        get { Preferences.decoded([String: DeviceCustomization].self, forKey: "deviceCustomizations") ?? [:] }
        set { Preferences.setEncoded(newValue, forKey: "deviceCustomizations") }
    }

    public var grouping: DeviceGrouping {
        get { Preferences.string(forKey: "deviceGrouping").flatMap(DeviceGrouping.init(rawValue:)) ?? .kind }
        set { Preferences.set(newValue.rawValue, forKey: "deviceGrouping") }
    }

    public var syncUpdatedAt: Date {
        get { Preferences.object(forKey: "syncUpdatedAt") as? Date ?? .distantPast }
        set { Preferences.set(newValue, forKey: "syncUpdatedAt") }
    }

    public var scenes: [HomeScene] {
        get { Preferences.decoded([HomeScene].self, forKey: "scenes") ?? [] }
        set { Preferences.setEncoded(newValue, forKey: "scenes") }
    }

    public var tvPins: [String: String] {
        get { Preferences.object(forKey: "tvCertificatePins") as? [String: String] ?? [:] }
        set { Self.saveTVPins(newValue) }
    }

    public static func saveTVPins(_ pins: [String: String]) {
        Preferences.set(pins, forKey: "tvCertificatePins")
    }

    public static func savePairedTVs(_ names: [String]) {
        Preferences.set(names, forKey: "pairedTVs")
    }

    static func loadKnownTVs() -> [AndroidTVProvider.KnownTV] {
        Preferences.decoded([AndroidTVProvider.KnownTV].self, forKey: "knownTVs") ?? []
    }

    public static func saveKnownTVs(_ tvs: [AndroidTVProvider.KnownTV]) {
        Preferences.setEncoded(tvs, forKey: "knownTVs")
    }

    /// SmartThings hands out a new refresh token at every renewal and the old one stops working at once.
    public static func saveSmartThingsRefreshToken(_ token: String) {
        setSecret(token, "st-refresh-token", label: "Lar – SmartThings refresh token")
    }
}

extension InMemorySettings: AccountSettings {}
