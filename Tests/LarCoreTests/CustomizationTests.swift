import Foundation
import Testing
@testable import LarCore

@MainActor
@Suite struct CustomizationTests {
    static let devices = [
        SceneTests.light, SceneTests.tv,
        HomeDevice(provider: .tuya, rawID: "p1", name: "Tomada", kind: .plug, isOn: false),
        HomeDevice(provider: .lg, rawID: "ac", name: "Ar", kind: .airConditioner, isOn: true),
    ]

    @Test func favoritesFirstThenKindsWithoutHidden() {
        let home = HomeStore(previewDevices: Self.devices)
        home.customize("tuya:p1") { $0.isFavorite = true; $0.name = "Cafeteira" }
        home.customize("lg:ac") { $0.isHidden = true }
        let sections = home.sections(grouping: .kind)
        #expect(sections.map(\.title) == ["Favoritos", "TVs", "Luzes"])
        #expect(sections[0].devices.map(\.name) == ["Cafeteira"])
        #expect(home.device(id: "tuya:p1")?.name == "Cafeteira")
        #expect(home.hiddenDevices.map(\.rawID) == ["ac"])
        #expect(home.sections(grouping: .kind, includeHidden: true).flatMap(\.devices).count == 4)
    }

    @Test func byRoomWithTheRestLast() {
        let home = HomeStore(previewDevices: Self.devices)
        #expect(home.sections(grouping: .room).map(\.title) == ["Aparelhos"])
        home.customize(SceneTests.tv.id) { $0.room = " Quarto " }
        home.customize(SceneTests.light.id) { $0.room = "Sala" }
        home.customize("lg:ac") { $0.room = "Quarto" }
        #expect(home.sections(grouping: .room).map(\.title) == ["Quarto", "Sala", "Sem cômodo"])
        #expect(home.rooms == ["Quarto", "Sala"])
    }

    @Test func emptyCustomizationIsRemovedAndSaved() throws {
        let home = HomeStore(previewDevices: Self.devices)
        let settings = InMemorySettings()
        var saves = 0
        settings.bindListPreferences(to: home) { saves += 1 }
        home.customize(SceneTests.tv.id) { $0.name = "  " ; $0.isFavorite = true }
        #expect(settings.customizations[SceneTests.tv.id] == DeviceCustomization(isFavorite: true))
        home.customize(SceneTests.tv.id) { $0.isFavorite = false }
        #expect(settings.customizations.isEmpty)
        home.grouping = .room
        #expect(settings.grouping == .room)
        #expect(saves == 3)

        home.customize(SceneTests.tv.id) { $0.room = "Quarto" }
        let watch = InMemorySettings()
        try WatchPayload.decoded(WatchPayload.from(settings, smartThingsAccessToken: nil).encoded()).apply(to: watch)
        #expect(watch.customizations[SceneTests.tv.id]?.room == "Quarto")
        #expect(watch.grouping == .room)
    }
}

@Suite struct HomeAlertTests {
    static func washer(_ state: String?) -> HomeDevice {
        var device = HomeDevice(provider: .lg, rawID: "w", name: "Lavadora", kind: .laundry, isOn: true)
        device.controls["runState"] = state
        return device
    }

    @Test func runningThenEndIsAnAlert() {
        #expect(HomeAlert.alerts(from: [Self.washer("RINSING")], to: [Self.washer("END")]).map(\.body) == ["O ciclo terminou."])
        #expect(HomeAlert.alerts(from: [Self.washer("END")], to: [Self.washer("END")]).isEmpty)
        #expect(HomeAlert.alerts(from: [Self.washer("PAUSE")], to: [Self.washer("END")]).isEmpty)
        #expect(HomeAlert.alerts(from: [Self.washer(nil)], to: [Self.washer("END")]).isEmpty)
        #expect(HomeAlert.alerts(from: [], to: [Self.washer("END")]).isEmpty)
        #expect(HomeAlert.alerts(from: [Self.washer("RUNNING")], to: [Self.washer("POWER_OFF")]).isEmpty)
    }
}
