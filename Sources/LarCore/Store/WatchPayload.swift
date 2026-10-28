import Foundation

/// What the iPhone hands the watch so it can talk to the clouds by itself. SmartThings goes as an access token only
/// (about 24 h): the iPhone owns the refresh token and is the only one that renews it, because every renewal
/// invalidates the previous token and two devices renewing would lock each other out.
public struct WatchPayload: Codable, Sendable, Equatable {
    public struct Tuya: Codable, Sendable, Equatable {
        public var clientID: String
        public var secret: String
        public var region: String
    }

    /// The intercom's extension, for calls placed from the watch (nil: no intercom set on the iPhone).
    public struct Phone: Codable, Sendable, Equatable {
        public var server: String
        public var port: UInt16
        public var user: String
        public var password: String
        public var domain: String
        public var doorNumber: String
        public var doorCode: String

        /// The iPhone's intercom, when it's on and complete.
        public static func current() -> Phone? {
            let settings = PhoneSettings.load()
            guard settings.isEnabled, settings.isComplete, let password = PhoneSettings.password else { return nil }
            return Phone(server: settings.server, port: settings.port, user: settings.user, password: password,
                         domain: settings.domain, doorNumber: settings.doorNumber, doorCode: settings.doorCode)
        }

        func apply() {
            PhoneSettings(server: server, port: port, user: user, domain: domain, doorNumber: doorNumber,
                          doorCode: doorCode, isEnabled: true).save()
            if PhoneSettings.password != password { PhoneSettings.password = password }
        }
    }

    public var lgToken: String?
    public var tuya: Tuya?
    public var smartThingsAccessToken: String?
    /// When the SmartThings access token stops working (the watch asks the iPhone for a new one before that).
    public var smartThingsExpires: Date?
    public var temperatureLimits: TemperatureLimits
    /// The iPhone's scenes (nil from older versions).
    public var scenes: [HomeScene]?
    /// The iPhone's names, favorites, rooms and grouping (nil from older versions).
    public var customizations: [String: DeviceCustomization]?
    public var grouping: DeviceGrouping?
    public var phone: Phone?
    /// The Amazon account for the Echos (its cookies are renewed on the watch with the same refresh token).
    public var alexa: AlexaAccount?
    /// The Microsoft account for the Xbox (the watch renews it on its own from there).
    public var xbox: XboxAccount?
    public var sentAt: Date

    /// The watch's answer once it took a payload: the payload's `sentAt` (seconds since 1970), so the iPhone can say
    /// the accounts arrived.
    public static let receivedKey = "accountsReceived"

    public init(
        lgToken: String?, tuya: Tuya?, smartThingsAccessToken: String?, smartThingsExpires: Date?,
        temperatureLimits: TemperatureLimits, scenes: [HomeScene]? = nil, sentAt: Date = Date()
    ) {
        self.scenes = scenes
        self.lgToken = lgToken
        self.tuya = tuya
        self.smartThingsAccessToken = smartThingsAccessToken
        self.smartThingsExpires = smartThingsExpires
        self.temperatureLimits = temperatureLimits
        self.sentAt = sentAt
    }

    /// The iPhone's accounts, as the watch will use them.
    public static func from(_ settings: LarSettings, smartThingsAccessToken: String?, now: Date = Date()) -> WatchPayload {
        WatchPayload(
            lgToken: settings.token,
            tuya: settings.tuya.map { Tuya(clientID: $0.clientID, secret: $0.secret, region: $0.region) },
            smartThingsAccessToken: smartThingsAccessToken,
            // SmartThings access tokens last 24 h; leave a margin.
            smartThingsExpires: smartThingsAccessToken == nil ? nil : now.addingTimeInterval(20 * 3600),
            temperatureLimits: settings.temperatureLimits,
            scenes: settings.scenes,
            sentAt: now
        )
        .with(customizations: settings.customizations, grouping: settings.grouping)
    }

    func with(customizations: [String: DeviceCustomization], grouping: DeviceGrouping) -> WatchPayload {
        var copy = self
        copy.customizations = customizations
        copy.grouping = grouping
        return copy
    }

    /// Writes the payload into the watch's own settings (its keychain). SmartThings becomes a plain token there.
    public func apply(to settings: LarSettings) {
        if settings.token != lgToken { settings.token = lgToken }
        settings.tuya = tuya.map { TuyaClient.Credentials(clientID: $0.clientID, secret: $0.secret, region: $0.region) }
        // A watch with its own integration renews by itself: the iPhone's token would replace it.
        if !WatchSmartThingsHandoff.ownOnWatch {
            settings.smartThings = smartThingsAccessToken.map { .personalToken($0) }
        }
        settings.temperatureLimits = temperatureLimits
        if let scenes { settings.scenes = scenes }
        if let customizations { settings.customizations = customizations }
        if let grouping { settings.grouping = grouping }
        if settings.alexa?.refreshToken != alexa?.refreshToken { settings.alexa = alexa }
        // Only a different account replaces the watch's: its own renewals change the token.
        if settings.xbox?.gamertag != xbox?.gamertag { settings.xbox = xbox }
        if let phone {
            phone.apply()
        } else if PhoneSettings.load().isEnabled {
            // Turned off (or cleared) on the iPhone: off here too, and the password gone.
            var off = PhoneSettings.load()
            off.isEnabled = false
            off.save()
            PhoneSettings.password = nil
        }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// WatchConnectivity refuses big payloads (and then nothing at all reaches the watch). Past the limit, the
    /// Alexa steps of imported routines go first (the scenes keep their own commands), then the per-device names.
    public static let watchLimit = 48_000

    public func encodedForWatch(limit: Int = watchLimit) throws -> Data {
        var payload = self
        var data = try payload.encoded()
        guard data.count > limit else { return data }
        payload.scenes = payload.scenes?.map { scene in
            var lean = scene
            lean.alexaSteps = nil
            return lean
        }
        data = try payload.encoded()
        guard data.count > limit else { return data }
        payload.customizations = payload.customizations?.filter { $0.value.isFavorite || $0.value.isHidden || $0.value.room != nil }
        return try payload.encoded()
    }
    public static func decoded(_ data: Data) throws -> WatchPayload { try JSONDecoder().decode(WatchPayload.self, from: data) }
}
