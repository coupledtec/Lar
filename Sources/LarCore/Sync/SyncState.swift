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
    /// Shared one house only: the devices of that house (the guest's list shows only these). Nil: everything.
    public var sharedDevices: [String]?

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
        HomePlaces.guestDevices = sharedDevices.map(Set.init)
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

extension SyncState {
    /// The part one house's guests get: that house, its devices' names and rooms, and the scenes that only touch
    /// its devices.
    public static func house(_ placeID: String, from state: SyncState, devices: [HomeDevice]) -> SyncState {
        let places = state.places ?? []
        let ids = Set(devices.filter {
            HomePlaces.placeID(of: $0, customizations: state.customizations, places: places, learned: HomePlaces.learned) == placeID
        }.map(\.id))
        var house = state
        house.scenes = state.scenes.filter { scene in !scene.actions.isEmpty && scene.actions.allSatisfy { ids.contains($0.deviceID) } }
        house.customizations = state.customizations.filter { ids.contains($0.key) }
        house.places = places.filter { $0.id == placeID }
        house.watches = nil
        house.dismissedSuggestions = nil
        house.sharedDevices = ids.sorted()
        return house
    }

    /// What one house's guests changed, brought back into the whole: its scenes (new, changed or deleted) and its
    /// devices' names and rooms.
    public func merging(house: SyncState) -> SyncState {
        let ids = Set(house.sharedDevices ?? [])
        var merged = self
        let isHouseScene: (HomeScene) -> Bool = { scene in !scene.actions.isEmpty && scene.actions.allSatisfy { ids.contains($0.deviceID) } }
        let guests = Dictionary(uniqueKeysWithValues: house.scenes.map { ($0.id, $0) })
        merged.scenes = scenes.compactMap { scene in
            if let changed = guests[scene.id] { return changed }
            return isHouseScene(scene) ? nil : scene
        } + house.scenes.filter { scene in !scenes.contains { $0.id == scene.id } }
        for id in ids { merged.customizations[id] = house.customizations[id] }
        merged.updatedAt = house.updatedAt
        return merged
    }

    /// The same state, apart from when it was saved.
    func sameContent(as other: SyncState) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
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
    /// A device with no SmartThings integration of its own (the Apple TV) asks for the Mac's access for a while;
    /// the Mac answers with a short-lived access token (nil: it has no SmartThings). The refresh token never leaves.
    case smartThingsAccess
    case smartThingsToken(String?)
    /// Pairing only: the Mac's long-term key for the next connections.
    case key(Data)
    case error(String)
}
