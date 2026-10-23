import BackgroundTasks
import LarCore
import SwiftUI

@main
struct LarPhoneApp: App {
    /// One model for the phone's window and the CarPlay screen.
    @MainActor static let model = LarModel(settings: AppSettings(), includeTVs: true)
    @MainActor static let link = WatchLink()
    @State private var model = LarPhoneApp.model
    @State private var link = LarPhoneApp.link
    @Environment(\.scenePhase) private var phase

    /// The watch's link starts with the app, not with its window: when the watch asks for something (a TV, a fresh
    /// SmartThings token), iOS launches the app in the background with no window at all.
    init() {
        Self.link.start(model: Self.model)
        IntentContext.model = Self.model
        Self.model.onListPreferencesChange = { Self.link.sendAccounts() }
        Self.model.home.onAlerts = { Notifier.post($0) }
        Self.model.home.onRefreshed = {
            WidgetSnapshot.save(from: Self.model.home)
            LaundryActivities.update(Self.model.home.devices)
        }
        Notifier.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeListView(model: model, link: link)
                .tint(.accentColor)
                .onOpenURL { url in
                    guard let link = LarLink(url) else { return }
                    Task {
                        if model.home.devices.isEmpty { await model.home.refresh() }
                        model.home.open(link, scenes: model.scenes.scenes)
                    }
                }
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .active:
                // Accounts copied from the Mac over the cable (Documents/lar-import.json), deleted once read.
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                if AccountsImport.importIfPresent(in: documents, into: model.settings) { model.accountsChanged() }
                // Keys saved while the iPhone was unlocked only (older versions) become readable in the background too;
                // accounts the app couldn't read when woken locked are read now.
                Keychain.migrateAccessibility()
                model.home.reloadAccountsIfChanged()
                model.home.isPopoverVisible = true
                model.home.start()
                link.sendAccounts()
            case .background:
                model.home.suspend()
                Self.scheduleRefresh()
            default:
                break
            }
        }
        // Every so often iOS wakes the app for a read, so a finished wash is announced with the app closed.
        .backgroundTask(.appRefresh(Self.refreshTask)) {
            await Self.model.home.refresh()
            await Self.scheduleRefresh()
        }
    }

    static let refreshTask = "com.coupled.lar.refresh"

    /// Asks iOS for the next background read (it decides when; usually within the hour).
    @MainActor
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
