import Foundation

/// Something worth a notification, found by comparing two reads of the devices.
public struct HomeAlert: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var urgency: Urgency

    public init(id: String, title: String, body: String, urgency: Urgency = .normal) {
        self.id = id
        self.title = title
        self.body = body
        self.urgency = urgency
    }

    /// How hard the notification tries to be seen.
    public enum Urgency: Sendable {
        case normal
        /// Through Focus and the notification summary (the washer done).
        case timeSensitive
        /// Rings even in silent mode, where Apple allowed it (the intercom); otherwise time-sensitive.
        case critical
    }

    /// LG's run states while a cycle is going (anything not idle, paused or done).
    static let idleStates: Set = ["POWER_OFF", "INITIAL", "END", "COMPLETE", "SLEEP", "PAUSE", "ERROR", "STANDBY"]
    static let doneStates: Set = ["END", "COMPLETE"]

    /// A washer or dryer that was running and has just finished; a robot that got stuck or whose bin is full (any
    /// device's new `problem`); a camera that saw movement.
    public static func alerts(from previous: [HomeDevice], to current: [HomeDevice]) -> [HomeAlert] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [HomeAlert] = current.compactMap { device in
            guard let problem = device.controls["problem"], let was = before[device.id], was.controls["problem"] != problem else { return nil }
            return HomeAlert(id: "\(device.id):problem", title: device.name, body: problem, urgency: .timeSensitive)
        }
        out += current.compactMap { device in
            guard device.kind == .camera, let motion = device.controls["motion"], let was = before[device.id],
                  was.controls["motion"] != nil, was.controls["motion"] != motion else { return nil }
            return HomeAlert(id: "\(device.id):motion", title: device.name, body: tr("Movimento detectado. Toque para ver ao vivo."),
                             urgency: .timeSensitive)
        }
        return out + current.compactMap { device in
            guard device.kind == .laundry, let now = device.controls["runState"], doneStates.contains(now),
                  let was = before[device.id]?.controls["runState"], !idleStates.contains(was)
            else { return nil }
            return HomeAlert(id: "\(device.id):done", title: device.name, body: tr("O ciclo terminou."), urgency: .timeSensitive)
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
