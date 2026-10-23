import Foundation
import UserNotifications

/// Posts the alerts (a washer that finished) as notifications, when the owner allows them. The watch shows the
/// iPhone's by itself.
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
        guard laundryEnabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameter force: post even with the laundry alerts off (a scene that ran by itself).
    public static func post(_ alerts: [HomeAlert], force: Bool = false) {
        guard laundryEnabled || force else { return }
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "\(alert.id):\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = Presenter()

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}
