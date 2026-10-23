import Foundation
import Observation

/// Several commands run with one tap ("Dormir": TV off, lights off). Made from the devices' state at the moment
/// it's saved, then kept as a list of commands by device.
public struct HomeScene: Codable, Sendable, Identifiable, Equatable, Hashable {
    public struct Action: Codable, Sendable, Equatable, Hashable {
        public var deviceID: String
        /// The device's name when the scene was saved, to show it even when the device is gone.
        public var deviceName: String
        public var command: HomeCommand

        public init(deviceID: String, deviceName: String, command: HomeCommand) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.command = command
        }
    }

    public var id: UUID
    public var name: String
    /// An SF Symbol.
    public var symbol: String
    public var actions: [Action]

    public init(id: UUID = UUID(), name: String, symbol: String = "sparkles", actions: [Action]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.actions = actions
    }

    /// The symbols offered when making a scene.
    public static let symbols = ["sparkles", "moon.fill", "sun.max.fill", "house.fill", "door.left.hand.open", "bed.double.fill",
                                 "tv", "film", "fork.knife", "book.fill", "figure.walk", "snowflake"]

    /// What a device does in a scene, from its state now: power, and the brightness of a dimmable light that's on.
    public static func actions(for device: HomeDevice, on: Bool) -> [Action] {
        var out = [Action(deviceID: device.id, deviceName: device.name, command: .power(on))]
        if on, device.kind == .light, let brightness = device.brightness {
            out.append(Action(deviceID: device.id, deviceName: device.name, command: .brightness(brightness)))
        }
        return out
    }

    /// The devices a scene can switch.
    public static func candidates(_ devices: [HomeDevice]) -> [HomeDevice] {
        devices.filter { $0.isOn != nil && $0.kind != .camera }
    }

    /// The air conditioner's target the scene sets, if any.
    public func temperature(of deviceID: String) -> Double? {
        for action in actions where action.deviceID == deviceID {
            if case .temperature(let value) = action.command { return value }
        }
        return nil
    }

    /// Whether the scene turns the device on (true), off (false), or doesn't touch it (nil).
    public func power(of deviceID: String) -> Bool? {
        for action in actions where action.deviceID == deviceID {
            if case .power(let on) = action.command { return on }
        }
        return nil
    }
}

/// The saved scenes, shared by every screen of an app.
@MainActor
@Observable
public final class SceneStore {
    public private(set) var scenes: [HomeScene]
    @ObservationIgnored private let settings: AccountSettings

    public init(settings: AccountSettings) {
        self.settings = settings
        self.scenes = settings.scenes
    }

    public func scene(id: UUID) -> HomeScene? { scenes.first { $0.id == id } }

    public func save(_ scene: HomeScene) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        settings.scenes = scenes
    }

    public func delete(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        settings.scenes = scenes
    }

    /// After the scenes changed elsewhere (the watch receiving the iPhone's).
    public func reload() { scenes = settings.scenes }
}

extension HomeStore {
    /// Runs every command of the scene through the usual queue. Says which devices couldn't be reached, if any.
    @discardableResult
    public func run(_ scene: HomeScene) -> String? {
        var missing: [String] = []
        for action in scene.actions {
            guard let device = device(id: action.deviceID), device.isOnline || device.canSwitch else {
                if !missing.contains(action.deviceName) { missing.append(action.deviceName) }
                continue
            }
            perform(action.command, on: device.id)
        }
        guard !missing.isEmpty else { return nil }
        let message = "\(scene.name): \(missing.joined(separator: ", ")) fora do ar"
        showNotice(message)
        return message
    }
}

/// A scene being made or changed: name, symbol and, per device, on / off / left alone. Shared by the Mac's and the
/// iPhone's editors.
public struct SceneDraft: Equatable, Sendable {
    public var name: String
    public var symbol: String
    /// true: turn on, false: turn off; absent: the scene leaves the device alone.
    public var choices: [String: Bool]
    /// Air conditioners turned on by the scene: the target to set (absent: left as it is).
    public var temperatures: [String: Double]
    public let original: HomeScene?

    public init(editing scene: HomeScene? = nil) {
        original = scene
        name = scene?.name ?? ""
        symbol = scene?.symbol ?? "sparkles"
        var choices: [String: Bool] = [:], temperatures: [String: Double] = [:]
        for action in scene?.actions ?? [] {
            switch action.command {
            case .power(let on): choices[action.deviceID] = on
            case .temperature(let value): temperatures[action.deviceID] = value
            default: break
            }
        }
        self.choices = choices
        self.temperatures = temperatures
    }

    /// Every device as it is now.
    public mutating func useCurrentState(of devices: [HomeDevice]) {
        for device in HomeScene.candidates(devices) { choices[device.id] = device.isOn == true }
    }

    public var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !choices.isEmpty }

    /// The devices to list: those that can be switched now, then the scene's own that are gone.
    public func rows(_ devices: [HomeDevice]) -> [(id: String, name: String, device: HomeDevice?)] {
        let present = HomeScene.candidates(devices)
        var rows = present.map { (id: $0.id, name: $0.name, device: Optional($0)) }
        var seen = Set(rows.map(\.id))
        for action in original?.actions ?? [] where seen.insert(action.deviceID).inserted {
            rows.append((id: action.deviceID, name: action.deviceName, device: nil))
        }
        return rows
    }

    /// The scene: a device whose choice didn't change keeps its saved commands (its brightness, or a device gone);
    /// a new choice takes the device's state now.
    public func build(with devices: [HomeDevice]) -> HomeScene {
        var actions: [HomeScene.Action] = []
        for (id, on) in choices.sorted(by: { $0.key < $1.key }) {
            let saved = (original?.actions.filter { $0.deviceID == id } ?? []).filter {
                if case .temperature = $0.command { return false } else { return true }
            }
            var name = saved.first?.deviceName
            if original?.power(of: id) == on, !saved.isEmpty {
                actions += saved
            } else if let device = devices.first(where: { $0.id == id }) {
                actions += HomeScene.actions(for: device, on: on)
                name = device.name
            } else if let name {
                actions.append(.init(deviceID: id, deviceName: name, command: .power(on)))
            }
            // The target goes after switching on (a unit that's off ignores it).
            if on, let target = temperatures[id], let name {
                actions.append(.init(deviceID: id, deviceName: name, command: .temperature(target)))
            }
        }
        return HomeScene(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, actions: actions)
    }
}
