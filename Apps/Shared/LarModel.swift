import Foundation
import LarCore
import Observation

/// Ties the settings to the stores on the iPhone and the watch: the device list for every account, and an air
/// conditioner's full controls while its screen is open (polled only then).
@MainActor
@Observable
final class LarModel {
    let home: HomeStore
    let scenes: SceneStore
    @ObservationIgnored let settings: LarSettings
    private(set) var airConditioner: ACStore?
    /// After the list preferences change here (the iPhone hands them to the watch).
    @ObservationIgnored var onListPreferencesChange: (() -> Void)?

    /// - Parameter extraProviders: accounts the shared list doesn't build, like the watch's TVs through the iPhone.
    init(settings: LarSettings, includeTVs: Bool, extraProviders: @escaping () -> [any DeviceProvider] = { [] }) {
        self.settings = settings
        self.scenes = SceneStore(settings: settings)
        defer { settings.bindListPreferences(to: home) { [weak self] in self?.onListPreferencesChange?() } }
        // TVs only through the Google TV remote protocol (paired with the code they show), never ADB.
        self.home = HomeStore(makeProviders: {
            Accounts.providers(settings, includeTVs: includeTVs, tvADB: false, tvClientName: "Lar no iPhone") + extraProviders()
        })
    }

    func openAirConditioner(rawID: String) {
        airConditioner?.suspend()
        settings.deviceID = rawID
        let store = ACStore(settings: settings)
        store.isPopoverVisible = true
        store.start()
        airConditioner = store
    }

    func closeAirConditioner() {
        airConditioner?.suspend()
        airConditioner = nil
        Task { await home.refresh() }
    }

    /// After a key changes: new clients, and a fresh read of every account.
    func accountsChanged() {
        home.reloadAccounts()
        Task { await home.refresh() }
    }
}
