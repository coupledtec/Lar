import Foundation

/// Something worth a notification, found by comparing two reads of the devices.
public struct HomeAlert: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String

    /// LG's run states while a cycle is going (anything not idle, paused or done).
    static let idleStates: Set = ["POWER_OFF", "INITIAL", "END", "COMPLETE", "SLEEP", "PAUSE", "ERROR", "STANDBY"]
    static let doneStates: Set = ["END", "COMPLETE"]

    /// A washer or dryer that was running and has just finished.
    public static func alerts(from previous: [HomeDevice], to current: [HomeDevice]) -> [HomeAlert] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.compactMap { device in
            guard device.kind == .laundry, let now = device.controls["runState"], doneStates.contains(now),
                  let was = before[device.id]?.controls["runState"], !idleStates.contains(was)
            else { return nil }
            return HomeAlert(id: "\(device.id):done", title: device.name, body: "O ciclo terminou.")
        }
    }
}

extension HomeStore {
    /// Whether a refresh just ended a cycle; the apps post these as notifications.
    func alerts(after previous: [HomeDevice]) -> [HomeAlert] {
        HomeAlert.alerts(from: previous, to: serverDevices).map { alert in
            var alert = alert
            if let name = serverDevices.first(where: { alert.id.hasPrefix($0.id) }).flatMap({ customizations[$0.id]?.name }) {
                alert.title = name
            }
            return alert
        }
    }
}
