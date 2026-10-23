import Foundation
import LarCore
import Observation

typealias AllSettings = LarSettings

/// Ties the settings to the stores: the device list for every account, and an air conditioner's full controls
/// while its screen is open.
@MainActor
@Observable
final class AppModel {
    let home: HomeStore
    let scenes: SceneStore
    @ObservationIgnored let settings: AllSettings
    /// The air conditioner whose screen is open; polled only while it is.
    private(set) var airConditioner: ACStore?
    @ObservationIgnored private let isPreview: Bool

    /// The air conditioner's room temperature next to the house in the menu bar.
    var showsTemperatureInMenuBar = Preferences.bool(forKey: "menuBarTemperature") ?? false {
        didSet { Preferences.set(showsTemperatureInMenuBar, forKey: "menuBarTemperature") }
    }

    /// ⌃⌥L opens the Lar from any app.
    var usesHotKey = Preferences.bool(forKey: "globalHotKey") ?? true {
        didSet { Preferences.set(usesHotKey, forKey: "globalHotKey") }
    }

    init(settings: AllSettings) {
        self.settings = settings
        self.home = HomeStore(makeProviders: { Self.providers(settings) })
        self.scenes = SceneStore(settings: settings)
        self.isPreview = false
        settings.bindListPreferences(to: home)
    }

    /// Fixed data that never touches the network, for snapshots.
    init(preview home: HomeStore, airConditioner: ACStore? = nil) {
        let settings = InMemorySettings(token: "preview")
        self.settings = settings
        self.scenes = SceneStore(settings: settings)
        self.home = home
        self.airConditioner = airConditioner
        self.isPreview = true
    }

    static func providers(_ settings: AllSettings) -> [any DeviceProvider] {
        Accounts.providers(settings, includeTVs: true)
    }

    // MARK: Air conditioner screen

    func openAirConditioner(rawID: String) {
        guard !isPreview else { return }
        airConditioner?.suspend()
        settings.deviceID = rawID
        let store = ACStore(settings: settings)
        store.isPopoverVisible = true
        store.start()
        airConditioner = store
    }

    func closeAirConditioner() {
        guard !isPreview else { return }
        airConditioner?.suspend()
        airConditioner = nil
        // The list shows the unit's new state sooner.
        Task { await home.refresh() }
    }

    // MARK: Accounts

    /// After a key changes: new clients, and a fresh read of every account.
    func accountsChanged() {
        home.reloadAccounts()
        Task { await home.refresh() }
    }
}
