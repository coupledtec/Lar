import Foundation
import LarCore
import Observation

typealias AllSettings = SettingsStorage & AccountSettings

/// Ties the settings to the stores: the device list for every account, and an air conditioner's full controls
/// while its screen is open.
@MainActor
@Observable
final class AppModel {
    let home: HomeStore
    @ObservationIgnored let settings: AllSettings
    /// The air conditioner whose screen is open; polled only while it is.
    private(set) var airConditioner: ACStore?
    @ObservationIgnored private let isPreview: Bool

    init(settings: AllSettings) {
        self.settings = settings
        self.home = HomeStore(makeProviders: { Self.providers(settings) })
        self.isPreview = false
    }

    /// Fixed data that never touches the network, for snapshots.
    init(preview home: HomeStore, airConditioner: ACStore? = nil) {
        self.settings = InMemorySettings(token: "preview")
        self.home = home
        self.airConditioner = airConditioner
        self.isPreview = true
    }

    static func providers(_ settings: AllSettings) -> [any DeviceProvider] {
        var out: [any DeviceProvider] = []
        if let token = settings.token, !token.isEmpty {
            out.append(LGProvider(client: ThinQClient(token: token, clientID: settings.clientID)))
        }
        if let tuya = settings.tuya {
            out.append(TuyaClient(credentials: tuya))
        }
        if settings.tvDiscovery || settings.tvHost != nil {
            let discover: @Sendable () async -> [TVDiscovery.Found]
            if settings.tvDiscovery {
                discover = { await TVDiscovery.scan() }
            } else {
                discover = { [] }
            }
            out.append(AndroidTVProvider(
                manualHosts: settings.tvHost.map { [$0] } ?? [],
                known: settings.knownTVs,
                discover: discover,
                remember: { AppSettings.saveKnownTVs($0) }
            ))
        }
        if let smartThings = settings.smartThings {
            out.append(SmartThingsClient(credentials: smartThings, saveRefreshToken: { AppSettings.saveSmartThingsRefreshToken($0) }))
        }
        return out
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
