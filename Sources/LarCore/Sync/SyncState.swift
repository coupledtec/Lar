import Foundation

/// What the Mac and the iPhone keep in common: the scenes and how the list is organized. Never the accounts' keys.
/// The newer side wins, by `updatedAt`, bumped whenever any of it changes locally.
public struct SyncState: Codable, Sendable, Equatable {
    public var scenes: [HomeScene]
    public var customizations: [String: DeviceCustomization]
    public var grouping: DeviceGrouping
    public var updatedAt: Date
    /// The alerts turned on and the suggestions dealt with (nil from older versions: left as they are).
    public var watches: [String]?
    public var dismissedSuggestions: [String]?
    /// The houses (nil from older versions: left as they are).
    public var places: [HomePlace]?

    public init(scenes: [HomeScene], customizations: [String: DeviceCustomization], grouping: DeviceGrouping, updatedAt: Date,
                watches: [String]? = nil, dismissedSuggestions: [String]? = nil, places: [HomePlace]? = nil) {
        self.scenes = scenes
        self.customizations = customizations
        self.grouping = grouping
        self.updatedAt = updatedAt
        self.watches = watches
        self.dismissedSuggestions = dismissedSuggestions
        self.places = places
    }

    public static func capture(_ settings: AccountSettings) -> SyncState {
        SyncState(scenes: settings.scenes, customizations: settings.customizations, grouping: settings.grouping,
                  updatedAt: settings.syncUpdatedAt, watches: settings.watches, dismissedSuggestions: settings.dismissedSuggestions,
                  places: settings.places)
    }

    /// Writes the state over the local one, keeping its date (so the two sides agree they're in step).
    public func apply(to settings: AccountSettings) {
        settings.scenes = scenes
        settings.customizations = customizations
        settings.grouping = grouping
        if let watches { settings.watches = watches }
        if let dismissedSuggestions { settings.dismissedSuggestions = dismissedSuggestions }
        if let places { settings.places = places }
        settings.syncUpdatedAt = updatedAt
    }

    /// Which way to copy: nil when both sides have the same state.
    public static func direction(local: SyncState, remote: SyncState) -> Direction? {
        if local.scenes == remote.scenes, local.customizations == remote.customizations, local.grouping == remote.grouping,
           remote.watches == nil || Set(local.watches ?? []) == Set(remote.watches ?? []),
           remote.dismissedSuggestions == nil || Set(local.dismissedSuggestions ?? []) == Set(remote.dismissedSuggestions ?? []),
           remote.places == nil || (local.places ?? []) == (remote.places ?? []) {
            return nil
        }
        return remote.updatedAt > local.updatedAt ? .pull : .push
    }

    public enum Direction: Sendable { case pull, push }
}

extension AccountSettings {
    /// Marks the shared state as changed here, now.
    public func markSyncChange(_ date: Date = Date()) { syncUpdatedAt = date }
}

/// The messages between the iPhone (client) and the Mac (server), as JSON.
enum SyncMessage: Codable, Sendable, Equatable {
    case get
    case state(SyncState)
    case put(SyncState)
    case ok
    /// The iPhone hands a turn-off timer to the Mac (nil seconds cancels it).
    case offTimer(deviceID: String, seconds: Double?)
    /// Which SmartThings integration a device uses (a fingerprint), from the iPhone; the Mac answers with its own.
    case claim(install: String, claim: SmartThingsClaims.Claim?)
    /// Pairing only: the Mac's long-term key for the next connections.
    case key(Data)
    case error(String)
}
