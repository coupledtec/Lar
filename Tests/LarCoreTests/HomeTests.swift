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

    /// The project without the video service: the camera says what to turn on in Tuya's site.
    @Test func cameraWithoutVideoServiceSaysWhatToDo() async {
        let client = TuyaClient(credentials: TuyaClient.Credentials(clientID: "id", secret: "secret"), transport: { request in
            let body = request.url!.path.contains("token")
                ? #"{"success":true,"result":{"access_token":"t","expire_time":7200}}"#
                : #"{"success":false,"code":28841101,"msg":"No permissions. This API is not subscribed."}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let camera = HomeDevice(provider: .tuya, rawID: "c1", name: "Portão", kind: .camera)
        await #expect(throws: ProviderError.api(TuyaClient.videoServiceMessage)) { _ = try await client.liveStreamURL(for: camera) }
    }

    /// A Smart Life robot vacuum: cleaning from power_go, the status and battery in the line; off docks it.
    @Test func robotVacuumCleansAndDocks() throws {
        let json: JSONValue = [
            "id": "r1", "name": "Robô", "category": "sd",
            "status": [["code": "power_go", "value": true], ["code": "status", "value": "smart_clean"],
                       ["code": "electricity_left", "value": 72], ["code": "switch_charge", "value": false]],
        ]
        let device = TuyaClient.device(from: json)
        #expect(device.kind == .vacuum)
        #expect(device.isOn == true)
        #expect(device.detail == "Limpando · bateria 72%")
        #expect(device.controls["tuyaStatus"]?.contains("status=smart_clean") == true)
        let dock = try TuyaClient.commands(for: .power(false), device: device)
        #expect(dock == [["code": "switch_charge", "value": true]])
        let start = try TuyaClient.commands(for: .power(true), device: device)
        #expect(start == [["code": "power_go", "value": true]])
    }

    /// A Smart Life lock: the door and battery, no switch; a video lock opens the live camera.
    @Test func lockShowsDoorAndBattery() {
        let json: JSONValue = [
            "id": "k1", "name": "Porta", "category": "videolock",
            "status": [["code": "closed_opened", "value": "closed"], ["code": "residual_electricity", "value": 88],
                       ["code": "lock_motor_state", "value": false]],
        ]
        let device = TuyaClient.device(from: json)
        #expect(device.kind == .lock)
        #expect(device.isOn == nil)
        #expect(device.detail == "Porta fechada · bateria 88%")
        #expect(device.hasLiveVideo)
        #expect(device.controls["tuyaStatus"] == "closed_opened=closed, residual_electricity=88, lock_motor_state=false")
    }

    /// SmartThings: a robot (robotCleanerMovement) cleans and goes home; a lock says locked and its battery.
    @Test func smartThingsRobotAndLock() throws {
        func make(_ capability: String) -> HomeDevice? {
            SmartThingsClient.device(from: ["deviceId": "d1", "label": "X",
                                            "components": [["id": "main", "capabilities": [["id": .string(capability)], ["id": "battery"]]]]])
        }
        var robot = try #require(make("robotCleanerMovement"))
        #expect(robot.kind == .vacuum)
        robot = SmartThingsClient.applyStatus(["robotCleanerMovement": ["robotCleanerMovement": ["value": "cleaning"]],
                                               "battery": ["battery": ["value": 64]]], to: robot)
        #expect(robot.isOn == true)
        #expect(robot.detail == "Limpando · bateria 64%")
        #expect(try SmartThingsClient.command(for: .power(false), device: robot)["arguments"] == ["homing"])
        var lock = try #require(make("lock"))
        #expect(lock.kind == .lock)
        lock = SmartThingsClient.applyStatus(["lock": ["lock": ["value": "locked"]], "battery": ["battery": ["value": 90]]], to: lock)
        #expect(lock.isOn == nil)
        #expect(lock.detail == "Trancada · bateria 90%")
        #expect(throws: ProviderError.unsupported) { try SmartThingsClient.command(for: .power(true), device: lock) }
    }

    /// A Smart Life air conditioner: set point in tenths (240 = 24 °C), sent back the same way.
    @Test func airConditionerTakesTemperature() throws {
        let json: JSONValue = [
            "id": "a1", "name": "Ar do quarto", "category": "kt",
            "status": [["code": "switch", "value": true], ["code": "temp_set", "value": 240], ["code": "temp_current", "value": 27]],
        ]
        let device = TuyaClient.device(from: json)
        #expect(device.kind == .airConditioner)
        #expect(device.acceptsTemperature)
        #expect(device.targetTemperature == 24)
        #expect(device.roomTemperature == 27)
        #expect(device.detail == "Ambiente 27° · ajustado em 24°")
        let commands = try TuyaClient.commands(for: .temperature(22), device: device)
        #expect(commands == [["code": "temp_set", "value": 220]])
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

    /// Not only LG: a Samsung air conditioner shows the room and the set point, and takes a temperature.
    @Test func airConditionerTakesTemperature() throws {
        let json: JSONValue = [
            "deviceId": "ac1", "label": "Ar da sala",
            "components": [["id": "main", "capabilities": [["id": "switch"], ["id": "airConditionerMode"],
                                                          ["id": "temperatureMeasurement"], ["id": "thermostatCoolingSetpoint"]]]],
        ]
        let device = try #require(SmartThingsClient.device(from: json))
        #expect(device.kind == .airConditioner)
        let status: JSONValue = [
            "switch": ["switch": ["value": "on"]],
            "temperatureMeasurement": ["temperature": ["value": 26, "unit": "C"]],
            "thermostatCoolingSetpoint": ["coolingSetpoint": ["value": 23, "unit": "C"]],
        ]
        let read = SmartThingsClient.applyStatus(status, to: device)
        #expect(read.acceptsTemperature)
        #expect(read.targetTemperature == 23)
        #expect(read.roomTemperature == 26)
        #expect(read.detail == "Ambiente 26° · ajustado em 23°")
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

    /// A widget's list can be old: "on" for a lamp it still thinks is on must go out anyway.
    @Test func forcedCommandGoesOutEvenWhenTheListAgrees() async throws {
        var on = lamp
        on.isOn = true
        let tuya = FakeProvider(.tuya, [on])
        let store = HomeStore(makeProviders: { [tuya] }, sleep: { _ in })
        await store.refresh()
        store.perform(.power(true), on: "tuya:l1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await tuya.sentCommands().isEmpty)
        store.perform(.power(true), on: "tuya:l1", force: true)
        try await waitUntil { await tuya.sentCommands().count == 1 }
        #expect(await tuya.sentCommands().first?.0 == .power(true))
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

@Suite struct SamsungRemoteTests {
    static func tv(_ flags: [String], _ extra: [String: String] = [:]) -> HomeDevice {
        var device = HomeDevice(provider: .smartThings, rawID: "t", name: "TV", kind: .tv, isOn: true)
        for flag in flags { device.controls[flag] = "1" }
        device.controls.merge(extra) { _, new in new }
        return device
    }

    @Test func keysByCapability() throws {
        let full = Self.tv(["st.keys", "st.volume", "st.mute", "st.channel", "st.playback", "st.inputs"],
                           ["inputs": "dtv,HDMI3", "input": "dtv", "playback": "playing", "volume": "0"])
        #expect(try SmartThingsClient.command(for: .up, device: full)["arguments"] == ["UP", "PRESS_AND_RELEASED"])
        #expect(try SmartThingsClient.command(for: .volumeUp, device: full)["command"] == "volumeUp")
        #expect(try SmartThingsClient.command(for: .mute, device: full)["command"] == "unmute")
        #expect(try SmartThingsClient.command(for: .playPause, device: full)["command"] == "pause")
        #expect(try SmartThingsClient.command(for: .inputs, device: full)["arguments"] == ["HDMI3"])
        #expect(try SmartThingsClient.command(for: .channelDown, device: full)["command"] == "channelDown")
        #expect(full.hasRemote && full.hasDirectionalPad && full.hasChannels && !full.canType)

        var soundbar = Self.tv(["st.volume", "st.audioInput"])
        soundbar.kind = .speaker
        #expect(soundbar.hasRemote && !soundbar.hasDirectionalPad && !soundbar.hasChannels)
        #expect(try SmartThingsClient.command(for: .inputs, device: soundbar)["command"] == "setNextInputSource")
        #expect(throws: ProviderError.unsupported) { try SmartThingsClient.command(for: .up, device: soundbar) }
    }

    @Test func readsVolumeAndInput() throws {
        let json: JSONValue = ["deviceId": "t", "label": "TV", "ocf": ["ocfDeviceType": "oic.d.tv"],
                               "components": [["id": "main", "capabilities": [["id": "switch"], ["id": "audioVolume"], ["id": "audioMute"],
                                                                               ["id": "samsungvd.mediaInputSource"], ["id": "samsungvd.remoteControl"]]]]]
        let device = try #require(SmartThingsClient.device(from: json))
        let status: JSONValue = [
            "switch": ["switch": ["value": "on"]], "audioVolume": ["volume": ["value": 12]], "audioMute": ["mute": ["value": "unmuted"]],
            "samsungvd.mediaInputSource": ["supportedInputSourcesMap": ["value": [["id": "dtv", "name": "TV"], ["id": "HDMI3", "name": "Soundbar"]]],
                                           "inputSource": ["value": "HDMI3"]],
        ]
        let read = SmartThingsClient.applyStatus(status, to: device)
        #expect(read.controls["volume"] == "12")
        #expect(read.controls["inputs"] == "dtv,HDMI3")
        #expect(read.detail == "Soundbar")
    }
}

// MARK: - SmartThings integrations per device

@Suite struct SmartThingsSetupTests {
    @Test func createsAnIntegrationNamedForTheDevice() async throws {
        final class Sent: @unchecked Sendable { var request: URLRequest? }
        let sent = Sent()
        let made = try await SmartThingsSetup.createIntegration(personalToken: "pat", deviceName: "iPhone") { request in
            sent.request = request
            let body = Data(#"{"app":{"appId":"a1"},"oauthClientId":"cid","oauthClientSecret":"sec"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(made == SmartThingsSetup.Integration(clientID: "cid", secret: "sec"))
        let request = try #require(sent.request)
        #expect(request.url?.absoluteString == "https://api.smartthings.com/v1/apps")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pat")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["appType"]?.string == "API_ONLY")
        #expect(body["displayName"]?.string == "Lar (iPhone)")
        #expect(body["oauth"]?["redirectUris"]?.array?.first?.string == SmartThingsSignIn.redirect)
        #expect(body["oauth"]?["scope"]?.array?.count == 3)
        #expect(body["appName"]?.string?.hasPrefix("lar-") == true)
    }

    @Test func refusedTokenSaysWhy() async {
        await #expect(throws: ProviderError.api("Token recusado: crie um com a permissão de apps (Apps)")) {
            _ = try await SmartThingsSetup.createIntegration(personalToken: "bad", deviceName: "Mac") { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    @Test func fingerprintHidesTheIDAndMatchesOnlyItself() {
        let a = SmartThingsClaims.fingerprint("4c4db767-0000"), b = SmartThingsClaims.fingerprint("9fa06221-0000")
        #expect(a != b)
        #expect(a == SmartThingsClaims.fingerprint("4C4DB767-0000"))
        #expect(!a.contains("4c4db767"))
        #expect(a.count == 24)
    }
}

// MARK: - Alexa

@Suite struct AlexaTests {
    static let account = AlexaAccount(domain: "com.br", serial: "SER", refreshToken: "rt", cookies: ["session-token": "s"],
                                      customerID: "C1", language: "pt-BR")

    /// Answers by path; records what was sent.
    final class Fake: @unchecked Sendable {
        var sent: [URLRequest] = []
        var answers: [String: String] = [:]
        func transport() -> HTTPTransport {
            { request in
                self.sent.append(request)
                let body = self.answers.first { request.url!.path.hasSuffix($0.key) }?.value ?? "{}"
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    @Test func listsEchosWithMicrophonesOnly() {
        let json = try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"devices":[
          {"serialNumber":"E1","deviceType":"A4ZXE0RM7LQ7A","accountName":"Echo da Sala","deviceFamily":"ECHO","online":true,"capabilities":["MICROPHONE","VOLUME_SETTING"]},
          {"serialNumber":"APP","deviceType":"A2IVLV5VM2W81","accountName":"Alexa no iPhone","capabilities":["MICROPHONE"]},
          {"serialNumber":"B1","deviceType":"X","accountName":"Lâmpada","capabilities":[]}
        ]}
        """.utf8))
        let echos = AlexaClient.devices(from: json)
        #expect(echos.map(\.name) == ["Echo da Sala"])
        #expect(echos.first?.members == ["E1"])
        let device = AlexaProvider.device(echos[0], volume: 40, doNotDisturb: true)
        #expect(device.id == "alexa:E1")
        #expect(device.kind == .speaker)
        #expect(device.detail == "Volume 40 · Não perturbe")
        #expect(device.echo == echos[0])
    }

    @Test func speakSendsARoutinePreview() async throws {
        let fake = Fake()
        let client = AlexaClient(account: Self.account, transport: fake.transport())
        let echo = AlexaDevice(serial: "E1", type: "T1", name: "Echo", family: "ECHO", online: true, members: ["E1"])
        try await client.speak("Porteiro chamando", on: echo)
        let post = try #require(fake.sent.last)
        #expect(post.url?.absoluteString == "https://alexa.amazon.com.br/api/behaviors/preview")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(post.httpBody))
        let sequence = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(body["sequenceJson"]?.string).utf8))
        let node = try #require(sequence["startNode"]?["nodesToExecute"]?.array?.first)
        #expect(node["type"]?.string == "Alexa.Speak")
        #expect(node["operationPayload"]?["textToSpeak"]?.string == "Porteiro chamando")
        #expect(node["operationPayload"]?["deviceSerialNumber"]?.string == "E1")
        #expect(node["operationPayload"]?["locale"]?.string == "pt-BR")
    }

    @Test func routineBecomesSceneWithAlexaLeftovers() throws {
        let start = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"@type":"com.amazon.alexa.behaviors.model.SerialNode","nodesToExecute":[
          {"type":"Alexa.SmartHome.Batch","operationPayload":{"target":["ent-1"],"operations":[{"type":"turnOff"}]}},
          {"@type":"com.amazon.alexa.behaviors.model.ParallelNode","nodesToExecute":[
            {"type":"Alexa.SmartHome.Batch","operationPayload":{"target":["ent-2"],"operations":[{"type":"setTargetTemperature","targetTemperature":{"value":23,"scale":"celsius"}}]}},
            {"type":"Alexa.Speak","operationPayload":{"textToSpeak":"Boa noite"}}
          ]},
          {"type":"Alexa.SmartHome.Batch","operationPayload":{"target":["ent-9"],"operations":[{"type":"turnOn"}]}}
        ]}
        """.utf8))
        let devices = [HomeDevice(provider: .tuya, rawID: "l1", name: "Luz da Sala", kind: .light, isOn: true),
                       HomeDevice(provider: .lg, rawID: "ac", name: "Ar do quarto", kind: .airConditioner, isOn: false)]
        let names = ["ent-1": "luz da sala", "ent-2": "Ar do Quarto", "ent-9": "Tomada só da Alexa"]
        let result = AlexaRoutineConverter.convert(start, names: names, devices: devices)
        #expect(result.actions.map(\.command) == [.power(false), .temperature(23)])
        #expect(result.actions.map(\.deviceID) == ["tuya:l1", "lg:ac"])
        #expect(result.leftover.map { $0["type"]?.string } == ["Alexa.Speak", "Alexa.SmartHome.Batch"])
        #expect(AlexaRoutineConverter.sequence(result.leftover)?.contains("Boa noite") == true)
    }

    /// Only the routines that are on come in.
    @Test func onlyActiveRoutines() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        [{"automationId":"r1","name":"Bom dia","status":"ENABLED","sequence":{"startNode":{"type":"Alexa.Speak"}}},
         {"automationId":"r2","name":"Antiga","status":"DISABLED","sequence":{"startNode":{"type":"Alexa.Speak"}}},
         {"automationId":"r3","name":"Sem estado","sequence":{"startNode":{"type":"Alexa.Speak"}}}]
        """.utf8))
        #expect(AlexaClient.routines(from: json).map(\.name) == ["Bom dia"])
        #expect(AlexaClient.routines(from: json).first?.id == "r1")
    }

    @Test func smartHomeNamesByEveryID() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"data":{"listEndpoints":{"endpoints":[{"endpointId":"amzn1.alexa.endpoint.x","friendlyNameObject":{"value":{"text":"Luz"}},
          "legacyIdentifiers":{"chrsIdentifier":{"entityId":"ent-1"}},"legacyAppliance":{"applianceId":"SKILL_abc"}}]}}}
        """.utf8))
        let names = AlexaClient.names(from: json)
        #expect(names["ent-1"] == "Luz")
        #expect(names["SKILL_abc"] == "Luz")
        #expect(names["amzn1.alexa.endpoint.x"] == "Luz")
    }

    @Test func registrationKeepsTokenCookiesAndCustomer() async throws {
        let fake = Fake()
        fake.answers["auth/register"] = """
        {"response":{"success":{"tokens":{"bearer":{"refresh_token":"Atnr|x","access_token":"a","expires_in":"3600"},
          "website_cookies":[{"Name":"at-main","Value":"\\"abc\\""},{"Name":"ubid-main","Value":"u"}],
          "store_authentication_cookie":{"cookie":"sess"}},"extensions":{"customer_info":{"user_id":"U"}}}}}
        """
        fake.answers["auth/token"] = #"{"response":{"tokens":{"cookies":{".amazon.com.br":[{"Name":"at-acbbr","Value":"new"}]}}}}"#
        fake.answers["api/users/me"] = #"{"id":"CUST","countryOfResidence":"BR"}"#
        let attempt = AlexaSignIn.Attempt(domain: "com.br", language: "pt-BR", serial: "ABC")
        let account = try await AlexaSignIn.register(code: "code", attempt: attempt, transport: fake.transport())
        #expect(account.refreshToken == "Atnr|x")
        #expect(account.customerID == "CUST")
        #expect(account.cookies["at-acbbr"] == "new")
        #expect(account.serial == "ABC")
        let register = try JSONDecoder().decode(JSONValue.self, from: try #require(fake.sent.first?.httpBody))
        #expect(register["auth_data"]?["authorization_code"]?.string == "code")
        #expect(register["registration_data"]?["device_serial"]?.string == "ABC")
        #expect(attempt.url.absoluteString.hasPrefix("https://www.amazon.com.br/ap/signin?"))
        // Brazil's site wants the country's handle and its own landing (the US ones answer "page not found").
        let query = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "openid.assoc_handle" }?.value == "amzn_dp_project_dee_ios_br")
        #expect(query.first { $0.name == "openid.return_to" }?.value == "https://www.amazon.com.br/ap/maplanding")
        #expect(AlexaSignIn.Attempt(domain: "com", language: "en-US").handle == "amzn_dp_project_dee_ios")
        #expect(AlexaSignIn.code(in: URL(string: "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=XYZ")!) == "XYZ")
    }
}

@Suite struct PagingTests {
    @Test func pagesAndClamps() {
        let all = Array(1...17)
        let first = Paged(all, page: 0, size: 8)
        #expect(first.items == Array(1...8) && first.pages == 3 && !first.hasPrevious && first.hasNext)
        let last = Paged(all, page: 9, size: 8)
        #expect(last.page == 2 && last.items == [17] && last.label == "3 de 3" && !last.hasNext)
        #expect(Paged([Int](), page: 0, size: 8).pages == 1)
    }
}

@Suite struct WatchPayloadSizeTests {
    /// Many imported routines: their Alexa steps leave the watch's payload, the account and the scenes stay.
    @Test func bigPayloadDropsAlexaStepsFirst() throws {
        let steps = String(repeating: "x", count: 2_000)
        let scenes = (0..<40).map { i -> HomeScene in
            var scene = HomeScene(name: "Rotina \(i)", actions: [.init(deviceID: "tuya:l", deviceName: "Luz", command: .power(true))])
            scene.alexaSteps = steps
            return scene
        }
        var payload = WatchPayload(lgToken: "t", tuya: nil, smartThingsAccessToken: nil, smartThingsExpires: nil,
                                   temperatureLimits: .standard, scenes: scenes)
        payload.alexa = AlexaAccount(domain: "com.br", serial: "S", refreshToken: "rt", cookies: [:], customerID: "C", language: "pt-BR")
        #expect(try payload.encoded().count > WatchPayload.watchLimit)
        let lean = try WatchPayload.decoded(try payload.encodedForWatch())
        #expect(try payload.encodedForWatch().count <= WatchPayload.watchLimit)
        #expect(lean.alexa?.refreshToken == "rt")
        #expect(lean.scenes?.count == 40)
        #expect(lean.scenes?.allSatisfy { $0.alexaSteps == nil && $0.actions.count == 1 } == true)
    }

    /// Still too big without the Alexa steps: names alone go, favorites, rooms and hidden devices stay.
    @Test func biggerPayloadKeepsOnlyCustomizationsThatMatter() throws {
        var customizations: [String: DeviceCustomization] = [:]
        for i in 0..<2_000 { customizations["tuya:\(i)"] = DeviceCustomization(name: "Aparelho com um nome comprido \(i)") }
        customizations["tuya:fav"] = DeviceCustomization(isFavorite: true)
        customizations["tuya:room"] = DeviceCustomization(room: "Sala")
        var payload = WatchPayload(lgToken: "t", tuya: nil, smartThingsAccessToken: nil, smartThingsExpires: nil,
                                   temperatureLimits: .standard, scenes: [])
        payload.customizations = customizations
        #expect(try payload.encoded().count > WatchPayload.watchLimit)
        let lean = try WatchPayload.decoded(try payload.encodedForWatch())
        #expect(lean.customizations?.keys.sorted() == ["tuya:fav", "tuya:room"])
        #expect(lean.lgToken == "t")
    }
}
