import LarCore
import SwiftUI

@main
struct LarWatchApp: App {
    /// The TVs come from the iPhone, which talks to them (the watch can't reach devices on the local network).
    @MainActor static let model = LarModel(settings: AppSettings(), includeTVs: false, extraProviders: {
        [RelayedTVProvider(send: PhoneLink.sendTV)]
    })
    @State private var model = LarWatchApp.model

    /// Siri may run an intent with no window.
    init() {
        IntentContext.model = Self.model
        Self.model.home.onRefreshed = { WidgetSnapshot.save(from: Self.model.home) }
    }
    @State private var link = PhoneLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchHomeView(model: model, link: link)
                .onAppear { link.start(model: model) }
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .active:
                model.home.isPopoverVisible = true
                model.home.start()
                link.askIfStale()
            case .background:
                model.home.suspend()
            default:
                break
            }
        }
    }
}
