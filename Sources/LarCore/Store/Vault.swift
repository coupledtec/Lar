import Foundation
import Security

#if os(macOS)
/// The Mac's keys in one keychain item: macOS asks for the keychain password per item and per app version, so a
/// dozen items meant a dozen prompts after each update. One item, one prompt ("Always Allow" covers it).
/// Items of older versions move in once and are deleted.
enum Vault {
    /// The item's account; tests use their own.
    nonisolated(unsafe) static var account = "vault"
    private static let entries = Locked<[String: String]?>(nil)

    /// The accounts older versions kept as separate items.
    static let legacyAccounts = ["thinq-pat", "tuya-client-id", "tuya-secret", "st-token", "st-client-id",
                                 "st-client-secret", "st-refresh-token", "sync-key", "adb-key"]

    static func read(_ key: String) -> String? {
        load()[key]
    }

    @discardableResult
    static func write(_ value: String, account key: String) -> Bool {
        var all = load()
        all[key] = value
        return save(all)
    }

    static func delete(_ key: String) {
        var all = load()
        guard all.removeValue(forKey: key) != nil else { return }
        save(all)
    }

    /// Forgets what was read (tests switch vaults).
    static func reset() { entries.update { $0 = nil } }

    private static func load() -> [String: String] {
        if let cached = entries.value { return cached }
        var all: [String: String] = [:]
        if let data = Keychain.readData(account), let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            all = decoded
        } else if account == "vault" {
            // First run of this version: bring the separate items in, then remove them.
            for key in legacyAccounts {
                if let data = Keychain.readData(key), let value = String(data: data, encoding: .utf8) { all[key] = value }
            }
            if !all.isEmpty, save(all) {
                for key in all.keys { Keychain.deleteItem(key) }
            }
        }
        entries.update { $0 = all }
        return all
    }

    @discardableResult
    private static func save(_ all: [String: String]) -> Bool {
        entries.update { $0 = all }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        return Keychain.writeData(data, account: account, label: "Lar – chaves das contas")
    }
}
#endif
