import Foundation
@testable import LarCore
import Testing

struct RoutineTests {
    static let air = HomeDevice(provider: .lg, rawID: "ac", name: "Ar da sala", kind: .airConditioner, isOn: false,
                                controls: ["roomTemperatureValue": "28", "targetTemperature": "24"])
    static let light = HomeDevice(provider: .tuya, rawID: "l1", name: "Luz da sala", kind: .light, isOn: false, brightness: 0.5)
    static let porch = HomeDevice(provider: .tuya, rawID: "l2", name: "Luz do quarto", kind: .light, isOn: true)
    static let tv = HomeDevice(provider: .androidTV, rawID: "tv", name: "TV", kind: .tv, isOn: true)
    static let robot = HomeDevice(provider: .tuya, rawID: "r1", name: "Robô", kind: .vacuum, isOn: false)
    static let washer = HomeDevice(provider: .lg, rawID: "w1", name: "Lavadora", kind: .laundry, controls: ["runState": "END"])
    static let saoPaulo = Coordinate(latitude: -23.55, longitude: -46.63)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func nightAtHomeFollowsTheSun() {
        // São Paulo in November: sunrise about 5:15, sunset about 18:35.
        #expect(!SolarTime.isDark(at: Self.date(19, 12), home: Self.saoPaulo))
        #expect(!SolarTime.isDark(at: Self.date(19, 18, 15), home: Self.saoPaulo))
        #expect(SolarTime.isDark(at: Self.date(19, 19, 10), home: Self.saoPaulo))
        #expect(SolarTime.isDark(at: Self.date(19, 23), home: Self.saoPaulo))
        #expect(SolarTime.isDark(at: Self.date(20, 4, 30), home: Self.saoPaulo))
        #expect(!SolarTime.isDark(at: Self.date(20, 6), home: Self.saoPaulo))
        // Tokyo (east of Greenwich, the sunset on the UTC day before): 22:00 there is dark, noon isn't.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let home = Coordinate(latitude: 35.68, longitude: 139.69)
        #expect(SolarTime.isDark(at: tokyo.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 22))!, home: home))
        #expect(!SolarTime.isDark(at: tokyo.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!, home: home))
        // Without home's spot: 18:00 to 6:00.
        #expect(SolarTime.isDark(at: Self.date(19, 18, 30), home: nil, calendar: Self.calendar))
        #expect(!SolarTime.isDark(at: Self.date(19, 17, 30), home: nil, calendar: Self.calendar))
    }

    @Test func conditionsHoldTheSceneBack() {
        let hot = SceneCondition(warmerThan: 26)
        #expect(hot.holds(devices: [Self.air]))
        var cool = Self.air
        cool.controls["roomTemperatureValue"] = "24"
        #expect(!hot.holds(devices: [cool]))
        // Nothing reads the temperature: it runs.
        #expect(hot.holds(devices: [Self.light]))
        let night = SceneCondition(atNight: true)
        #expect(night.holds(devices: [], now: Self.date(19, 22), home: Self.saoPaulo))
        #expect(!night.holds(devices: [], now: Self.date(19, 14), home: Self.saoPaulo))
        #expect(SceneCondition().isEmpty)
        #expect(SceneCondition(warmerThan: 26, atNight: true).text == "só acima de 26 °C · só à noite")
    }

    @Test func draftKeepsApproachAndCondition() {
        var scene = HomeScene(name: "Ar ao chegar", actions: [.init(deviceID: Self.air.id, deviceName: "Ar", command: .power(true))],
                              presence: .arrive)
        scene.approachDistance = 1500
        scene.condition = SceneCondition(warmerThan: 26)
        let built = SceneDraft(editing: scene).build(with: [Self.air])
        #expect(built.approachDistance == 1500)
        #expect(built.condition == SceneCondition(warmerThan: 26))
        #expect(built.triggerText == "Chegando (a 1,5 km) · só acima de 26 °C")
        // Leaving has no "Chegando"; an empty condition goes away.
        var draft = SceneDraft(editing: built)
        draft.presence = .leave
        draft.condition = SceneCondition()
        let leaving = draft.build(with: [Self.air])
        #expect(leaving.approachDistance == nil)
        #expect(leaving.condition == nil)
    }

    @Test func olderAppsReadTheNewScenes() throws {
        var scene = HomeScene(name: "Ar ao chegar", actions: [], presence: .arrive)
        scene.approachDistance = 1500
        scene.condition = SceneCondition(atNight: true)
        let data = try JSONEncoder().encode([scene])
        let back = try JSONDecoder().decode([HomeScene].self, from: data)
        #expect(back == [scene])
        // A scene saved before has neither.
        let old = #"[{"id":"\#(UUID().uuidString)","name":"Dormir","symbol":"moon.fill","actions":[]}]"#
        let decoded = try JSONDecoder().decode([HomeScene].self, from: Data(old.utf8))
        #expect(decoded.first?.approachDistance == nil && decoded.first?.condition == nil)
    }

    @Test func suggestionsFollowTheDevices() {
        let all = RoutineSuggestions.make(devices: [Self.air, Self.light, Self.porch, Self.tv, Self.robot, Self.washer],
                                          scenes: [], watches: [], dismissed: [])
        let ids = all.map(\.id)
        #expect(ids.contains("air-presence"))
        #expect(ids.contains("leave-home"))
        #expect(ids.contains("robot-away"))
        #expect(ids.contains("arrive-night"))
        #expect(ids.contains("movie"))
        #expect(ids.contains("watch:laundryOnArrival"))
        // No lock, no camera: no alert about them.
        #expect(!ids.contains("watch:unlockedAtNight"))
        #expect(!ids.contains("watch:motionAway"))
        let air = all.first { $0.id == "air-presence" }!
        #expect(air.scenes.count == 2)
        #expect(air.scenes[0].approachDistance == 1500 && air.scenes[0].condition?.warmerThan == 26)
        #expect(air.scenes[0].actions.contains { $0.command == .temperature(23) })
        #expect(air.scenes[1].presence == .leave && air.scenes[1].power(of: Self.air.id) == false)
        #expect(air.needsHome)
        // The living room's light by the door, not the bedroom's.
        let night = all.first { $0.id == "arrive-night" }!
        #expect(night.scenes[0].power(of: Self.light.id) == true && night.scenes[0].power(of: Self.porch.id) == nil)

        // Only an air conditioner: nothing about lights or the robot.
        let few = RoutineSuggestions.make(devices: [Self.air], scenes: [], watches: [], dismissed: []).map(\.id)
        #expect(few.contains("air-presence") && !few.contains("robot-away") && !few.contains("arrive-night") && !few.contains("movie"))
    }

    @Test func suggestionsAlreadyDealtWithGoAway() {
        let devices = [Self.air, Self.light, Self.tv]
        // Dismissed, accepted (the alert on), or a scene that already does it.
        let ids = RoutineSuggestions.make(devices: devices, scenes: [], watches: [.energy], dismissed: ["movie"]).map(\.id)
        #expect(!ids.contains("movie") && !ids.contains("watch:energy"))
        let existing = HomeScene(name: "Chegada", actions: [.init(deviceID: Self.air.id, deviceName: "Ar", command: .power(true))], presence: .arrive)
        let withScene = RoutineSuggestions.make(devices: devices, scenes: [existing], watches: [], dismissed: []).map(\.id)
        #expect(!withScene.contains("air-presence"))
        let named = HomeScene(name: "dormir", actions: [], schedule: SceneSchedule(hour: 22, minute: 0))
        #expect(!RoutineSuggestions.make(devices: devices, scenes: [named], watches: [], dismissed: []).map(\.id).contains("bedtime"))
    }

    @MainActor
    @Test func acceptingMakesTheScenesAndRemembers() {
        let settings = InMemorySettings()
        let store = SceneStore(settings: settings)
        let suggestions = RoutineSuggestions.make(devices: [Self.air, Self.light], scenes: [], watches: [], dismissed: [])
        store.accept(suggestions.first { $0.id == "air-presence" }!)
        store.accept(suggestions.first { $0.id == "watch:energy" }!)
        store.dismiss(suggestions.first { $0.id == "good-morning" }!)
        #expect(store.scenes.map(\.name) == ["Ar ao chegar", "Ar ao sair"])
        #expect(store.watches == [.energy])
        #expect(Set(settings.dismissedSuggestions) == ["air-presence", "watch:energy", "good-morning"])
        let left = RoutineSuggestions.make(devices: [Self.air, Self.light], scenes: store.scenes, watches: store.watches,
                                           dismissed: store.dismissedSuggestions).map(\.id)
        #expect(!left.contains("air-presence") && !left.contains("watch:energy") && !left.contains("good-morning"))
        store.setWatch(.energy, on: false)
        #expect(settings.watches.isEmpty)
    }

    @Test func syncCarriesWatchesAndKeepsThemFromOlderSides() {
        let settings = InMemorySettings()
        settings.watches = ["energy"]
        settings.dismissedSuggestions = ["movie"]
        let local = SyncState.capture(settings)
        // An older Mac sends no watches: same state, nothing to copy, and applying it leaves ours.
        var older = local
        older.watches = nil
        older.dismissedSuggestions = nil
        #expect(SyncState.direction(local: local, remote: older) == nil)
        older.apply(to: settings)
        #expect(settings.watches == ["energy"] && settings.dismissedSuggestions == ["movie"])
        var newer = local
        newer.watches = ["energy", "forgotOn"]
        newer.updatedAt = local.updatedAt.addingTimeInterval(60)
        #expect(SyncState.direction(local: local, remote: newer) == .pull)
    }

    @Test func habitsFromTheHistory() {
        // The TV on at about 19:00 on six weekdays, and once at 9:00 on a Saturday.
        var samples: [HistorySample] = []
        for day in [9, 10, 11, 12, 13, 16] {
            let minute = [55, 0, 5, 10, 58, 2][[9, 10, 11, 12, 13, 16].firstIndex(of: day)!]
            let on = Self.date(day, minute > 30 ? 18 : 19, minute)
            samples.append(HistorySample(date: on.addingTimeInterval(-300), deviceID: Self.tv.id, isOn: false))
            samples.append(HistorySample(date: on, deviceID: Self.tv.id, isOn: true))
        }
        samples.append(HistorySample(date: Self.date(14, 8, 55), deviceID: Self.tv.id, isOn: false))
        samples.append(HistorySample(date: Self.date(14, 9), deviceID: Self.tv.id, isOn: true))
        let habits = RoutineSuggestions.habits(in: samples, now: Self.date(19, 12), calendar: Self.calendar)
        #expect(habits == [Habit(deviceID: Self.tv.id, hour: 19, minute: 0, weekdaysOnly: true)])
        // Fewer than five days isn't a habit.
        #expect(RoutineSuggestions.habits(in: Array(samples.prefix(8)), now: Self.date(19, 12), calendar: Self.calendar).isEmpty)
        let suggestion = RoutineSuggestions.make(devices: [Self.tv], scenes: [], watches: [], dismissed: [], habits: habits)
            .first { $0.id.hasPrefix("habit:") }
        #expect(suggestion?.scenes.first?.schedule == SceneSchedule(hour: 19, minute: 0, weekdays: [2, 3, 4, 5, 6]))
    }

    @Test func forgottenAndWaitingAlerts() {
        let alert = HomeWatch.forgotOnAlert([Self.air, Self.porch, Self.tv, Self.washer])
        #expect(alert?.body == "Luz do quarto, TV")
        #expect(alert?.action == .turnOff([Self.porch.id, Self.tv.id]))
        #expect(HomeWatch.forgotOnAlert([Self.air]) == nil)
        #expect(HomeWatch.laundryWaitingAlert([Self.washer])?.body == "Lavadora terminou e está esperando.")
    }

    @MainActor
    @Test func unlockedDoorAtNight() async {
        var door = HomeDevice(provider: .tuya, rawID: "d1", name: "Porta", kind: .lock, isOn: false,
                              controls: ["locked": "0", "lockable": "1"])
        door.isOn = false
        let home = HomeStore(previewDevices: [door])
        home.activeWatches = { [.unlockedAtNight] }
        #expect(await home.watchAlerts([], at: Self.date(19, 23)).isEmpty)
        let alerts = await home.watchAlerts([], at: Self.date(19, 23, 11))
        #expect(alerts.map(\.action) == [.lock([door.id])])
        // Once per time it was left unlocked.
        #expect(await home.watchAlerts([], at: Self.date(19, 23, 20)).isEmpty)
    }

    @MainActor
    @Test func notificationButtonsActOnTheDevices() {
        let home = HomeStore(previewDevices: [Self.tv, Self.air])
        home.perform(HomeAlert.Action.turnOff([Self.tv.id]))
        #expect(home.device(id: Self.tv.id)?.isOn == false)
    }
}

@MainActor
struct ReviewPromptTests {
    static let keys = ["reviewOpens", "reviewCommands", "reviewAsks", "reviewRated"]

    @Test func threeAsksEachNeedingMoreUse() {
        for key in Self.keys { Preferences.set(nil, forKey: key) }
        let prompt = ReviewPrompt()
        // 1: the second opening.
        prompt.noteOpen()
        #expect(!prompt.isDue)
        prompt.noteOpen()
        #expect(prompt.isDue)
        prompt.asked()
        // 2: more than 4 openings and 2 commands since.
        prompt.noteOpen(); prompt.noteOpen(); prompt.noteOpen()
        prompt.noteSuccess()
        #expect(!prompt.isDue)
        prompt.noteSuccess()
        #expect(prompt.isDue)
        prompt.asked()
        // 3: more than 10 openings and 3 commands; not right after a failure.
        for _ in 0..<6 { prompt.noteOpen() }
        prompt.noteSuccess(); prompt.noteSuccess()
        #expect(!prompt.isDue)
        prompt.noteSuccess()
        #expect(prompt.isDue)
        prompt.noteFailure()
        #expect(!prompt.isDue)
        prompt.noteSuccess()
        #expect(prompt.isDue)
        prompt.asked()
        // Never a fourth.
        for _ in 0..<20 { prompt.noteOpen(); prompt.noteSuccess() }
        #expect(!prompt.isDue)
        for key in Self.keys { Preferences.set(nil, forKey: key) }
    }

    @Test func ratedNeverAgain() {
        for key in Self.keys { Preferences.set(nil, forKey: key) }
        let prompt = ReviewPrompt()
        prompt.noteOpen(); prompt.noteOpen()
        #expect(prompt.isDue)
        prompt.rated()
        for _ in 0..<20 { prompt.noteOpen(); prompt.noteSuccess() }
        #expect(!prompt.isDue)
        for key in Self.keys { Preferences.set(nil, forKey: key) }
    }
}
