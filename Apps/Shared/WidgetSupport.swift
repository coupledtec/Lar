import Foundation
import LarCore
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The list as the app last read it, for widgets and complications to show at once (they read again when they can).
/// Kept in the shared keychain group, like the rest of the preferences.
struct WidgetSnapshot: Codable {
    var date: Date
    /// The visible devices, with the owner's names, favorites first.
    var devices: [HomeDevice]
    var favorites: Set<String>

    var onCount: Int { devices.filter { $0.isOn == true && $0.isOnline && $0.kind != .camera }.count }

    static let key = "widgetSnapshot"

    static func load() -> WidgetSnapshot? {
        Preferences.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }

    /// Saves the store's list and asks the widgets to redraw (only when it changed).
    @MainActor
    static func save(from home: HomeStore) {
        let sections = home.sections(grouping: .kind)
        let favorites = Set(home.customizations.filter { $0.value.isFavorite }.keys)
        let devices = sections.flatMap(\.devices)
        guard !devices.isEmpty else { return }
        if let old = load(), old.devices == devices { return }
        let snapshot = WidgetSnapshot(date: Date(), devices: devices, favorites: favorites)
        Preferences.set(try? JSONEncoder().encode(snapshot), forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

#if canImport(ActivityKit) && os(iOS)
/// A washer or dryer's cycle on the Lock Screen and in the Dynamic Island, counting down by itself.
struct LaundryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stage: String
        var ends: Date
    }

    var deviceID: String
    var name: String
}

/// Starts, updates and ends the laundry Live Activities from the device list (after every read of the iPhone app).
@MainActor
enum LaundryActivities {
    static func update(_ devices: [HomeDevice]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = devices.filter { $0.kind == .laundry && $0.controls["remainMinutes"].flatMap(Int.init) ?? 0 > 0 }
        for activity in Activity<LaundryActivityAttributes>.activities
        where !running.contains(where: { $0.id == activity.attributes.deviceID }) {
            nonisolated(unsafe) let finished = activity
            Task { await finished.end(nil, dismissalPolicy: .default) }
        }
        for device in running {
            let minutes = Int(device.controls["remainMinutes"] ?? "") ?? 0
            let state = LaundryActivityAttributes.ContentState(
                stage: device.detail.components(separatedBy: " · ").first ?? "Lavando",
                ends: Date().addingTimeInterval(TimeInterval(minutes * 60))
            )
            let content = ActivityContent(state: state, staleDate: state.ends.addingTimeInterval(600))
            if let activity = Activity<LaundryActivityAttributes>.activities.first(where: { $0.attributes.deviceID == device.id }) {
                // Small drifts aren't worth an update: the countdown runs by itself.
                if abs(activity.content.state.ends.timeIntervalSince(state.ends)) > 90 || activity.content.state.stage != state.stage {
                    nonisolated(unsafe) let current = activity
                    Task { await current.update(content) }
                }
            } else {
                _ = try? Activity.request(attributes: LaundryActivityAttributes(deviceID: device.id, name: device.name), content: content)
            }
        }
    }
}
#endif
