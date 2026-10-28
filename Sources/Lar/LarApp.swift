import AppKit
import LarCore

@main
struct LarMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            let directory = arguments.indices.contains(index + 1) ? arguments[index + 1] : "snapshots"
            DevTools.renderSnapshots(to: URL(fileURLWithPath: directory))
            return
        }

        let app = NSApplication.shared
        guard StartAtLogin.takeOver() else { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var controller: StatusItemController?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if LAR_NO_INTERCOM
        // The Mac App Store version leaves the intercom out (App Review); the GitHub version keeps it.
        Features.intercom = false
        #endif
        installEditMenu()
        // A menu bar app with no windows: macOS must not close it to save memory.
        ProcessInfo.processInfo.disableAutomaticTermination("Lar fica na barra de menus")
        StartAtLogin.applyDefault()
        let model = AppModel(settings: AppSettings())
        let store = model.home
        let controller = StatusItemController(model: model)
        self.model = model
        self.controller = controller
        Notifier.start()
        #if LAR_APPSTORE
        TipJar.listen()
        #endif
        // iCloud's pushes: the scenes changed on another device (App Store version).
        if CloudSync.isAvailable { NSApp.registerForRemoteNotifications() }
        model.startSync()
        model.startScheduler()
        model.startAlexaImport()
        if Features.intercom { model.startPhone() }
        #if !LAR_APPSTORE
        model.updater.isBusy = { [weak model] in model?.phone.call != nil }
        model.updater.start()
        #endif
        #if LAR_PRIVATE
        PrivateExtensions.start(model)
        #endif
        store.onAlerts = { [weak model] alerts in
            model?.post(alerts)
            for alert in alerts {
                model?.noticeOnTVs(alert.title, alert.body, doorbell: false)
                if model?.announcesOnEchos == true { model?.home.announceOnEchos("\(alert.title): \(alert.body)") }
            }
        }
        store.onUnauthorized = { [weak model] provider in
            if provider == .smartThings { model?.reconnectSmartThings() }
        }
        store.onRefreshed = { [weak store] in
            guard let devices = store?.devices else { return }
            Task { await HistoryStore.shared.record(devices) }
        }
        store.start()

        // Don't poll while the Mac sleeps; catch up right after waking.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { store.suspend() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { store.start() }
        })

        if let path = ProcessInfo.processInfo.environment["LAR_LIVE_SNAPSHOT"] {
            DevTools.snapshotLive(model: model, to: URL(fileURLWithPath: path))
        }

        let openOnLaunch = ProcessInfo.processInfo.environment["LAR_OPEN_ON_LAUNCH"] == "1"
        if openOnLaunch || !store.hasAccounts {
            // Give the status item a moment to appear in the menu bar before anchoring to it.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                controller.showPopover()
            }
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard CloudSync.isChange(userInfo), let model else { return }
        Task { await model.syncWithCloud() }
    }

    /// `lar://cena/Dormir`, `lar://ligar/TV da Sala`… (Shortcuts' "Open URL"). Right after launch, the devices are
    /// read first.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls {
            guard let link = LarLink(url) else { continue }
            if case .call(let number) = link {
                if Features.intercom { model.call(number) }
                continue
            }
            if link == .hangUp {
                Task { await model.phone.hangup() }
                continue
            }
            Task {
                if model.home.devices.isEmpty { await model.home.refresh() }
                model.home.open(link, scenes: model.scenes.scenes)
            }
        }
    }

    /// An accessory app has no menu bar, and without one nothing routes ⌘V, ⌘C, ⌘X, ⌘A or ⌘Z to the
    /// focused text field. This menu is never shown; it only supplies the key equivalents.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (index, (title, action, key)) in items.enumerated() {
            if index == 2 { edit.addItem(.separator()) }
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
