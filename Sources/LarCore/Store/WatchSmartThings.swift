import Foundation

/// The watch's own SmartThings integration, signed in on the iPhone and handed over once: from then on the watch
/// renews its token by itself and needs the iPhone for nothing on SmartThings. The iPhone keeps it only until the
/// watch has it (the refresh token turns over at the watch's first renewal, so a copy left behind would go stale).
public struct WatchSmartThingsHandoff: Codable, Sendable, Equatable {
    public static let userInfoKey = "smartThingsHandoff"

    public var id: UUID
    /// Nil hands SmartThings back to the iPhone (its 24 h tokens).
    public var credentials: Credentials?

    public struct Credentials: Codable, Sendable, Equatable {
        public var clientID: String
        public var secret: String
        public var refreshToken: String

        public init(clientID: String, secret: String, refreshToken: String) {
            self.clientID = clientID
            self.secret = secret
            self.refreshToken = refreshToken
        }
    }

    public init(id: UUID = UUID(), credentials: Credentials?) {
        self.id = id
        self.credentials = credentials
    }

    /// The handoff waiting on the iPhone for the watch to receive it.
    public static var pending: WatchSmartThingsHandoff? {
        get { Keychain.read("st-watch-handoff").flatMap { try? JSONDecoder().decode(Self.self, from: Data($0.utf8)) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Keychain.write(String(decoding: data, as: UTF8.self), account: "st-watch-handoff",
                               label: "Lar – SmartThings do relógio (a entregar)")
            } else {
                Keychain.delete("st-watch-handoff")
            }
        }
    }

    /// On the iPhone: whether the watch has its own integration (shown in Settings).
    public static var watchHasOwn: Bool {
        get { Preferences.bool(forKey: "watchHasOwnSmartThings") ?? false }
        set { Preferences.set(newValue, forKey: "watchHasOwnSmartThings") }
    }

    /// On the watch: takes a handoff once (a repeated delivery is ignored). True when it changed the account.
    @discardableResult
    public func apply(to settings: AccountSettings) -> Bool {
        guard Preferences.string(forKey: "watchSmartThingsHandoff") != id.uuidString else { return false }
        Preferences.set(id.uuidString, forKey: "watchSmartThingsHandoff")
        Self.ownOnWatch = credentials != nil
        settings.smartThings = credentials.map { .oauth(clientID: $0.clientID, secret: $0.secret, refreshToken: $0.refreshToken) }
        return true
    }

    /// On the watch: SmartThings runs on its own integration, so the iPhone's 24 h tokens are not taken.
    public static var ownOnWatch: Bool {
        get { Preferences.bool(forKey: "watchOwnSmartThings") ?? false }
        set { Preferences.set(newValue, forKey: "watchOwnSmartThings") }
    }
}
