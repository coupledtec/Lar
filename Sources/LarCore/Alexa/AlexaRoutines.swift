import Foundation

/// Alexa routines turned into Lar scenes: the smart home steps whose devices the Lar also has (by name) become the
/// scene's own commands; every other step (speaking, music, the weather, devices only Alexa has) stays with Alexa
/// and runs on an Echo with the scene.
public enum AlexaRoutineConverter {
    public struct Result: Sendable, Equatable {
        public var actions: [HomeScene.Action]
        /// The steps left to Alexa, as nodes of a routine.
        public var leftover: [JSONValue]
    }

    public static func convert(_ start: JSONValue, names: [String: String], devices: [HomeDevice]) -> Result {
        var result = Result(actions: [], leftover: [])
        for node in steps(start) {
            if let actions = smartHome(node, names: names, devices: devices) {
                result.actions += actions
            } else {
                result.leftover.append(node)
            }
        }
        return result
    }

    /// The routine's steps, one after the other (serial and parallel groups opened up).
    static func steps(_ node: JSONValue) -> [JSONValue] {
        if let children = node["nodesToExecute"]?.array { return children.flatMap(steps) }
        return node["type"] != nil || node["operationPayload"] != nil ? [node] : []
    }

    /// A smart home step whose every target and operation the Lar can do; nil otherwise (it stays with Alexa).
    static func smartHome(_ node: JSONValue, names: [String: String], devices: [HomeDevice]) -> [HomeScene.Action]? {
        guard node["type"]?.string?.hasPrefix("Alexa.SmartHome") == true, let payload = node["operationPayload"] else { return nil }
        let targets = (payload["target"]?.array ?? payload["targets"]?.array ?? [payload["target"]].compactMap { $0 })
            .compactMap { $0.string ?? $0["id"]?.string ?? $0["entityId"]?.string }
        let operations = payload["operations"]?.array ?? [payload]
        guard !targets.isEmpty, !operations.isEmpty else { return nil }
        var out: [HomeScene.Action] = []
        for target in targets {
            guard let name = names[target],
                  let device = devices.first(where: { LarLink.same($0.name, name) && $0.provider != .alexa }) else { return nil }
            for operation in operations {
                guard let command = command(operation) else { return nil }
                out.append(.init(deviceID: device.id, deviceName: device.name, command: command))
            }
        }
        return out
    }

    static func command(_ operation: JSONValue) -> HomeCommand? {
        switch operation["type"]?.string {
        case "turnOn", "TurnOn": return .power(true)
        case "turnOff", "TurnOff": return .power(false)
        case "setBrightness", "SetBrightness":
            guard let value = operation["brightness"]?.double ?? operation["value"]?.double else { return nil }
            return .brightness(min(max(value / 100, 0.01), 1))
        case "setTargetTemperature", "SetTargetTemperature":
            let target = operation["targetTemperature"] ?? operation["targetSetpoint"]
            guard var value = target?["value"]?.double ?? target?.double else { return nil }
            if target?["scale"]?.string?.lowercased() == "fahrenheit" { value = (value - 32) * 5 / 9 }
            return .temperature(value.rounded())
        default: return nil
        }
    }

    /// The steps left to Alexa as one routine node, in the order they were.
    public static func sequence(_ leftover: [JSONValue]) -> String? {
        guard !leftover.isEmpty else { return nil }
        let node: JSONValue = ["@type": "com.amazon.alexa.behaviors.model.SerialNode", "nodesToExecute": .array(leftover)]
        return (try? JSONEncoder().encode(node)).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Brings the account's routines in as scenes. By hand: every routine, the imported ones brought up to date. Every
/// hour (the Mac): only routines never seen before, so a scene the person deleted doesn't come back.
@MainActor
public enum AlexaRoutineImport {
    static let seenKey = "alexaSeenRoutines"

    public static var autoImport: Bool {
        get { Preferences.bool(forKey: "alexaAutoImport") ?? true }
        set { Preferences.set(newValue, forKey: "alexaAutoImport") }
    }

    /// How many scenes were made or updated.
    @discardableResult
    public static func run(home: HomeStore, scenes: SceneStore, onlyNew: Bool) async throws -> Int {
        guard let alexa = home.alexa else { return 0 }
        // Only the routines that are on: a routine turned off (or deleted) in Alexa takes its scene away too.
        let routines = try await alexa.routines()
        let active = Set(routines.map(\.id))
        // (An empty answer is taken as a hiccup, not as every routine gone.)
        for scene in scenes.scenes where !active.isEmpty && scene.alexaRoutineID.map({ !active.contains($0) }) == true {
            scenes.delete(scene.id)
        }
        var seen = Set(Preferences.object(forKey: seenKey) as? [String] ?? [])
        let fresh = routines.filter { !seen.contains($0.id) }
        let wanted = onlyNew ? fresh : routines
        guard !wanted.isEmpty else { return 0 }
        let names = (try? await alexa.smartHomeNames()) ?? [:]
        var count = 0
        for routine in wanted {
            let converted = AlexaRoutineConverter.convert(routine.startNode, names: names, devices: home.devices)
            var scene = scenes.scenes.first { $0.alexaRoutineID == routine.id }
                ?? HomeScene(name: routine.name, symbol: "sparkles", actions: [])
            if onlyNew, scenes.scenes.contains(where: { $0.alexaRoutineID == routine.id }) { continue }
            scene.actions = converted.actions
            scene.alexaRoutineID = routine.id
            scene.alexaSteps = AlexaRoutineConverter.sequence(converted.leftover)
            scenes.save(scene)
            count += 1
        }
        seen.formUnion(routines.map(\.id))
        Preferences.set(Array(seen), forKey: seenKey)
        return count
    }
}

extension HomeStore {
    /// The scene's Alexa steps, on its own Echo or else the first one online. When they can't go out (no account,
    /// no Echo, Alexa refused) the message under the list says so: the rest of the scene did run.
    func runAlexaSteps(of scene: HomeScene) {
        guard let steps = scene.alexaSteps,
              let node = try? JSONDecoder().decode(JSONValue.self, from: Data(steps.utf8)) else { return }
        guard let alexa else {
            showNotice(tr("\(scene.name): conta da Alexa desconectada, a parte dela não rodou"))
            return
        }
        let chosen = scene.alexaEcho.flatMap { device(id: $0)?.echo }.flatMap { $0.online ? $0 : nil }
        guard let echo = chosen ?? echos.first else {
            showNotice(tr("\(scene.name): nenhum Echo no ar, a parte da Alexa não rodou"))
            return
        }
        Task {
            do {
                try await alexa.run(steps: node, on: echo)
            } catch {
                showNotice(tr("\(scene.name), Alexa: \((error as? ProviderError)?.message ?? error.localizedDescription)"))
            }
        }
    }
}
