import Foundation
import UserNotifications

/// Posts the alerts (a washer that finished) as notifications, when the owner allows them. The watch shows the
/// iPhone's by itself; the Apple TV has no banners (only the app's badge).
public enum Notifier {
    /// "Avisar quando a lavadora terminar", on unless turned off.
    public static var laundryEnabled: Bool {
        get { Preferences.bool(forKey: "notifyLaundry") ?? true }
        set { Preferences.set(newValue, forKey: "notifyLaundry") }
    }

    /// Asks once; later calls change nothing. Also shows the notifications while the app is in front.
    public static func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = Presenter.shared
        // (`-LarScreenshots YES`: the store's screenshots, with no permission prompt in front.)
        guard laundryEnabled, !UserDefaults.standard.bool(forKey: "LarScreenshots") else { return }
        var options: UNAuthorizationOptions = [.alert, .sound]
        if criticalAllowed { options.insert(.criticalAlert) }
        center.requestAuthorization(options: options) { _, _ in }
    }

    /// Apple granted the critical alerts (an entitlement given on request): the app's Info.plist says so with
    /// `LarCriticalAlerts`. Without it, the intercom is only time-sensitive.
    public static let criticalAllowed: Bool = {
        let value = Bundle.main.object(forInfoDictionaryKey: "LarCriticalAlerts")
        return value as? Bool == true || (value as? String)?.uppercased() == "YES"
    }()


    /// - Parameter force: post even with the laundry alerts off (a scene that ran by itself).
    public static func post(_ alerts: [HomeAlert], force: Bool = false) {
        guard laundryEnabled || force else { return }
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            switch alert.urgency {
            case .normal:
                break
            case .timeSensitive:
                content.interruptionLevel = .timeSensitive
            case .critical:
                #if os(iOS) || os(watchOS)
                if criticalAllowed {
                    content.interruptionLevel = .critical
                    content.sound = .defaultCritical
                    break
                }
                #endif
                content.interruptionLevel = .timeSensitive
            }
            center.add(UNNotificationRequest(identifier: "\(alert.id):\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }
        #endif
    }

    // MARK: Opening a device

    /// Posted (with the device's id as the object) when a notification that opens a device is tapped.
    public static let openDevice = Notification.Name("LarOpenDevice")
    private static let deviceKey = "larOpenDevice"
    /// A device to open once the list shows (the app launched by the tap).
    @MainActor public static var pendingDevice: String?

    /// "Câmera do portão: toque para ver ao vivo": a tap opens the device in the app (from CarPlay, where a camera
    /// can't play while driving).
    public static func postOpen(deviceID: String, title: String, body: String) {
        #if !os(tvOS)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = [deviceKey: deviceID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "open:\(deviceID)", content: content, trigger: nil))
        #endif
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = Presenter()

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }

        #if !os(tvOS)
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let id = response.notification.request.content.userInfo[Notifier.deviceKey] as? String
            completionHandler()
            guard let id else { return }
            Task { @MainActor in
                Notifier.pendingDevice = id
                NotificationCenter.default.post(name: Notifier.openDevice, object: id)
            }
        }
        #endif
    }
}
