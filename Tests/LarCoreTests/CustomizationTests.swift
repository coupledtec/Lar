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

@MainActor
@Suite struct DiagnosticsTests {
    @Test func reportHasNoNamesNorKeys() {
        let home = HomeStore(previewDevices: CustomizationTests.devices, accounts: [.lg: .connected, .tuya: .unauthorized])
        let report = home.diagnosticsReport(app: "iPhone", version: "1.0", pairedTVs: 1, sharedKeychain: true)
        #expect(report.contains("LG ThinQ: conectada"))
        #expect(report.contains("Smart Life: chave recusada"))
        #expect(report.contains("TVs pareadas: 1"))
        #expect(!report.contains("Tomada"))
        #expect(!report.contains("Luz da sala"))
    }
}

@Suite struct HistoryTests {
    @Test func recordsThrottledAndCountsOnTime() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lar-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = HistoryStore(file: file)
        var ac = HomeDevice(provider: .lg, rawID: "ac", name: "Ar", kind: .airConditioner, isOn: true)
        ac.controls["roomTemperatureValue"] = "26"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record([ac], at: start)
        await store.record([ac], at: start.addingTimeInterval(60))  // too soon: skipped
        await store.record([ac], at: start.addingTimeInterval(600))
        ac.isOn = false
        await store.record([ac], at: start.addingTimeInterval(1200))
        let samples = await store.samples(of: ac.id, since: start)
        #expect(samples.count == 3)
        #expect(samples.first?.room == 26)
        #expect(HistoryStore.onTime(samples, from: start, to: start.addingTimeInterval(3600)) == 1200)
        // Read back from the file by a fresh store.
        #expect(await HistoryStore(file: file).samples(of: ac.id, since: start).count == 3)
    }

    @Test func gapsArentCountedAsOn() {
        let start = Date(timeIntervalSince1970: 0)
        let samples = [HistorySample(date: start, deviceID: "a", isOn: true),
                       HistorySample(date: start.addingTimeInterval(7200), deviceID: "a", isOn: false)]
        #expect(HistoryStore.onTime(samples, from: start, to: start.addingTimeInterval(7200)) == 900)
    }

    @Test func energyText() {
        #expect(EnergyEstimate.text(running: 12_000, watts: 1000, tariff: 0.85, locale: Locale(identifier: "pt_BR"))
                == "3 h 20 min · ~3,3 kWh · ~R$\u{00A0}2,83")
        #expect(EnergyEstimate.text(running: 12_000, watts: 1000, tariff: 0.15, locale: Locale(identifier: "en_US"))
                == "3 h 20 min · ~3.3 kWh · ~$0.50")
        // No tariff set: no cost.
        #expect(EnergyEstimate.text(running: 600, watts: 1000, tariff: 0, locale: Locale(identifier: "de_DE")) == "10 min · ~0,2 kWh")
    }
}
