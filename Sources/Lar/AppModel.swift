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
        })
        try? server.start()
        sync = server
    }

    /// Runs the scenes whose time has come (checked every half minute; the Mac is the one that's always on).
    func startPhone() {
        let phone = phone
        phone.onIncoming = { [weak self] call in
            self?.noticeOnTVs(call.name == "Porteiro" ? "Porteiro chamando" : "Chamada: \(call.name)",
                              "Atenda no Mac ou no iPhone.", doorbell: true)
            CallWindow.show(phone)
            CallWindow.startRinging()
            Notifier.post([HomeAlert(id: "call:\(call.id)", title: call.name, body: "Chamando no porteiro.")], force: true)
        }
        phone.onEnded = { _ in CallWindow.closeSoon() }
        Task { await phone.start() }
    }

    func callDoor() {
        call(nil)
    }

    /// Calls the intercom (nil) or a number, and shows the call.
    func call(_ number: String?) {
        Task { await phone.dial(number) }
        CallWindow.show(phone)
    }

    /// Free My TV on the TVs (by ADB): the scenes and the list's organization, whenever they change (checked every
    /// minute), and the notices below.
    func startTVBridge() {
        let settings = settings, home = home
        Task {
            var lastSent = Data()
            var sentAt = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(lastSent.isEmpty ? 20 : 60))
                let json = FreeMyTV.export(scenes: settings.scenes, customizations: settings.customizations, grouping: settings.grouping)
                // Again after a while too, for a TV that was off.
                guard json != lastSent || Date().timeIntervalSince(sentAt) > 1800,
                      let tv = home.tv as? AndroidTVProvider else { continue }
                if await tv.sendFreeMyTVUpdate(json) > 0 {
                    lastSent = json
                    sentAt = Date()
                }
            }
        }
    }

    /// A notice on the TVs' screens (the intercom calling, the washer done).
    func noticeOnTVs(_ title: String, _ body: String, doorbell: Bool) {
        guard let tv = home.tv as? AndroidTVProvider else { return }
        Task { await tv.sendFreeMyTVNotice(title: title, body: body, doorbell: doorbell) }
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
                                             body: problem ?? "Cena executada no horário.")], force: true)
                }
                last = now
            }
        }
    }

    func showPairingCode() {
        pairingCode = try? sync?.startPairing()
        // The code works for five minutes.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            self?.hidePairingCode()
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
