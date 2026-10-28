import Foundation
import Testing
@testable import LarCore

/// Alexa routines made into scenes: what the Lar can do itself, and what stays with Alexa.
@Suite struct AlexaRoutineTests {
    let lamp = HomeDevice(provider: .tuya, rawID: "l1", name: "Luz da Sala", kind: .light, isOn: false)
    let ac = HomeDevice(provider: .lg, rawID: "a1", name: "Ar do Quarto", kind: .airConditioner, isOn: false)
    /// Alexa's own ids for the devices, and their names there (accents and case may differ).
    let names = ["amzn-lamp": "luz da sala", "amzn-ac": "Ar do quarto", "amzn-plug": "Tomada da Varanda"]

    private func smartHome(_ target: String, _ operations: [JSONValue]) -> JSONValue {
        ["@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode",
         "type": "Alexa.SmartHome.Batch",
         "operationPayload": ["target": .array([.string(target)]), "operations": .array(operations)]]
    }

    private let speak: JSONValue = ["@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode",
                                    "type": "Alexa.Speak", "operationPayload": ["textToSpeak": "Boa noite"]]

    @Test func devicesTheLarHasBecomeCommands() {
        let routine: JSONValue = [
            "@type": "com.amazon.alexa.behaviors.model.SerialNode",
            "nodesToExecute": [
                smartHome("amzn-lamp", [["type": "turnOn"], ["type": "setBrightness", "brightness": 40]]),
                ["@type": "com.amazon.alexa.behaviors.model.ParallelNode", "nodesToExecute": [
                    smartHome("amzn-ac", [["type": "setTargetTemperature",
                                           "targetTemperature": ["value": 73.4, "scale": "FAHRENHEIT"]]]),
                    speak,
                ]],
            ],
        ]
        let result = AlexaRoutineConverter.convert(routine, names: names, devices: [lamp, ac])
        #expect(result.actions == [
            .init(deviceID: "tuya:l1", deviceName: "Luz da Sala", command: .power(true)),
            .init(deviceID: "tuya:l1", deviceName: "Luz da Sala", command: .brightness(0.4)),
            .init(deviceID: "lg:a1", deviceName: "Ar do Quarto", command: .temperature(23)),
        ])
        #expect(result.leftover == [speak])
    }

    /// A device only Alexa has, or an operation the Lar can't do, leaves the whole step with Alexa.
    @Test func unknownDevicesAndOperationsStayWithAlexa() {
        let plug = smartHome("amzn-plug", [["type": "turnOff"]])
        let color = smartHome("amzn-lamp", [["type": "setColor", "colorName": "red"]])
        let routine: JSONValue = ["nodesToExecute": [plug, color]]
        let result = AlexaRoutineConverter.convert(routine, names: names, devices: [lamp, ac])
        #expect(result.actions.isEmpty)
        #expect(result.leftover == [plug, color])
    }

    /// An Echo is never taken as the Lar's own copy of a device with the same name.
    @Test func echosAreNotTargets() {
        let echo = HomeDevice(provider: .alexa, rawID: "E1", name: "Luz da Sala", kind: .speaker)
        let result = AlexaRoutineConverter.convert(["nodesToExecute": [smartHome("amzn-lamp", [["type": "turnOff"]])]],
                                                   names: names, devices: [echo])
        #expect(result.actions.isEmpty)
        #expect(result.leftover.count == 1)
    }

    @Test func leftoverRunsAsOneSerialNode() throws {
        #expect(AlexaRoutineConverter.sequence([]) == nil)
        let json = try #require(AlexaRoutineConverter.sequence([speak]))
        let node = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(node["@type"]?.string == "com.amazon.alexa.behaviors.model.SerialNode")
        #expect(node["nodesToExecute"]?.array == [speak])
    }

    /// An edit keeps the routine's steps and the Echo chosen for them; a scene that only has Alexa steps can be saved.
    @Test func editingAnImportedSceneKeepsItsAlexaPart() {
        var scene = HomeScene(name: "Boa noite", actions: [])
        scene.alexaRoutineID = "amzn1.alexa.automation.1"
        scene.alexaSteps = AlexaRoutineConverter.sequence([speak])
        var draft = SceneDraft(editing: scene)
        #expect(draft.hasAlexaSteps)
        #expect(draft.canSave)
        draft.alexaEcho = "alexa:E2"
        let saved = draft.build(with: [])
        #expect(saved.alexaSteps == scene.alexaSteps)
        #expect(saved.alexaEcho == "alexa:E2")
        // A scene of the Lar's own has no Alexa part to place.
        var own = SceneDraft()
        own.alexaEcho = "alexa:E2"
        own.name = "Cinema"
        #expect(!own.canSave)
        #expect(own.build(with: []).alexaEcho == nil)
    }
}
