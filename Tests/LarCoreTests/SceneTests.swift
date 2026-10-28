import Foundation
import Testing
@testable import LarCore

@MainActor
@Suite struct SceneTests {
    static let light = HomeDevice(provider: .tuya, rawID: "l1", name: "Luz da sala", kind: .light, isOn: false, brightness: 0.4)
    static let tv = HomeDevice(provider: .androidTV, rawID: "tv", name: "TV da Sala", kind: .tv, isOn: true)
    static let camera = HomeDevice(provider: .tuya, rawID: "c1", name: "Câmera", kind: .camera)

    @Test func runSwitchesTheDevicesAndNamesTheMissingOnes() {
        let home = HomeStore(previewDevices: [Self.light, Self.tv])
        let scene = HomeScene(name: "Dormir", actions: [
            .init(deviceID: Self.tv.id, deviceName: "TV da Sala", command: .power(false)),
            .init(deviceID: Self.light.id, deviceName: "Luz da sala", command: .power(true)),
            .init(deviceID: Self.light.id, deviceName: "Luz da sala", command: .brightness(0.2)),
            .init(deviceID: "tuya:gone", deviceName: "Abajur", command: .power(false)),
        ])
        #expect(home.run(scene) == "Dormir: Abajur fora do ar")
        #expect(home.device(id: Self.tv.id)?.isOn == false)
        #expect(home.device(id: Self.light.id)?.isOn == true)
        #expect(home.device(id: Self.light.id)?.brightness == 0.2)
    }

    @Test func actionsFromTheCurrentState() {
        let on = HomeScene.actions(for: Self.light, on: true)
        #expect(on.map(\.command) == [.power(true), .brightness(0.4)])
        #expect(HomeScene.actions(for: Self.light, on: false).map(\.command) == [.power(false)])
        #expect(HomeScene.candidates([Self.light, Self.tv, Self.camera]).map(\.rawID) == ["l1", "tv"])
        let scene = HomeScene(name: "x", actions: on)
        #expect(scene.power(of: Self.light.id) == true)
        #expect(scene.power(of: Self.tv.id) == nil)
    }

    @Test func storeSavesAndGoesToTheWatch() throws {
        let settings = InMemorySettings()
        let store = SceneStore(settings: settings)
        var scene = HomeScene(name: "Cinema", symbol: "film", actions: HomeScene.actions(for: Self.tv, on: true))
        store.save(scene)
        scene.name = "Filme"
        store.save(scene)
        #expect(settings.scenes.map(\.name) == ["Filme"])

        let payload = WatchPayload.from(settings, smartThingsAccessToken: nil)
        let watch = InMemorySettings()
        try WatchPayload.decoded(payload.encoded()).apply(to: watch)
        #expect(watch.scenes == [scene])

        store.delete(scene.id)
        #expect(settings.scenes.isEmpty)
    }
}

@MainActor
@Suite struct SceneDraftTests {
    @Test func newSceneFromTheCurrentState() {
        var draft = SceneDraft()
        draft.name = " Sala "
        #expect(!draft.canSave)
        draft.useCurrentState(of: [SceneTests.light, SceneTests.tv, SceneTests.camera])
        #expect(draft.canSave)
        let scene = draft.build(with: [SceneTests.light, SceneTests.tv])
        #expect(scene.name == "Sala")
        #expect(scene.power(of: SceneTests.tv.id) == true)
        #expect(scene.power(of: SceneTests.light.id) == false)
    }

    @Test func editingKeepsBrightnessAndDevicesGone() {
        let original = HomeScene(name: "Noite", actions: [
            .init(deviceID: SceneTests.light.id, deviceName: "Luz da sala", command: .power(true)),
            .init(deviceID: SceneTests.light.id, deviceName: "Luz da sala", command: .brightness(0.1)),
            .init(deviceID: "tuya:gone", deviceName: "Abajur", command: .power(false)),
        ])
        var draft = SceneDraft(editing: original)
        #expect(draft.rows([SceneTests.light, SceneTests.tv]).map(\.name) == ["Luz da sala", "TV da Sala", "Abajur"])
        draft.choices[SceneTests.tv.id] = false
        let scene = draft.build(with: [SceneTests.light, SceneTests.tv])
        #expect(scene.id == original.id)
        #expect(scene.actions.contains { $0.command == .brightness(0.1) })
        #expect(scene.power(of: "tuya:gone") == false)
        #expect(scene.power(of: SceneTests.tv.id) == false)
        draft.choices[SceneTests.light.id] = nil
        #expect(draft.build(with: [SceneTests.light]).power(of: SceneTests.light.id) == nil)
    }
}

@MainActor
@Suite struct LarLinkTests {
    @Test func parsesTheLinks() throws {
        #expect(LarLink(try #require(URL(string: "lar://cena/Dormir"))) == .scene("Dormir"))
        #expect(LarLink(try #require(URL(string: "lar://porteiro"))) == .call(nil))
        #expect(LarLink(try #require(URL(string: "lar://discar/*43"))) == .call("*43"))
        #expect(LarLink(try #require(URL(string: "lar://encerrar"))) == .hangUp)
        #expect(LarLink.url(.call("*43"))?.absoluteString == "lar://discar/*43")
        #expect(LarLink(try #require(URL(string: "lar://ligar/TV%20da%20Sala"))) == .power(device: "TV da Sala", on: true))
        #expect(LarLink(try #require(URL(string: "LAR://Desligar/Luz"))) == .power(device: "Luz", on: false))
        #expect(LarLink(try #require(URL(string: "lar://alternar/Abajur"))) == .power(device: "Abajur", on: nil))
        #expect(LarLink(try #require(URL(string: "lar://cena/"))) == nil)
        #expect(LarLink(try #require(URL(string: "http://cena/Dormir"))) == nil)
        #expect(LarLink(try #require(URL(string: "lar://temperatura/Ar%20do%20quarto/23.5"))) == .temperature(device: "Ar do quarto", value: 23.5))
        #expect(LarLink(try #require(URL(string: "lar://temperatura/Ar"))) == nil)
        #expect(LarLink(try #require(LarLink.url(.temperature(device: "Ar", value: 22)))) == .temperature(device: "Ar", value: 22))
        let made = try #require(LarLink.url(.scene("Sala de jantar")))
        #expect(LarLink(made) == .scene("Sala de jantar"))
    }

    @Test func runsByNameIgnoringCaseAndAccents() {
        let home = HomeStore(previewDevices: [SceneTests.light, SceneTests.tv])
        let scene = HomeScene(name: "Cinema", actions: [.init(deviceID: SceneTests.tv.id, deviceName: "TV da Sala", command: .power(false))])
        #expect(home.open(.scene("cinemá"), scenes: [scene]) == nil)
        #expect(home.device(id: SceneTests.tv.id)?.isOn == false)
        #expect(home.open(.power(device: "luz da SALA", on: nil), scenes: []) == nil)
        #expect(home.device(id: SceneTests.light.id)?.isOn == true)
        #expect(home.open(.scene("Nada"), scenes: [scene]) == "Cena “Nada” não encontrada")
    }
}

@MainActor
@Suite struct SceneTemperatureTests {
    static let ac: HomeDevice = {
        var device = HomeDevice(provider: .lg, rawID: "ac", name: "Ar", kind: .airConditioner, isOn: false)
        device.controls["targetTemperature"] = "22"
        return device
    }()

    @Test func sceneSetsTheTargetAfterSwitchingOn() {
        var draft = SceneDraft()
        draft.name = "Dormir"
        draft.choices[Self.ac.id] = true
        draft.temperatures[Self.ac.id] = 24
        let scene = draft.build(with: [Self.ac])
        #expect(scene.actions.map(\.command) == [.power(true), .temperature(24)])
        #expect(scene.temperature(of: Self.ac.id) == 24)

        var edit = SceneDraft(editing: scene)
        #expect(edit.temperatures[Self.ac.id] == 24)
        edit.temperatures[Self.ac.id] = 25
        #expect(edit.build(with: [Self.ac]).actions.map(\.command) == [.power(true), .temperature(25)])
        edit.choices[Self.ac.id] = false
        #expect(edit.build(with: [Self.ac]).actions.map(\.command) == [.power(false)])

        let home = HomeStore(previewDevices: [Self.ac])
        home.run(scene)
        #expect(home.device(id: Self.ac.id)?.targetTemperature == 24)
        #expect(home.device(id: Self.ac.id)?.isOn == true)
    }
}

@Suite struct AutomationTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func dueOnceInTheWindowAndOnTheRightDays() {
        // 23 Oct 2026 is a Friday (weekday 6).
        let night = HomeScene(name: "Dormir", actions: [], schedule: SceneSchedule(hour: 23, minute: 0))
        let weekend = HomeScene(name: "Sábado", actions: [], schedule: SceneSchedule(hour: 23, minute: 0, weekdays: [1, 7]))
        let scenes = [night, weekend, HomeScene(name: "Manual", actions: [])]
        #expect(HomeScene.due(scenes, after: Self.date(23, 22, 59, 40), through: Self.date(23, 23, 0, 10), calendar: Self.calendar).map(\.name) == ["Dormir"])
        #expect(HomeScene.due(scenes, after: Self.date(23, 23, 0, 10), through: Self.date(23, 23, 0, 40), calendar: Self.calendar).isEmpty)
        #expect(HomeScene.due(scenes, after: Self.date(24, 22, 59, 40), through: Self.date(24, 23, 0, 10), calendar: Self.calendar).map(\.name)
                == ["Dormir", "Sábado"])
        // A Mac asleep from 20:00 to 23:30 doesn't run a 23:00 scene half an hour late.
        #expect(HomeScene.due(scenes, after: Self.date(23, 20, 0), through: Self.date(23, 23, 30), calendar: Self.calendar).isEmpty)
    }

    @Test func scheduleText() {
        #expect(SceneSchedule(hour: 7, minute: 5).text == "Todo dia às 07:05")
        #expect(SceneSchedule(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6]).text == "Dias úteis às 07:00")
        #expect(SceneSchedule(hour: 9, minute: 30, weekdays: [2, 4]).text == "seg, qua às 09:30")
    }

    @MainActor
    @Test func offTimerTurnsOff() async throws {
        let home = HomeStore(previewDevices: [SceneTests.tv])
        home.setOffTimer(SceneTests.tv.id, after: 0.1)
        #expect(home.offTimerText(SceneTests.tv.id) == "desliga em 1 min")
        try await Task.sleep(for: .milliseconds(400))
        #expect(home.device(id: SceneTests.tv.id)?.isOn == false)
        #expect(home.offTimers.isEmpty)
    }
}
