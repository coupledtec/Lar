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
    public var sentAt: Date

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
        settings.smartThings = smartThingsAccessToken.map { .personalToken($0) }
        settings.temperatureLimits = temperatureLimits
        if let scenes { settings.scenes = scenes }
        if let customizations { settings.customizations = customizations }
        if let grouping { settings.grouping = grouping }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decoded(_ data: Data) throws -> WatchPayload { try JSONDecoder().decode(WatchPayload.self, from: data) }
}
