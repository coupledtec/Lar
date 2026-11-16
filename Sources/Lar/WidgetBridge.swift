#if LAR_APPSTORE
import Foundation
import LarCore
import WidgetKit

/// The App Store version's widgets (the GitHub version has none: SwiftPM doesn't build widget extensions). They have
/// no accounts of their own: this keeps them the list (`WidgetRelay`) and sends what they tap.
@MainActor
enum WidgetBridge {
    /// State changes from outside (someone at the switch) redraw the widgets at most this often; their own taps and
    /// a new device, name or room, at once.
    static let backgroundInterval: TimeInterval = 5 * 60

    private static var lastReload = Date.distantPast
    private static var timer: Timer?
    /// A change saved without a redraw (the interval): the next tick past it redraws.
    private static var pending = false

    static func start(_ model: AppModel) {
        guard WidgetRelay.isAvailable else { return }
        WidgetRelay.observeRequests { handleRequests(model) }
        // Taps left while the app was starting.
        handleRequests(model)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { publish(model) }
        }
    }

    private static func handleRequests(_ model: AppModel) {
        let requests = WidgetRelay.takeRequests()
        guard !requests.isEmpty else { return }
        for request in requests {
            switch request {
            case .command(let deviceID, let command):
                // Never unlocking: the widgets only lock (`perform` refuses it without Touch ID anyway).
                model.home.perform(command, on: deviceID, force: true)
            case .key(let deviceID, let key):
                if let key = AndroidTVProvider.Key(rawValue: key) { model.home.press(key, on: deviceID) }
            }
        }
        // The expected state at once (the store shows it before the accounts answer), and again once sent.
        publish(model, urgent: true)
        Task {
            await model.home.waitUntilSent()
            publish(model, urgent: true)
        }
    }

    /// Saves the list for the widgets and asks them to redraw when it changed.
    static func publish(_ model: AppModel, urgent: Bool = false) {
        let home = model.home
        let devices = home.sections(grouping: .kind).flatMap(\.devices)
        guard !devices.isEmpty else { return }
        let rooms = Dictionary(uniqueKeysWithValues: devices.compactMap { device in home.room(of: device.id).map { (device.id, $0) } })
        let feed = WidgetRelay.Feed(date: Date(), devices: devices,
                                    favorites: home.customizations.filter { $0.value.isFavorite }.keys.sorted(),
                                    rooms: rooms, scenes: model.scenes.scenes)
        let old = WidgetRelay.readFeed()
        let changed = !feed.sameContent(as: old)
        if changed { WidgetRelay.write(feed) }
        let structural = changed && (old.map { old in
            old.devices.map { "\($0.id)|\($0.name)|\($0.kind)" } != feed.devices.map { "\($0.id)|\($0.name)|\($0.kind)" }
                || old.rooms != feed.rooms || old.favorites != feed.favorites || old.scenes != feed.scenes
        } ?? true)
        let due = (changed || pending) && Date().timeIntervalSince(lastReload) >= backgroundInterval
        guard (changed && (urgent || structural)) || due else {
            if changed { pending = true }
            return
        }
        lastReload = Date()
        pending = false
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
