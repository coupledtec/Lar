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
    /// The last sync with the Mac, and what went wrong if it did.
    private(set) var lastSync: Date?
    private(set) var syncProblem: String?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// Brings the scenes and the list's organization in step with the Mac (iPhone only, when paired).
    func syncWithMac() async {
        guard SyncClient.isPaired else { return }
        do {
            if try await SyncClient.sync(settings) == .pull {
                scenes.reload()
                home.customizations = settings.customizations
                home.grouping = settings.grouping
                onListPreferencesChange?()
            }
            lastSync = Date()
            syncProblem = nil
        } catch {
            syncProblem = (error as? SyncError)?.message ?? error.localizedDescription
        }
    }

    /// A turn-off timer: kept here, and handed to the Mac when paired, which keeps it even if the iPhone sleeps.
    func setOffTimer(_ deviceID: String, minutes: Int?) {
        let seconds = minutes.map { TimeInterval($0 * 60) }
        home.setOffTimer(deviceID, after: seconds)
        Task { _ = await SyncClient.handOffTimer(deviceID: deviceID, seconds: seconds) }
    }

    /// A sync shortly after a change here (several quick changes go as one).
    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncWithMac()
        }
    }

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
