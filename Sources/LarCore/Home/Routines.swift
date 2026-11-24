import Foundation

// MARK: - Conditions

/// When a scene that runs by itself (on a time, arriving, leaving) really runs: only in a hot house, only at night.
public struct SceneCondition: Codable, Sendable, Equatable, Hashable {
    /// Only when the house is warmer than this (°C), by the room temperature its air conditioners or sensors read.
    public var warmerThan: Double?
    /// Only between sunset and sunrise (at home's spot; without it, 18:00 to 6:00).
    public var atNight: Bool?

    public init(warmerThan: Double? = nil, atNight: Bool? = nil) {
        self.warmerThan = warmerThan
        self.atNight = atNight
    }

    public var isEmpty: Bool { warmerThan == nil && atNight != true }

    /// "Só acima de 26 °C · só à noite".
    public var text: String {
        var parts: [String] = []
        if let warmerThan { parts.append(tr("só acima de \(Int(warmerThan)) °C")) }
        if atNight == true { parts.append(tr("só à noite")) }
        return parts.joined(separator: " · ")
    }

    /// Whether it holds now. A temperature nobody reads doesn't hold the scene back.
    public func holds(devices: [HomeDevice], now: Date = Date(), home: Coordinate? = nil, calendar: Calendar = .current) -> Bool {
        if let warmerThan {
            let readings = devices.compactMap(\.roomTemperature)
            if let warmest = readings.max(), warmest <= warmerThan { return false }
        }
        if atNight == true, !SolarTime.isDark(at: now, home: home, calendar: calendar) { return false }
        return true
    }
}

extension HomeScene {
    /// Whether it runs by itself now (its condition, if any).
    public func shouldRun(devices: [HomeDevice], now: Date = Date(), home: Coordinate? = nil) -> Bool {
        condition?.holds(devices: devices, now: now, home: home) ?? true
    }

    /// "Ao chegar em casa", "Chegando (a 1,5 km)", "Todo dia às 07:00", with its condition.
    public var triggerText: String? {
        var text: String?
        if let presence {
            if presence == .arrive, let approachDistance {
                text = tr("Chegando (a \(Coordinate.distanceText(approachDistance)))")
            } else {
                text = presence.text
            }
        } else if let schedule {
            text = schedule.text
        }
        guard let text else { return nil }
        guard let condition, !condition.isEmpty else { return text }
        return "\(text) · \(condition.text)"
    }
}

/// A spot on the map (home's, marked on the iPhone).
public struct Coordinate: Codable, Sendable, Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "800 m", "1,5 km".
    public static func distanceText(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters)) m"
            : Measurement(value: meters / 1000, unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}

/// Sunrise and sunset from the date and the spot (NOAA's simple formula, about a minute off): what "só à noite"
/// means, with no network.
public enum SolarTime {
    /// The sun is down (between sunset and the next sunrise). Without a spot, 18:00 to 6:00 on the clock.
    public static func isDark(at date: Date, home: Coordinate?, calendar: Calendar = .current) -> Bool {
        guard let home else {
            let hour = calendar.component(.hour, from: date)
            return hour >= 18 || hour < 6
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // The days around it in UTC: a sunset can fall on the next UTC day.
        for offset in -1...1 {
            guard let day = utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: date)),
                  let (rise, set) = daylight(on: day, at: home, calendar: utc) else { continue }
            if date >= rise && date < set { return false }
        }
        // Polar day: no sunset anywhere around.
        if (-1...1).allSatisfy({ offset in
            utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: date)).map { daylight(on: $0, at: home, calendar: utc) == nil } ?? true
        }) {
            return abs(home.latitude) > 60 && isWinter(date, home: home, calendar: utc)
        }
        return true
    }

    /// The sunrise and the sunset following it, for that UTC day; nil when the sun doesn't rise or set.
    static func daylight(on day: Date, at home: Coordinate, calendar: Calendar) -> (Date, Date)? {
        guard let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day),
              let rise = hour(rising: true, dayOfYear: dayOfYear, at: home),
              let set = hour(rising: false, dayOfYear: dayOfYear, at: home) else { return nil }
        let sunrise = day.addingTimeInterval(rise * 3600)
        var sunset = day.addingTimeInterval(set * 3600)
        if sunset <= sunrise { sunset.addTimeInterval(86_400) }
        return (sunrise, sunset)
    }

    /// The UTC hour of sunrise or sunset.
    static func hour(rising: Bool, dayOfYear: Int, at home: Coordinate) -> Double? {
        let rad = Double.pi / 180
        let lngHour = home.longitude / 15
        let t = Double(dayOfYear) + ((rising ? 6 : 18) - lngHour) / 24
        let anomaly = 0.9856 * t - 3.289
        var longitude = anomaly + 1.916 * sin(anomaly * rad) + 0.020 * sin(2 * anomaly * rad) + 282.634
        longitude = longitude.truncatingRemainder(dividingBy: 360)
        if longitude < 0 { longitude += 360 }
        var ascension = atan(0.91764 * tan(longitude * rad)) / rad
        ascension = ascension.truncatingRemainder(dividingBy: 360)
        if ascension < 0 { ascension += 360 }
        ascension += floor(longitude / 90) * 90 - floor(ascension / 90) * 90
        ascension /= 15
        let sinDeclination = 0.39782 * sin(longitude * rad)
        let cosDeclination = cos(asin(sinDeclination))
        let cosHour = (cos(90.833 * rad) - sinDeclination * sin(home.latitude * rad)) / (cosDeclination * cos(home.latitude * rad))
        guard cosHour >= -1, cosHour <= 1 else { return nil }
        var hourAngle = acos(cosHour) / rad
        if rising { hourAngle = 360 - hourAngle }
        hourAngle /= 15
        let local = hourAngle + ascension - 0.06571 * t - 6.622
        var hour = (local - lngHour).truncatingRemainder(dividingBy: 24)
        if hour < 0 { hour += 24 }
        return hour
    }

    private static func isWinter(_ date: Date, home: Coordinate, calendar: Calendar) -> Bool {
        let month = calendar.component(.month, from: date)
        let northernWinter = month >= 10 || month <= 3
        return home.latitude > 0 ? northernWinter : !northernWinter
    }
}

// MARK: - Alerts the owner turns on

/// Alerts offered among the suggested routines; off until accepted. They go with the scenes to the other devices.
public enum HomeWatch: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Left home with an air conditioner, a TV, a light… on: "Desligar tudo".
    case forgotOn
    /// A door unlocked for 10 minutes at night (22:00 to 6:00): "Trancar".
    case unlockedAtNight
    /// Arriving with the washer or dryer done and the clothes waiting.
    case laundryOnArrival
    /// A camera's movement while nobody's home, more urgent.
    case motionAway
    /// The air conditioners went past the day's energy limit: "Subir 1 °C".
    case energy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forgotOn: tr("Esqueci ligado")
        case .unlockedAtNight: tr("Porta destrancada à noite")
        case .laundryOnArrival: tr("Roupa pronta ao chegar")
        case .motionAway: tr("Movimento com a casa vazia")
        case .energy: tr("Energia do ar no dia")
        }
    }

    public var detail: String {
        switch self {
        case .forgotOn: tr("Ao sair de casa, avisa o que ficou ligado, com o botão Desligar tudo.")
        case .unlockedAtNight: tr("Porta destrancada há mais de 10 minutos entre 22h e 6h: aviso com o botão Trancar.")
        case .laundryOnArrival: tr("Ao chegar, lembra da lavadora ou da secadora que terminou e está esperando.")
        case .motionAway: tr("Movimento numa câmera depois de sair de casa vira um aviso mais forte.")
        case .energy: tr("Quando o ar passa do limite de kWh do dia, avisa e oferece subir 1 °C.")
        }
    }

    public var symbol: String {
        switch self {
        case .forgotOn: "powerplug"
        case .unlockedAtNight: "lock.open"
        case .laundryOnArrival: "washer"
        case .motionAway: "video"
        case .energy: "bolt"
        }
    }

    /// The day's limit for `.energy`, in kWh (10 unless set).
    public static var energyLimit: Double {
        get { Preferences.object(forKey: "energyAlertKWh") as? Double ?? 10 }
        set { Preferences.set(newValue, forKey: "energyAlertKWh") }
    }

    /// Whether the owner is away: the iPhone's last crossing of home (nil where unknown, as on the Mac).
    public static var isAway: Bool? {
        get { Preferences.bool(forKey: "presenceAway") }
        set { Preferences.set(newValue, forKey: "presenceAway") }
    }

    /// What's left on, worth turning off when leaving.
    public static func leftOn(_ devices: [HomeDevice]) -> [HomeDevice] {
        devices.filter { $0.countsAsOn && [.airConditioner, .tv, .light, .gameConsole, .fan, .speaker].contains($0.kind) }
    }

    /// "Ficou ligado: Ar da sala, TV" with "Desligar tudo"; nil with nothing on.
    /// - Parameter house: with several houses, the one just left ("Ficou ligado na Praia").
    public static func forgotOnAlert(_ devices: [HomeDevice], house: String? = nil) -> HomeAlert? {
        let on = leftOn(devices)
        guard !on.isEmpty else { return nil }
        return HomeAlert(id: "watch:forgotOn" + (house.map { ":" + $0 } ?? ""),
                         title: house.map { tr("Ficou ligado: \($0)") } ?? tr("Ficou ligado"),
                         body: on.map(\.name).joined(separator: ", "),
                         urgency: .timeSensitive, action: .turnOff(on.map(\.id)))
    }

    /// The washers and dryers done and waiting (arriving home).
    public static func laundryWaitingAlert(_ devices: [HomeDevice]) -> HomeAlert? {
        let done = devices.filter { $0.kind == .laundry && HomeAlert.doneStates.contains($0.controls["runState"] ?? "") }
        guard !done.isEmpty else { return nil }
        return HomeAlert(id: "watch:laundry", title: tr("Roupa pronta"),
                         body: tr("\(done.map(\.name).joined(separator: ", ")) terminou e está esperando."), urgency: .timeSensitive)
    }
}

extension HomeStore {
    /// The alerts the owner turned on, checked after each read: a door unlocked at night, the day's energy, and
    /// movement while away (it replaces the plain movement alert).
    func watchAlerts(_ found: [HomeAlert], at date: Date? = nil) async -> [HomeAlert] {
        let watches = activeWatches()
        guard !watches.isEmpty else { return found }
        var out = found
        let now = date ?? now()
        if watches.contains(.motionAway), HomeWatch.isAway == true {
            out = out.map { alert in
                guard alert.id.hasSuffix(":motion") else { return alert }
                var away = alert
                away.id += "-away"
                away.body = tr("Movimento com a casa vazia. Toque para ver ao vivo.")
                away.urgency = .critical
                return away
            }
        }
        if watches.contains(.unlockedAtNight) {
            let hour = Calendar.current.component(.hour, from: now)
            for lock in serverDevices where lock.kind == .lock {
                guard lock.isLocked == false else { unlockedSince[lock.id] = nil; continue }
                let since = unlockedSince[lock.id] ?? now
                unlockedSince[lock.id] = since
                let key = "lock:\(lock.id):\(since.timeIntervalSince1970)"
                guard hour >= 22 || hour < 6, now.timeIntervalSince(since) >= 600, !watchFired.contains(key) else { continue }
                watchFired.insert(key)
                let name = customizations[lock.id]?.name ?? lock.name
                out.append(HomeAlert(id: "watch:unlocked:\(lock.id)", title: name,
                                     body: tr("Destrancada há \(Int(now.timeIntervalSince(since) / 60)) min."),
                                     urgency: .timeSensitive, action: lock.canLock ? .lock([lock.id]) : nil))
            }
        }
        if watches.contains(.energy) {
            let units = serverDevices.filter { $0.kind == .airConditioner }
            let day = Calendar.current.startOfDay(for: now)
            let key = "energy:\(day.timeIntervalSince1970)"
            if !units.isEmpty, !watchFired.contains(key) {
                let times = await HistoryStore.shared.onTimeToday(of: units.map(\.id), now: now)
                let kWh = times.values.reduce(0, +) / 3600 * EnergyEstimate.watts / 1000
                if kWh >= HomeWatch.energyLimit {
                    watchFired.insert(key)
                    let running = units.filter { $0.isOn == true }.map(\.id)
                    out.append(HomeAlert(id: "watch:energy", title: tr("Energia do ar hoje"),
                                         body: tr("~\(String(format: "%.1f", kWh)) kWh até agora, acima do limite de \(Int(HomeWatch.energyLimit)) kWh."),
                                         action: running.isEmpty ? nil : .warmer(running)))
                }
            }
        }
        return out
    }

    /// Carries out a notification's button: "Desligar tudo", "Trancar", "Subir 1 °C".
    public func perform(_ action: HomeAlert.Action) {
        switch action {
        case .turnOff(let ids):
            for id in ids { perform(.power(false), on: id) }
        case .lock(let ids):
            for id in ids { perform(.power(true), on: id) }
        case .warmer(let ids):
            for id in ids {
                guard let target = device(id: id)?.targetTemperature else { continue }
                perform(.temperature(target + 1), on: id)
            }
        }
    }
}

// MARK: - Suggestions

/// A ready-made routine offered by the Lar from the devices the house has (or its habits): one or two scenes, or an
/// alert to turn on. Accepted, it becomes ordinary scenes (to change or delete as any other).
public struct RoutineSuggestion: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var symbol: String
    public var scenes: [HomeScene]
    public var watch: HomeWatch?

    /// Runs on arriving or leaving: needs home marked on the iPhone (Ajustes → Casa).
    public var needsHome: Bool { scenes.contains { $0.presence != nil } || watch == .forgotOn || watch == .laundryOnArrival || watch == .motionAway }
}

/// The same device turned on at about the same time on several days: "Criar uma rotina às 19:00?".
public struct Habit: Sendable, Equatable {
    public var deviceID: String
    public var hour: Int
    public var minute: Int
    /// Only working days when every time was on one.
    public var weekdaysOnly: Bool
}

public enum RoutineSuggestions {
    /// Everything worth offering now: only with the devices it needs, never one dismissed or accepted, nor one the
    /// scenes already do.
    public static func make(devices: [HomeDevice], scenes: [HomeScene], watches: Set<HomeWatch>, dismissed: Set<String>,
                            names: [String: String] = [:], rooms: [String: String] = [:], habits: [Habit] = []) -> [RoutineSuggestion] {
        func name(_ device: HomeDevice) -> String { names[device.id] ?? device.name }
        func of(_ kinds: DeviceKind...) -> [HomeDevice] { devices.filter { kinds.contains($0.kind) && $0.isOn != nil } }
        func power(_ list: [HomeDevice], _ on: Bool) -> [HomeScene.Action] {
            list.map { HomeScene.Action(deviceID: $0.id, deviceName: name($0), command: .power(on)) }
        }
        let air = of(.airConditioner)
        let lights = of(.light)
        let screens = of(.tv, .gameConsole)
        let robots = of(.vacuum)
        let locks = devices.filter(\.canLock)
        let cameras = devices.filter { $0.kind == .camera }
        let laundry = devices.filter { $0.kind == .laundry }
        // The lights by the door or in the living room; else all of them.
        let entrance = lights.filter { light in
            let words = "\(name(light)) \(rooms[light.id] ?? "")".lowercased()
            return ["entrada", "sala", "hall", "varanda", "garagem", "living", "entry", "porch", "garage"].contains { words.contains($0) }
        }
        let dimmable = lights.filter { $0.brightness != nil }

        var out: [RoutineSuggestion] = []
        if !air.isEmpty {
            var arrive = HomeScene(name: tr("Ar ao chegar"), symbol: "snowflake",
                                   actions: power(air, true) + air.map { .init(deviceID: $0.id, deviceName: name($0), command: .temperature(23)) },
                                   presence: .arrive)
            arrive.approachDistance = 1500
            arrive.condition = SceneCondition(warmerThan: 26)
            let leave = HomeScene(name: tr("Ar ao sair"), symbol: "snowflake", actions: power(air, false), presence: .leave)
            out.append(RoutineSuggestion(id: "air-presence", title: tr("Ar ao chegar e ao sair"),
                                         detail: tr("Liga o ar a 23 °C quando você estiver a 1,5 km de casa (se estiver acima de 26 °C) e desliga ao sair."),
                                         symbol: "snowflake", scenes: [arrive, leave]))
        }
        let leaving = air + lights + screens + of(.fan)
        if leaving.count >= 2 || !locks.isEmpty || !robots.isEmpty {
            let actions = power(leaving, false) + locks.map { .init(deviceID: $0.id, deviceName: name($0), command: .power(true)) } + power(robots, true)
            out.append(RoutineSuggestion(id: "leave-home", title: tr("Sair de casa"),
                                         detail: tr("Ao sair: desliga luzes, TV, videogame e ar, tranca a porta e põe o robô para limpar."),
                                         symbol: "door.left.hand.open",
                                         scenes: [HomeScene(name: tr("Sair de casa"), symbol: "door.left.hand.open", actions: actions, presence: .leave)]))
        }
        if !robots.isEmpty {
            out.append(RoutineSuggestion(id: "robot-away", title: tr("Robô com a casa vazia"),
                                         detail: tr("O robô começa a limpar quando você sai e volta à base quando você chega."),
                                         symbol: "fan",
                                         scenes: [HomeScene(name: tr("Robô ao sair"), symbol: "figure.walk", actions: power(robots, true), presence: .leave),
                                                  HomeScene(name: tr("Robô ao chegar"), symbol: "house.fill", actions: power(robots, false), presence: .arrive)]))
        }
        if !lights.isEmpty {
            var scene = HomeScene(name: tr("Chegar à noite"), symbol: "moon.fill", actions: power(entrance.isEmpty ? lights : entrance, true), presence: .arrive)
            scene.condition = SceneCondition(atNight: true)
            out.append(RoutineSuggestion(id: "arrive-night", title: tr("Chegar à noite"),
                                         detail: tr("Acende as luzes da entrada e da sala ao chegar, só depois do pôr do sol."),
                                         symbol: "moon.fill", scenes: [scene]))
        }
        if !lights.isEmpty || !air.isEmpty {
            let actions = power(air, false) + dimmable.flatMap { light in
                [HomeScene.Action(deviceID: light.id, deviceName: name(light), command: .power(true)),
                 HomeScene.Action(deviceID: light.id, deviceName: name(light), command: .brightness(0.6))]
            }
            if !actions.isEmpty {
                out.append(RoutineSuggestion(id: "good-morning", title: tr("Bom dia"),
                                             detail: tr("Nos dias úteis às 7:00: desliga o ar e acende as luzes a 60 %."),
                                             symbol: "sun.max.fill",
                                             scenes: [HomeScene(name: tr("Bom dia"), symbol: "sun.max.fill", actions: actions,
                                                                schedule: SceneSchedule(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6]))]))
            }
        }
        if !(lights + screens).isEmpty {
            let actions = power(screens + lights, false) + locks.map { .init(deviceID: $0.id, deviceName: name($0), command: .power(true)) }
            out.append(RoutineSuggestion(id: "bedtime", title: tr("Dormir"),
                                         detail: tr("Todo dia às 23:00: desliga TV, videogame e luzes e tranca a porta."),
                                         symbol: "bed.double.fill",
                                         scenes: [HomeScene(name: tr("Dormir"), symbol: "bed.double.fill", actions: actions,
                                                            schedule: SceneSchedule(hour: 23, minute: 0))]))
        }
        if let tv = of(.tv).first, !dimmable.isEmpty {
            let actions = power([tv], true) + dimmable.flatMap { light in
                [HomeScene.Action(deviceID: light.id, deviceName: name(light), command: .power(true)),
                 HomeScene.Action(deviceID: light.id, deviceName: name(light), command: .brightness(0.2))]
            }
            out.append(RoutineSuggestion(id: "movie", title: tr("Cinema"),
                                         detail: tr("Um toque: liga a TV e deixa as luzes a 20 %."), symbol: "film",
                                         scenes: [HomeScene(name: tr("Cinema"), symbol: "film", actions: actions)]))
        }
        for habit in habits {
            guard let device = devices.first(where: { $0.id == habit.deviceID }) else { continue }
            let time = String(format: "%02d:%02d", habit.hour, habit.minute)
            let scene = HomeScene(name: tr("\(name(device)) às \(time)"), symbol: "clock", actions: power([device], true),
                                  schedule: SceneSchedule(hour: habit.hour, minute: habit.minute, weekdays: habit.weekdaysOnly ? [2, 3, 4, 5, 6] : []))
            out.append(RoutineSuggestion(id: "habit:\(habit.deviceID):\(time)", title: tr("\(name(device)) às \(time)"),
                                         detail: tr("Você costuma ligar \(name(device)) por volta das \(time). Criar uma rotina?"),
                                         symbol: "clock", scenes: [scene]))
        }
        let watchNeeds: [HomeWatch: Bool] = [.forgotOn: !leaving.isEmpty, .unlockedAtNight: devices.contains { $0.kind == .lock },
                                             .laundryOnArrival: !laundry.isEmpty, .motionAway: !cameras.isEmpty, .energy: !air.isEmpty]
        for watch in HomeWatch.allCases where watchNeeds[watch] == true && !watches.contains(watch) {
            out.append(RoutineSuggestion(id: "watch:\(watch.rawValue)", title: watch.title, detail: watch.detail, symbol: watch.symbol,
                                         scenes: [], watch: watch))
        }

        // Not one dismissed, nor one whose scenes are already there (same name, or same trigger on the same devices).
        return out.filter { suggestion in
            guard !dismissed.contains(suggestion.id) else { return false }
            return !suggestion.scenes.contains { offered in
                scenes.contains { scene in
                    scene.name.localizedCaseInsensitiveCompare(offered.name) == .orderedSame
                        || (offered.presence != nil && scene.presence == offered.presence
                            && Set(offered.actions.map(\.deviceID)).isSubset(of: Set(scene.actions.map(\.deviceID))))
                        || (offered.schedule != nil && scene.schedule.map { abs(($0.hour * 60 + $0.minute) - (offered.schedule!.hour * 60 + offered.schedule!.minute)) <= 45 } == true
                            && !Set(offered.actions.map(\.deviceID)).isDisjoint(with: Set(scene.actions.map(\.deviceID))))
                }
            }
        }
    }

    /// Habits from the history: a device switched on (off → on) within half an hour of the same time on at least 5 of
    /// the last 14 days.
    public static func habits(in samples: [HistorySample], now: Date = Date(), calendar: Calendar = .current) -> [Habit] {
        let since = now.addingTimeInterval(-14 * 86_400)
        var turnOns: [String: [Date]] = [:]
        for (id, list) in Dictionary(grouping: samples.filter { $0.date >= since }, by: \.deviceID) {
            let sorted = list.sorted { $0.date < $1.date }
            for (previous, sample) in zip(sorted, sorted.dropFirst())
            where previous.isOn == false && sample.isOn == true && sample.date.timeIntervalSince(previous.date) <= HistoryStore.longestGap {
                turnOns[id, default: []].append(sample.date)
            }
        }
        var out: [Habit] = []
        for (id, dates) in turnOns.sorted(by: { $0.key < $1.key }) {
            let minutes = dates.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
            // The time most others are close to.
            guard let center = minutes.max(by: { a, b in
                minutes.filter { abs($0 - a) <= 30 }.count < minutes.filter { abs($0 - b) <= 30 }.count
            }) else { continue }
            let close = zip(dates, minutes).filter { abs($0.1 - center) <= 30 }
            let days = Set(close.map { calendar.startOfDay(for: $0.0) })
            guard days.count >= 5 else { continue }
            let average = close.map(\.1).reduce(0, +) / close.count
            let rounded = (average + 2) / 5 * 5
            let weekdaysOnly = close.allSatisfy { !calendar.isDateInWeekend($0.0) }
            out.append(Habit(deviceID: id, hour: rounded / 60 % 24, minute: rounded % 60, weekdaysOnly: weekdaysOnly))
        }
        return out
    }
}

extension HistoryStore {
    /// The habits found in the last two weeks of this device's history.
    public func habits(now: Date = Date()) -> [Habit] {
        RoutineSuggestions.habits(in: allSamples(), now: now)
    }
}
