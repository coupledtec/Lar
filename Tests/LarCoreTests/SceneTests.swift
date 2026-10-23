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
