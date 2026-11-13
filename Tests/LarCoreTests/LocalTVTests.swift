import Foundation
import Testing
@testable import LarCore

/// LG and Samsung TVs on the network: the messages they expect (no TV needed).
@Suite struct LocalTVTests {
    @Test func lgRegistersWithThePromptAndTheKey() throws {
        let first = LGWebOSClient.registration(clientKey: nil)
        #expect(first["type"] as? String == "register")
        let payload = try #require(first["payload"] as? [String: Any])
        #expect(payload["pairingType"] as? String == "PROMPT")
        #expect(payload["client-key"] == nil)
        let permissions = (payload["manifest"] as? [String: Any])?["permissions"] as? [String] ?? []
        #expect(permissions.contains("CONTROL_INPUT_TEXT") && permissions.contains("CONTROL_POWER"))
        let again = LGWebOSClient.registration(clientKey: "abc")
        #expect((again["payload"] as? [String: Any])?["client-key"] as? String == "abc")
    }

    @Test func everyKeyHasAButtonOnBoth() {
        for key in AndroidTVProvider.Key.allCases {
            #expect(!LGWebOSClient.buttonName(key).isEmpty)
            #expect(SamsungTVClient.keyName(key).hasPrefix("KEY_"))
        }
        #expect(LGWebOSClient.buttonName(.back) == "BACK")
        #expect(SamsungTVClient.keyName(.back) == "KEY_RETURN")
    }

    @Test func pairedTVsShowWithTheFullRemote() {
        let device = HomeDevice(provider: .samsungTV, rawID: "samsung:192.0.2.5", name: "TV", kind: .tv, isOn: true)
        #expect(device.hasRemote && device.hasDirectionalPad && device.canType && device.hasApps && device.hasChannels)
        #expect(LocalTV(kind: .lg, host: "192.0.2.4", name: "TV LG").id == "lg:192.0.2.4")
    }
}

/// Locks the Lar can open: locking goes out, unlocking only with the owner's confirmation.
@Suite @MainActor struct LockTests {
    @Test func unlockingNeedsTheOwner() async throws {
        let home = HomeStore(previewDevices: DemoHome.devices)
        let door = try #require(home.devices.first { $0.kind == .lock })
        #expect(door.canLock && door.isOn == true && !door.countsAsOn)
        home.perform(.power(false), on: door.id)
        #expect(home.device(id: door.id)?.isOn == true)
        home.perform(.power(false), on: door.id, unlockAllowed: true)
        #expect(home.device(id: door.id)?.isOn == false)
        #expect(home.device(id: door.id)?.isLocked == false)
        #expect(HAPRole(try #require(home.device(id: door.id))) == .lock)
    }
}

/// Options: an air conditioner's mode from SmartThings and a Smart Life robot's suction from its functions.
@Suite struct DeviceOptionTests {
    @Test func smartThingsListsAndSetsTheMode() throws {
        var ac = HomeDevice(provider: .smartThings, rawID: "a", name: "Ar", kind: .airConditioner, isOn: true)
        ac = SmartThingsClient.applyStatus([
            "airConditionerMode": ["airConditionerMode": ["value": "cool"], "supportedAcModes": ["value": ["cool", "dry", "wind", "auto"]]],
            "airConditionerFanMode": ["fanMode": ["value": "auto"], "supportedAcFanModes": ["value": ["auto", "low", "high"]]],
        ], to: ac)
        let mode = try #require(ac.options.first { $0.name == "airConditionerMode" })
        #expect(mode.values == ["cool", "dry", "wind", "auto"] && mode.current == "cool")
        #expect(mode.title == "Modo" && mode.label("dry") == "Desumidificar")
        let command = try SmartThingsClient.command(for: .option("fanMode", "high"), device: ac)
        #expect(command["command"] == "setFanMode" && command["arguments"] == ["high"])
        #expect(ac.applying(.option("airConditionerMode", "dry")).option("airConditionerMode") == "dry")
    }

    @Test func tuyaOffersItsEnumFunctions() throws {
        let functions: [JSONValue] = [
            ["code": "suction", "type": "Enum", "values": "{\"range\":[\"gentle\",\"normal\",\"strong\"]}"],
            ["code": "power_go", "type": "Boolean", "values": "{}"],
        ]
        let options = TuyaClient.options(fromFunctions: functions)
        #expect(options.count == 1 && options[0].0 == "suction" && options[0].1 == ["gentle", "normal", "strong"])
        var robot = HomeDevice(provider: .tuya, rawID: "r", name: "Robô", kind: .vacuum, isOn: false)
        robot = TuyaClient.applyOptions(options, to: robot, json: ["status": [["code": "suction", "value": "normal"]]])
        #expect(robot.option("suction") == "normal")
        #expect(try TuyaClient.commands(for: .option("suction", "strong"), device: robot) == [["code": "suction", "value": "strong"]])
    }
}

/// Infrared remotes: the Lar's keys found among a remote's own names.
@Suite struct InfraredTests {
    @Test func keysAreFoundByTheirNames() {
        let keys: [(key: String, id: Int)] = [("Power", 1), ("Vol+", 2), ("Vol-", 3), ("OK", 4), ("Back", 5), ("CH+", 6)]
        #expect(TuyaClient.infraredKey(nil, power: true, in: keys)?.id == 1)
        #expect(TuyaClient.infraredKey(.volumeUp, in: keys)?.id == 2)
        #expect(TuyaClient.infraredKey(.volumeDown, in: keys)?.id == 3)
        #expect(TuyaClient.infraredKey(.select, in: keys)?.id == 4)
        #expect(TuyaClient.infraredKey(.channelUp, in: keys)?.id == 6)
        #expect(TuyaClient.infraredKey(.mute, in: keys) == nil)
        #expect(TuyaClient.infraredKind(5) == .airConditioner && TuyaClient.infraredKind(2) == .tv)
    }
}

/// Problems and motion become notifications once, when they appear.
@Suite struct ProblemAlertTests {
    @Test func aNewProblemOrMovementAlertsOnce() {
        let robot = HomeDevice(provider: .irobot, rawID: "r", name: "Roomba", kind: .vacuum, isOn: false)
        var stuck = robot
        stuck.controls["problem"] = "Robô preso"
        #expect(HomeAlert.alerts(from: [robot], to: [stuck]).map(\.body) == ["Robô preso"])
        #expect(HomeAlert.alerts(from: [stuck], to: [stuck]).isEmpty)
        var camera = HomeDevice(provider: .tuya, rawID: "c", name: "Câmera", kind: .camera)
        camera.controls["motion"] = "a"
        var moved = camera
        moved.controls["motion"] = "b"
        #expect(HomeAlert.alerts(from: [camera], to: [moved]).count == 1)
        #expect(RoborockClient.errorText(8) == "Robô preso" && RoborockClient.errorText(0) == nil)
        #expect(OptionText.value("room", "17=Sala") == "Sala")
    }
}
