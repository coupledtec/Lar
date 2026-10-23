import Foundation
import Testing
@testable import LarCore

// MARK: - Tuya

@Suite struct TuyaTests {
    let credentials = TuyaClient.Credentials(clientID: "abc123client", secret: "s3cr3tkey")

    /// Vectors from the Python implementation that worked against the live API.
    @Test func signatureForTokenRequest() {
        let headers = TuyaClient.signatureHeaders(
            method: "GET", path: "/v1.0/token?grant_type=1", body: Data(), credentials: credentials,
            token: nil, timestamp: "1700000000000", nonce: "nonce-1"
        )
        #expect(headers["sign"] == "A39E7C3EC1CC35C168C6ADB0302FC26E7EC5A1470C2F6F316B4240E4419A3BCB")
        #expect(headers["access_token"] == nil)
    }

    @Test func signatureForSignedCommand() {
        let body = Data(#"{"commands":[{"code":"switch_led","value":true}]}"#.utf8)
        let headers = TuyaClient.signatureHeaders(
            method: "POST", path: "/v1.0/iot-03/devices/dev1/commands", body: body, credentials: credentials,
            token: "tok-xyz", timestamp: "1700000000000", nonce: "nonce-1"
        )
        #expect(headers["sign"] == "AF29F0AEBABA5C25D8A880F5D043223A12D2BBC9A62FAF17E8A934C23963D366")
        #expect(headers["access_token"] == "tok-xyz")
    }

    @Test func lightWithSwitch() {
        let json: JSONValue = [
            "id": "l1", "name": "Luz da Varanda", "category": "dj", "online": false,
            "status": [["code": "switch_led", "value": true], ["code": "bright_value_v2", "value": 505]],
        ]
        let device = TuyaClient.device(from: json)
        #expect(device.kind == .light)
        #expect(device.isOn == true)
        #expect(device.isOnline == false)
        #expect(device.controls["switch"] == "switch_led")
        #expect(device.id == "tuya:l1")
    }

    @Test func cameraHasNoSwitch() {
        let json: JSONValue = ["id": "c1", "name": "Portão", "category": "sp", "status": [["code": "switch", "value": true]]]
        let device = TuyaClient.device(from: json)
        #expect(device.kind == .camera)
        #expect(device.isOn == nil)
        #expect(device.hasLiveVideo)
    }

    @Test func sensorShowsTemperatureAndHumidity() {
        let json: JSONValue = [
            "id": "s1", "name": "Sala", "category": "wsdcg",
            "status": [["code": "va_temperature", "value": 236], ["code": "va_humidity", "value": 61]],
        ]
        #expect(TuyaClient.device(from: json).detail == "24° · 61%")
    }

    @Test func specFromFunctionsPrefersV2() {
        let functions: [JSONValue] = [
            ["code": "bright_value", "values": #"{"min":25,"max":255}"#],
            ["code": "bright_value_v2", "values": #"{"min":10,"max":1000,"step":1}"#],
            ["code": "colour_data_v2", "values": "{}"],
        ]
        let spec = TuyaClient.spec(fromFunctions: functions)
        #expect(spec.brightnessCode == "bright_value_v2")
        #expect(spec.brightnessRange == 10...1000)
        #expect(spec.colorCode == "colour_data_v2")
        #expect(spec.colorScale == 1000)
    }

    @Test func colorModeReadsBrightnessFromTheColor() {
        let spec = TuyaClient.spec(fromFunctions: [
            ["code": "bright_value_v2", "values": #"{"min":10,"max":1000}"#], ["code": "colour_data_v2", "values": "{}"],
        ])
        let json: JSONValue = [
            "status": [
                ["code": "work_mode", "value": "colour"], ["code": "bright_value_v2", "value": 1000],
                ["code": "colour_data_v2", "value": #"{"h":120,"s":500,"v":250}"#],
            ],
        ]
        let base = HomeDevice(provider: .tuya, rawID: "l1", name: "L", kind: .light, isOn: true)
        let device = TuyaClient.applySpec(spec, to: base, json: json)
        #expect(device.color == LightColor(hue: 120, saturation: 0.5))
        #expect(device.brightness == 0.25)
        #expect(device.controls["mode"] == "colour")
    }

    @Test func brightnessScalesToTheRange() throws {
        var device = HomeDevice(provider: .tuya, rawID: "l1", name: "L", kind: .light, isOn: true, brightness: 1)
        device.controls = ["bright": "bright_value_v2", "brightMin": "10.0", "brightMax": "1000.0", "mode": "white"]
        let commands = try TuyaClient.commands(for: .brightness(0.5), device: device)
        #expect(commands == [["code": "bright_value_v2", "value": 505]])
    }

    @Test func colorSwitchesToColorMode() throws {
        var device = HomeDevice(provider: .tuya, rawID: "l1", name: "L", kind: .light, isOn: true, brightness: 0.8,
                                color: LightColor(hue: 0, saturation: 0))
        device.controls = ["colour": "colour_data_v2", "colourScale": "1000.0"]
        let commands = try TuyaClient.commands(for: .color(LightColor(hue: 240, saturation: 1)), device: device)
        #expect(commands == [
            ["code": "work_mode", "value": "colour"],
            ["code": "colour_data_v2", "value": ["h": 240, "s": 1000, "v": 800]],
        ])
    }

    @Test func powerWithoutSwitchIsUnsupported() {
        let device = HomeDevice(provider: .tuya, rawID: "c1", name: "C", kind: .camera)
        #expect(throws: ProviderError.unsupported) { try TuyaClient.commands(for: .power(true), device: device) }
    }
}

// MARK: - SmartThings

@Suite struct SmartThingsTests {
    @Test func dimmableColorLight() throws {
        let json: JSONValue = [
            "deviceId": "st1", "label": "Abajur",
            "components": [["id": "main", "capabilities": [["id": "switch"], ["id": "switchLevel"], ["id": "colorControl"]]]],
        ]
        let device = try #require(SmartThingsClient.device(from: json))
        #expect(device.kind == .light)
        let status: JSONValue = [
            "switch": ["switch": ["value": "on"]], "switchLevel": ["level": ["value": 40]],
            "colorControl": ["hue": ["value": 50], "saturation": ["value": 100]],
        ]
        let read = SmartThingsClient.applyStatus(status, to: device)
        #expect(read.isOn == true)
        #expect(read.brightness == 0.4)
        #expect(read.color == LightColor(hue: 180, saturation: 1))
    }

    @Test func deviceWithNothingToShowIsSkipped() {
        let json: JSONValue = ["deviceId": "x", "components": [["id": "main", "capabilities": [["id": "refresh"]]]]]
        #expect(SmartThingsClient.device(from: json) == nil)
    }

    @Test func washerCycleAndOffline() throws {
        let json: JSONValue = ["deviceId": "w", "label": "Lava", "components": [["id": "main", "capabilities": [["id": "washerOperatingState"]]]]]
        let device = try #require(SmartThingsClient.device(from: json))
        let status: JSONValue = [
            "washerOperatingState": ["machineState": ["value": "run"]],
            "healthCheck": ["DeviceWatch-DeviceStatus": ["value": "offline"]],
        ]
        let read = SmartThingsClient.applyStatus(status, to: device)
        #expect(read.kind == .laundry)
        #expect(read.detail == "Funcionando")
        #expect(read.isOnline == false)
    }

    /// Off and offline are different things: a TV in standby can be switched on; one that's unreachable can't.
    @Test func switchedOffIsNotOffline() throws {
        let json: JSONValue = ["deviceId": "t", "label": "TV da Sala", "ocf": ["ocfDeviceType": "oic.d.tv"],
                               "components": [["id": "main", "capabilities": [["id": "switch"]]]]]
        let device = try #require(SmartThingsClient.device(from: json))
        let off = SmartThingsClient.applyStatus(["switch": ["switch": ["value": "off"]]], to: device)
        #expect(off.isOnline == true)
        #expect(off.canSwitch)
        #expect(SmartThingsClient.isOffline(health: ["state": "OFFLINE"]))
        #expect(!SmartThingsClient.isOffline(health: ["state": "ONLINE"]))
        #expect(!SmartThingsClient.isOffline(health: nil))
    }

    @Test func samsungTVAndSoundbarFromOCF() throws {
        let tv: JSONValue = ["deviceId": "t", "label": "TV da Sala", "ocf": ["ocfDeviceType": "oic.d.tv"],
                             "components": [["id": "main", "capabilities": [["id": "switch"], ["id": "audioVolume"]]]]]
        let bar: JSONValue = ["deviceId": "b", "label": "Soundbar", "ocf": ["ocfDeviceType": "oic.d.networkaudio"],
                              "components": [["id": "main", "capabilities": [["id": "switch"], ["id": "audioVolume"]]]]]
        #expect(try #require(SmartThingsClient.device(from: tv)).kind == .tv)
        #expect(try #require(SmartThingsClient.device(from: bar)).kind == .speaker)
    }

    @Test func levelAndColorCommands() throws {
        var device = HomeDevice(provider: .smartThings, rawID: "st1", name: "A", kind: .light)
        device.controls = ["level": "1", "color": "1"]
        #expect(try SmartThingsClient.command(for: .brightness(0.42), device: device)
            == ["component": "main", "capability": "switchLevel", "command": "setLevel", "arguments": [42]])
        #expect(try SmartThingsClient.command(for: .color(LightColor(hue: 180, saturation: 0.5)), device: device)
            == ["component": "main", "capability": "colorControl", "command": "setColor",
                "arguments": [["hue": 50, "saturation": 50]]])
    }
}

// MARK: - LG

@Suite struct LGTests {
    @Test func washerReadsTheFirstDrum() {
        let state: JSONValue = [[
            "operation": ["washerOperationMode": "POWER_ON"],
            "runState": ["currentState": "RINSING"],
            "timer": ["remainHour": 0, "remainMinute": 7],
        ]]
        let device = LGProvider.applyState(state, to: HomeDevice(provider: .lg, rawID: "w", name: "Lavadora", kind: .laundry))
        #expect(device.isOn == true)
        #expect(device.controls["operation"] == "washerOperationMode")
        #expect(device.detail == "Enxaguando · faltam 0:07")
    }

    @Test func airConditionerShowsRoomAndTarget() {
        let state: JSONValue = [
            "operation": ["airConOperationMode": "POWER_ON"],
            "temperature": ["currentTemperature": 26, "targetTemperature": 22, "unit": "C"],
            "runState": ["currentState": "NORMAL"],
        ]
        let device = LGProvider.applyState(state, to: HomeDevice(provider: .lg, rawID: "a", name: "Ar", kind: .airConditioner))
        #expect(device.detail == "Ambiente 26° · ajustado em 22°")
    }

    @Test func kinds() {
        #expect(LGProvider.kind("DEVICE_AIR_CONDITIONER") == .airConditioner)
        #expect(LGProvider.kind("DEVICE_WASHER") == .laundry)
        #expect(LGProvider.kind("DEVICE_REFRIGERATOR") == .kitchen)
        #expect(LGProvider.kind("DEVICE_AIR_PURIFIER") == .fan)
    }
}

// MARK: - Store

actor FakeProvider: DeviceProvider {
    nonisolated let provider: Provider
    var list: [HomeDevice]
    var error: ProviderError?
    private(set) var sent: [(HomeCommand, String)] = []

    init(_ provider: Provider, _ list: [HomeDevice], error: ProviderError? = nil) {
        self.provider = provider
        self.list = list
        self.error = error
    }

    func devices() async throws -> [HomeDevice] {
        if let error { throw error }
        return list
    }

    func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        sent.append((command, device.rawID))
        list = list.map { $0.id == device.id ? $0.applying(command) : $0 }
    }

    func setError(_ error: ProviderError?) { self.error = error }
    func sentCommands() -> [(HomeCommand, String)] { sent }
}

@MainActor
@Suite struct HomeStoreTests {
    let lamp = HomeDevice(provider: .tuya, rawID: "l1", name: "Lâmpada", kind: .light, isOn: false, brightness: 0.5,
                          controls: ["switch": "switch_led"])
    let ac = HomeDevice(provider: .lg, rawID: "a1", name: "Ar", kind: .airConditioner, isOn: true)

    @Test func mergesAccountsAndSortsByKind() async {
        let store = HomeStore(makeProviders: { [FakeProvider(.tuya, [self.lamp]), FakeProvider(.lg, [self.ac])] })
        await store.refresh()
        #expect(store.devices.map(\.name) == ["Ar", "Lâmpada"])
        #expect(store.accounts[.tuya] == .connected)
        #expect(store.accounts[.smartThings] == .notConfigured)
    }

    @Test func oneAccountFailingKeepsTheOther() async {
        let tuya = FakeProvider(.tuya, [lamp])
        let store = HomeStore(makeProviders: { [tuya, FakeProvider(.lg, [self.ac])] })
        await store.refresh()
        await tuya.setError(.network("sem rede"))
        await store.refresh()
        #expect(store.accounts[.tuya] == .failed("sem rede"))
        #expect(store.accounts[.lg] == .connected)
        // One failure is a hiccup: the lamp keeps its last state.
        #expect(store.device(id: "tuya:l1")?.isOnline == true)
        await store.refresh()
        await store.refresh()
        #expect(store.device(id: "tuya:l1")?.isOnline == false)
    }

    @Test func unauthorizedMarksTheAccount() async {
        let store = HomeStore(makeProviders: { [FakeProvider(.tuya, [self.lamp], error: .unauthorized)] })
        await store.refresh()
        #expect(store.accounts[.tuya] == .unauthorized)
    }

    @Test func toggleShowsAtOnceAndSends() async throws {
        let tuya = FakeProvider(.tuya, [lamp])
        let store = HomeStore(makeProviders: { [tuya] }, sleep: { _ in })
        await store.refresh()
        store.toggle("tuya:l1")
        #expect(store.device(id: "tuya:l1")?.isOn == true)
        try await waitUntil { await tuya.sentCommands().count == 1 }
        let sent = await tuya.sentCommands()
        #expect(sent.first?.0 == .power(true))
    }

    @Test func newerCommandForTheSameFieldReplacesTheUnsent() async throws {
        let tuya = FakeProvider(.tuya, [lamp])
        let store = HomeStore(makeProviders: { [tuya] }, sleep: { _ in })
        await store.refresh()
        store.perform(.brightness(0.2), on: "tuya:l1")
        store.perform(.brightness(0.3), on: "tuya:l1")
        store.perform(.brightness(0.9), on: "tuya:l1")
        #expect(store.device(id: "tuya:l1")?.brightness == 0.9)
        try await waitUntil { await !tuya.sentCommands().isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        let sent = await tuya.sentCommands().map(\.0)
        #expect(sent.last == .brightness(0.9))
        #expect(sent.count <= 2)
    }

    @Test func overrideOutlivesStaleServerStateUntilExpiry() async {
        var clock = Date(timeIntervalSince1970: 1000)
        let tuya = FakeProvider(.tuya, [lamp])
        let store = HomeStore(makeProviders: { [tuya] }, now: { clock })
        await store.refresh()
        store.perform(.power(true), on: "tuya:l1")
        await tuya.setError(nil)
        // The cloud still says off right after the command.
        await store.refresh()
        #expect(store.device(id: "tuya:l1")?.isOn == true)
        clock = clock.addingTimeInterval(HomeStore.overrideLifetime + 1)
        #expect(store.device(id: "tuya:l1")?.isOn != nil)
    }

    /// The release build once tagged the Smart Life list as LG's, and every refresh added it again on top.
    @Test func mislabeledListNeverPilesUp() async {
        // A client that says it's LG but returns Tuya devices.
        let confused = FakeProvider(.lg, [lamp])
        let store = HomeStore(makeProviders: { [confused] })
        for _ in 0..<4 { await store.refresh() }
        #expect(store.devices.map(\.id) == ["tuya:l1"])
    }

    @Test func offlineDeviceIgnoresCommands() async {
        var offline = lamp
        offline.isOnline = false
        let tuya = FakeProvider(.tuya, [offline])
        let store = HomeStore(makeProviders: { [tuya] })
        await store.refresh()
        store.toggle("tuya:l1")
        #expect(store.device(id: "tuya:l1")?.isOn == false)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }
}

@MainActor
@Suite struct WatchPayloadTests {
    @Test func roundTripAndApplyNeverCarriesTheRefreshToken() throws {
        let phone = InMemorySettings(token: "lg-token")
        phone.tuya = TuyaClient.Credentials(clientID: "id", secret: "sec", region: "us")
        phone.smartThings = .oauth(clientID: "c", secret: "s", refreshToken: "REFRESH")
        let payload = WatchPayload.from(phone, smartThingsAccessToken: "ACCESS", now: Date(timeIntervalSince1970: 0))
        let data = try payload.encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("REFRESH"))
        let watch = InMemorySettings()
        try WatchPayload.decoded(data).apply(to: watch)
        #expect(watch.token == "lg-token")
        #expect(watch.tuya?.secret == "sec")
        #expect(watch.smartThings == .personalToken("ACCESS"))
    }
}

@MainActor
@Suite struct AccountsImportTests {
    @Test func importsAndDeletesTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let accounts = AccountsImport(lgToken: "lg", tuya: .init(clientID: "id", secret: "sec", region: "us"),
                                      smartThings: .init(clientID: "c", secret: "s", refreshToken: "r"), temperatureLimits: nil)
        try JSONEncoder().encode(accounts).write(to: folder.appendingPathComponent(AccountsImport.fileName))
        let settings = InMemorySettings()
        #expect(AccountsImport.importIfPresent(in: folder, into: settings))
        #expect(settings.token == "lg")
        #expect(settings.tuya?.secret == "sec")
        #expect(settings.smartThings == .oauth(clientID: "c", secret: "s", refreshToken: "r"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(AccountsImport.fileName).path))
        #expect(!AccountsImport.importIfPresent(in: folder, into: settings))
    }
}
