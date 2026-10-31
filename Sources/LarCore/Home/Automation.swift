import Foundation

/// When a scene runs by itself: at a time on chosen weekdays (run by the Mac, which stays on), or on arriving at or
/// leaving home (run by the iPhone, from its location).
public struct SceneSchedule: Codable, Sendable, Equatable, Hashable {
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar's weekdays); empty means every day.
    public var weekdays: Set<Int>

    public init(hour: Int, minute: Int, weekdays: Set<Int> = []) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    public var text: String {
        let time = String(format: "%02d:%02d", hour, minute)
        if weekdays.isEmpty || weekdays.count == 7 { return tr("Todo dia às \(time)") }
        if weekdays == [2, 3, 4, 5, 6] { return tr("Dias úteis às \(time)") }
        if weekdays == [1, 7] { return tr("Fins de semana às \(time)") }
        let names = [tr("dom"), tr("seg"), tr("ter"), tr("qua"), tr("qui"), tr("sex"), tr("sáb")]
        return weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ") + tr(" às \(time)")
    }

    /// The scheduled moments in (from, to], so a check every half minute never runs a scene twice nor skips one.
    func occurrences(after from: Date, through to: Date, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: from)
        while day <= to {
            if let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), date > from, date <= to,
               weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: date)) {
                out.append(date)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }
}

public enum ScenePresence: String, Codable, Sendable, CaseIterable {
    case arrive, leave

    public var text: String {
        switch self {
        case .arrive: tr("Ao chegar em casa")
        case .leave: tr("Ao sair de casa")
        }
    }
}

extension HomeScene {
    /// Scenes whose time came in (from, to]. A Mac that slept through a time doesn't run it late: at most
    /// `lateness` after it.
    public static func due(_ scenes: [HomeScene], after from: Date, through to: Date,
                           lateness: TimeInterval = 600, calendar: Calendar = .current) -> [HomeScene] {
        let start = max(from, to.addingTimeInterval(-lateness))
        return scenes.filter { scene in
            guard let schedule = scene.schedule else { return false }
            return !schedule.occurrences(after: start, through: to, calendar: calendar).isEmpty
        }
    }
}

// MARK: - Turn-off timers

extension HomeStore {
    /// Turns the device off after `delay`; a new timer replaces the old one, nil cancels it. Runs while the app
    /// runs (the Mac always; the iPhone hands its timers to the Mac when paired).
    public func setOffTimer(_ deviceID: String, after delay: TimeInterval?) {
        offTimerTasks[deviceID]?.cancel()
        offTimerTasks[deviceID] = nil
        offTimers[deviceID] = nil
        guard let delay else { return }
        let fire = now().addingTimeInterval(delay)
        offTimers[deviceID] = fire
        offTimerTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.offTimers[deviceID] = nil
            self.offTimerTasks[deviceID] = nil
            self.perform(.power(false), on: deviceID)
        }
    }

    /// "desliga em 23 min", for a device with a timer.
    public func offTimerText(_ deviceID: String) -> String? {
        guard let fire = offTimers[deviceID] else { return nil }
        let minutes = max(1, Int((fire.timeIntervalSince(now()) / 60).rounded(.up)))
        return tr("desliga em \(minutes) min")
    }
}
