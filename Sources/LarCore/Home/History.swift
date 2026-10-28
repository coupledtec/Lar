import Foundation

/// One look at a device: on or off, and an air conditioner's temperatures.
public struct HistorySample: Codable, Sendable, Equatable {
    public var date: Date
    public var deviceID: String
    public var isOn: Bool?
    public var room: Double?
    public var target: Double?
}

/// The devices' recent past, kept on this device only (a file, 30 days): enough for a day's chart and how long an
/// air conditioner ran. One sample per device every few minutes at most.
public actor HistoryStore {
    public static let shared = HistoryStore()

    static let minimumGap: TimeInterval = 300
    static let keep: TimeInterval = 30 * 86_400
    /// A gap longer than this between two samples isn't counted as "on" time (the app wasn't reading).
    static let longestGap: TimeInterval = 900

    private let file: URL
    private var samples: [HistorySample]?

    public init(file: URL = HistoryStore.defaultFile) {
        self.file = file
    }

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lar/history.json")
    }

    /// Takes the devices worth keeping (air conditioners, lights, plugs, TVs) after a read.
    public func record(_ devices: [HomeDevice], at date: Date = Date()) {
        var all = load()
        var changed = false
        for device in devices where device.isOnline && [.airConditioner, .light, .plug, .tv, .fan].contains(device.kind) {
            if let last = all.last(where: { $0.deviceID == device.id }), date.timeIntervalSince(last.date) < Self.minimumGap { continue }
            all.append(HistorySample(date: date, deviceID: device.id, isOn: device.isOn, room: device.roomTemperature,
                                     target: device.targetTemperature))
            changed = true
        }
        guard changed else { return }
        all.removeAll { date.timeIntervalSince($0.date) > Self.keep }
        samples = all
        save(all)
    }

    public func samples(of deviceID: String, since: Date) -> [HistorySample] {
        load().filter { $0.deviceID == deviceID && $0.date >= since }
    }

    /// How long the device was on between the two dates, from its samples.
    public static func onTime(_ samples: [HistorySample], from start: Date, to end: Date) -> TimeInterval {
        let sorted = samples.sorted { $0.date < $1.date }
        var total: TimeInterval = 0
        for (index, sample) in sorted.enumerated() where sample.isOn == true {
            let next = index + 1 < sorted.count ? sorted[index + 1].date : end
            let until = min(next, sample.date.addingTimeInterval(longestGap), end)
            let from = max(sample.date, start)
            if until > from { total += until.timeIntervalSince(from) }
        }
        return total
    }

    private func load() -> [HistorySample] {
        if let samples { return samples }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([HistorySample].self, from: $0) } ?? []
        samples = read
        return read
    }

    private func save(_ all: [HistorySample]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}

/// What an air conditioner's running time costs, from its power and the tariff (both set by the owner).
public enum EnergyEstimate {
    /// Watts drawn while running; a 12 000 BTU inverter averages about 1 kW.
    public static var watts: Double {
        get { Preferences.object(forKey: "acWatts") as? Double ?? 1000 }
        set { Preferences.set(newValue, forKey: "acWatts") }
    }

    /// The price of a kWh in the device's currency; 0 (the default, since it differs everywhere) leaves the cost out.
    public static var tariff: Double {
        get { Preferences.object(forKey: "energyTariff") as? Double ?? 0 }
        set { Preferences.set(newValue, forKey: "energyTariff") }
    }

    public static func kWh(running seconds: TimeInterval, watts: Double = watts) -> Double { watts * seconds / 3_600_000 }

    /// "3 h 20 min · ~3.3 kWh · ~$2.83", in the device's language and currency.
    public static func text(running seconds: TimeInterval, watts: Double = watts, tariff: Double = tariff,
                            locale: Locale = .current) -> String {
        let minutes = Int(seconds / 60)
        let time = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        let energy = kWh(running: seconds, watts: watts)
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(locale)
        let parts = [time, "~\(energy.formatted(format)) kWh"]
        guard tariff > 0 else { return parts.joined(separator: " · ") }
        return (parts + ["~" + (energy * tariff).formatted(.currency(code: locale.currency?.identifier ?? HomeRegion.currency).locale(locale))]).joined(separator: " · ")
    }
}
