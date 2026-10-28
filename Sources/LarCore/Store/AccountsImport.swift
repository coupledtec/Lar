import Foundation

/// Accounts handed to another device of the owner's (the iPhone, from the Mac) as a one-time file: read, written
/// into that device's keychain and deleted right after. A SmartThings refresh token in it must come from its own
/// authorization, never a copy of another device's (each renewal invalidates the previous token).
public struct AccountsImport: Codable, Sendable, Equatable {
    public struct Tuya: Codable, Sendable, Equatable {
        public var clientID: String
        public var secret: String
        public var region: String
    }

    public struct SmartThingsOAuth: Codable, Sendable, Equatable {
        public var clientID: String
        public var secret: String
        public var refreshToken: String
    }

    /// The intercom's SIP account, with its password.
    public struct Intercom: Codable, Sendable, Equatable {
        public var server: String
        public var port: UInt16
        public var user: String
        public var domain: String
        public var doorNumber: String
        public var doorCode: String
        public var isEnabled: Bool
        public var password: String
    }

    public var lgToken: String?
    public var tuya: Tuya?
    public var smartThings: SmartThingsOAuth?
    public var temperatureLimits: TemperatureLimits?
    public var alexa: AlexaAccount?
    public var xbox: XboxAccount?
    public var intercom: Intercom?

    public static let fileName = "lar-import.json"

    public func apply(to settings: LarSettings) {
        if let lgToken { settings.token = lgToken }
        if let tuya { settings.tuya = TuyaClient.Credentials(clientID: tuya.clientID, secret: tuya.secret, region: tuya.region) }
        // Another device's integration is never taken: the two would log each other out.
        if let smartThings, SmartThingsClaims.problem(with: smartThings.clientID) == nil {
            settings.smartThings = .oauth(clientID: smartThings.clientID, secret: smartThings.secret, refreshToken: smartThings.refreshToken)
        }
        if let temperatureLimits { settings.temperatureLimits = temperatureLimits }
        if let alexa { settings.alexa = alexa }
        if let xbox { settings.xbox = xbox }
        if let intercom {
            PhoneSettings(server: intercom.server, port: intercom.port, user: intercom.user, domain: intercom.domain,
                          doorNumber: intercom.doorNumber, doorCode: intercom.doorCode, isEnabled: intercom.isEnabled).save()
            PhoneSettings.password = intercom.password
        }
    }

    /// Imports `lar-import.json` from the folder when it's there, then deletes it. True when something was imported.
    @discardableResult
    public static func importIfPresent(in folder: URL, into settings: LarSettings) -> Bool {
        let file = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else { return false }
        // The file holds secrets: gone whatever happens next.
        defer { try? FileManager.default.removeItem(at: file) }
        guard let accounts = try? JSONDecoder().decode(AccountsImport.self, from: data) else { return false }
        accounts.apply(to: settings)
        return true
    }
}
