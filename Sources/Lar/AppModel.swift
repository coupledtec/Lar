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
    /// The intercom (SIP): always registered while the Mac runs, so it rings here even with the iPhone away.
    let phone = PhoneStore()
    #if !LAR_APPSTORE
    /// New versions from GitHub, installed by themselves (the App Store version is updated by the store).
    let updater = Updater()
    #endif
    @ObservationIgnored let settings: AllSettings
    /// The air conditioner whose screen is open; polled only while it is.
    private(set) var airConditioner: ACStore?
    @ObservationIgnored private let isPreview: Bool

    /// The air conditioner's room temperature next to the house in the menu bar.
    var showsTemperatureInMenuBar = Preferences.bool(forKey: "menuBarTemperature") ?? false {
        didSet { Preferences.set(showsTemperatureInMenuBar, forKey: "menuBarTemperature") }
    }

    /// Answers the paired iPhones (scenes and the list's organization); nil in previews.
    @ObservationIgnored private(set) var sync: SyncServer?
    /// The code an iPhone types to pair, while shown.
    private(set) var pairingCode: String?

    func startSync() {
        let settings = settings, home = home, scenes = scenes
        let server = SyncServer(state: { SyncState.capture(settings) }, apply: { incoming in
            incoming.apply(to: settings)
            scenes.reload()
            home.customizations = settings.customizations
            home.grouping = settings.grouping
        }, offTimer: { id, seconds in
            guard home.device(id: id) != nil else { return false }
            home.setOffTimer(id, after: seconds)
            return true
        }, claim: { SmartThingsClaims.own(settings, device: "Mac") })
        try? server.start()
        sync = server
        startCloudSync()
        if HAPBridge.isEnabled { startHomeKitBridge() }
    }

    // MARK: Home app

    /// Lar's devices in Apple's Home app, with the Mac as a HomeKit bridge; nil while turned off.
    @ObservationIgnored private(set) var homeKitBridge: HAPBridge?
    /// Whether an iPhone has added the bridge to the Home app (the settings then hide the code).
    private(set) var homeKitPaired = false

    var usesHomeKitBridge: Bool {
        get { homeKitBridge != nil }
        set {
            HAPBridge.isEnabled = newValue
            if newValue { startHomeKitBridge() } else { stopHomeKitBridge() }
        }
    }

    private func startHomeKitBridge() {
        guard homeKitBridge == nil, !isPreview else { return }
        let home = home
        let bridge = HAPBridge(name: "Lar", devices: {
            // Hidden ones, and the ones the Home app already has by themselves (marked by the iPhone), stay out.
            home.devices.filter {
                let custom = home.customization(of: $0.id)
                return !custom.isHidden && custom.excludedFromHomeApp != true
            }
        }, perform: { command, id in home.perform(command, on: id) },
        liveURL: { id in try await home.liveStreamURL(for: id) })
        bridge.onChange = { [weak self, weak bridge] in self?.homeKitPaired = bridge?.isPaired ?? false }
        bridge.start()
        homeKitBridge = bridge
        homeKitPaired = bridge.isPaired
    }

    private func stopHomeKitBridge() {
        homeKitBridge?.stop()
        homeKitBridge = nil
    }

    /// Forgets the Home app's pairings: a new code, and the bridge is added again as a new one.
    func resetHomeKitBridge() {
        homeKitBridge?.reset()
        homeKitPaired = homeKitBridge?.isPaired ?? false
    }

    /// The last iCloud sync and what went wrong, if it did (App Store version only).
    private(set) var lastCloudSync: Date?
    private(set) var cloudProblem: String?

    /// iCloud, in the App Store version: at launch, half a minute after a change here, on iCloud's pushes and every
    /// quarter of an hour. Also says, every hour, that this Mac publishes the alerts for the iPhone.
    private func startCloudSync() {
        guard CloudSync.isAvailable else { return }
        let settings = settings
        Task { [weak self] in
            var lastChange = settings.syncUpdatedAt
            var lastFull = Date.distantPast
            var lastAnnounce = Date.distantPast
            while !Task.isCancelled {
                let now = Date()
                if settings.syncUpdatedAt != lastChange || now.timeIntervalSince(lastFull) > 15 * 60 {
                    await self?.syncWithCloud()
                    lastChange = settings.syncUpdatedAt
                    lastFull = now
                }
                if now.timeIntervalSince(lastAnnounce) > 3600 {
                    await CloudSync.announcePublisher()
                    lastAnnounce = now
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func syncWithCloud() async {
        guard CloudSync.isAvailable else { return }
        do {
            if try await CloudSync.sync(settings) == .pull {
                scenes.reload()
                home.customizations = settings.customizations
                home.grouping = settings.grouping
            }
            lastCloudSync = Date()
            cloudProblem = nil
        } catch {
            cloudProblem = (error as? CloudSyncError)?.message ?? error.localizedDescription
        }
    }

    /// A notification here, and for the iPhone through iCloud (App Store version).
    func post(_ alerts: [HomeAlert], force: Bool = false) {
        Notifier.post(alerts, force: force)
        guard force || Notifier.laundryEnabled else { return }
        Task { await CloudSync.publish(alerts) }
    }

    /// Runs the scenes whose time has come (checked every half minute; the Mac is the one that's always on).
    func startPhone() {
        let phone = phone
        phone.onIncoming = { [weak self] call in
            self?.noticeOnTVs(call.name == "Porteiro" ? "Porteiro chamando" : "Chamada: \(call.name)",
                              "Atenda no Mac ou no iPhone.", doorbell: true)
            CallWindow.show(phone)
            CallWindow.startRinging()
            self?.post([HomeAlert(id: "call:\(call.id)", title: call.name, body: String(localized: "Chamando no porteiro."),
                                  urgency: .critical)], force: true)
            if self?.announcesOnEchos == true {
                self?.home.announceOnEchos(call.name == "Porteiro" ? String(localized: "Porteiro chamando") : String(localized: "Chamada de \(call.name)"), title: String(localized: "Porteiro"))
            }
        }
        phone.onEnded = { _ in CallWindow.closeSoon() }
        Task { await phone.start() }
    }

    /// The intercom and the alerts said on the Echos too (Ajustes → Alexa; on unless turned off).
    var announcesOnEchos: Bool { Preferences.bool(forKey: "alexaAnnounce") ?? true }

    func callDoor() {
        call(nil)
    }

    /// Calls the intercom (nil) or a number, and shows the call.
    func call(_ number: String?) {
        guard Features.intercom else { return }
        Task { await phone.dial(number) }
        CallWindow.show(phone)
    }

    /// Who else hears the notices (the intercom calling, the washer done): extensions add themselves.
    @ObservationIgnored var noticeHandlers: [@MainActor (_ title: String, _ body: String, _ doorbell: Bool) -> Void] = []

    /// A notice for the screens around the house, through whatever extension shows them.
    func noticeOnTVs(_ title: String, _ body: String, doorbell: Bool) {
        for handler in noticeHandlers { handler(title, body, doorbell) }
    }

    /// New Alexa routines become scenes by themselves: a minute after launch, then every hour (Ajustes → Alexa).
    func startAlexaImport() {
        let home = home, scenes = scenes
        Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                if AlexaRoutineImport.autoImport, home.alexa != nil {
                    _ = try? await AlexaRoutineImport.run(home: home, scenes: scenes, onlyNew: true)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func startScheduler() {
        let home = home, scenes = scenes
        Task {
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let now = Date()
                for scene in HomeScene.due(scenes.scenes, after: last, through: now) {
                    if home.devices.isEmpty { await home.refresh() }
                    let problem = home.run(scene)
                    Notifier.post([HomeAlert(id: "scene:\(scene.id)", title: scene.name,
                                             body: problem ?? String(localized: "Cena executada no horário."))], force: true)
                }
                last = now
            }
        }
    }

    func showPairingCode() {
        sync?.onPairingStopped = { [weak self] in self?.pairingCode = nil }
        let code = try? sync?.startPairing()
        pairingCode = code
        // The code works for two minutes (a code shown again later keeps its own two).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            if let self, self.pairingCode == code { self.hidePairingCode() }
        }
    }

    func hidePairingCode() {
        sync?.stopPairing()
        pairingCode = nil
    }

    func forgetPairedPhones() {
        try? sync?.forgetPairedDevices()
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
        let store = DemoHome.isOn ? DemoHome.airConditioner() : ACStore(settings: settings)
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

    /// SmartThings refused the token: sign in again by itself, or say so.
    func reconnectSmartThings() {
        SmartThingsReconnect.attempt(settings, renewed: { [weak self] in self?.accountsChanged() },
                                     needsPerson: { [weak self] in self?.post([SmartThingsReconnect.needsPersonAlert], force: true) })
    }

    /// After a key changes: new clients, and a fresh read of every account.
    func accountsChanged() {
        home.reloadAccounts()
        Task { await home.refresh() }
    }
}
