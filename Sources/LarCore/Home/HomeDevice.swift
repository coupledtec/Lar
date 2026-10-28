import Foundation

/// The cloud account a device comes from.
public enum Provider: String, Sendable, CaseIterable, Codable {
    case lg, tuya, smartThings, androidTV, alexa
    /// The accessories of the Apple Home app (HomeKit and Matter), on the iPhone, iPad, Vision Pro and Apple TV.
    case homeKit
    /// Xbox consoles, through Xbox network's cloud.
    case xbox

    public var name: String {
        switch self {
        case .lg: "LG ThinQ"
        case .tuya: "Smart Life"
        case .smartThings: "SmartThings"
        case .androidTV: "Google TV"
        case .alexa: "Alexa"
        case .homeKit: tr("Casa (Apple)")
        case .xbox: "Xbox"
        }
    }

    /// The accounts this device can have: the Apple Home isn't reachable from a Mac app (nor from the watch's).
    public static var available: [Provider] {
        #if os(macOS) || os(watchOS)
        allCases.filter { $0 != .homeKit }
        #else
        allCases
        #endif
    }
}

/// What a device is, as far as the list and its icon are concerned.
public enum DeviceKind: String, Sendable, CaseIterable, Codable {
    case airConditioner, light, plug, tv, speaker, camera, laundry, kitchen, fan, climateSensor, other
    /// Game consoles (the Xbox): a section of their own in the list, "Jogos".
    case gameConsole
    /// Robot vacuums: on is cleaning, off is going back to the dock ("Limpeza").
    case vacuum
    /// Door locks: their state is in the detail; no switch ("Fechaduras").
    case lock
}

/// A color as the apps show it: hue 0–360, saturation 0–1.
public struct LightColor: Sendable, Equatable, Hashable, Codable {
    public var hue: Double
    public var saturation: Double

    public init(hue: Double, saturation: Double) {
        self.hue = hue
        self.saturation = saturation
    }
}

/// Any device from any account, flattened to what the list shows and what can be changed.
public struct HomeDevice: Sendable, Equatable, Identifiable, Codable {
    /// Unique across accounts: "<provider>:<rawID>".
    public var id: String { "\(provider.rawValue):\(rawID)" }
    public var provider: Provider
    public var rawID: String
    public var name: String
    public var kind: DeviceKind
    public var isOnline: Bool
    /// nil: no on/off switch.
    public var isOn: Bool?
    /// 0–1; nil when it can't be dimmed.
    public var brightness: Double?
    /// nil when the light has no color.
    public var color: LightColor?
    /// A short line under the name: a temperature, a cycle and the time left. Empty when there's nothing to add.
    public var detail: String

    /// What the provider needs to send commands (Tuya's switch code, LG's operation key, ...). Not shown.
    public var controls: [String: String]

    public init(
        provider: Provider, rawID: String, name: String, kind: DeviceKind, isOnline: Bool = true,
        isOn: Bool? = nil, brightness: Double? = nil, color: LightColor? = nil, detail: String = "",
        controls: [String: String] = [:]
    ) {
        self.provider = provider
        self.rawID = rawID
        self.name = name
        self.kind = kind
        self.isOnline = isOnline
        self.isOn = isOn
        self.brightness = brightness
        self.color = color
        self.detail = detail
        self.controls = controls
    }

    /// A TV off the network can still be tried: it may wake by Wake-on-LAN, or answer the Google TV remote from a
    /// light standby.
    public var canSwitch: Bool {
        isOn != nil && (isOnline || (kind == .tv && (controls["mac"] != nil || controls["link"] == "remote")))
    }
    public var canDim: Bool { brightness != nil && isOnline }
    public var hasColor: Bool { color != nil && isOnline }
    /// An air conditioner whose target temperature the list can set (LG's).
    /// LG's air conditioners have the full screen (modes, fan, airflow: ThinQ's ACStore); the others (SmartThings,
    /// Smart Life), power and temperature on the plain one.
    public var hasLGPanel: Bool { kind == .airConditioner && provider == .lg }
    public var acceptsTemperature: Bool { kind == .airConditioner && controls["targetTemperature"] != nil }
    public var targetTemperature: Double? { controls["targetTemperature"].flatMap(Double.init) }
    public var roomTemperature: Double? { controls["roomTemperatureValue"].flatMap(Double.init) }

    /// Smart Life cameras, and locks with one (a video doorbell lock).
    public var hasLiveVideo: Bool { (kind == .camera || controls["tuyaVideo"] == "1") && provider == .tuya && isOnline }

    /// A remote screen: an Android TV, an Xbox, or a Samsung TV or soundbar with SmartThings' remote capabilities.
    public var hasRemote: Bool {
        (kind == .tv || kind == .speaker || kind == .gameConsole)
            && (provider == .androidTV || provider == .xbox || controls["st.volume"] != nil || controls["st.keys"] != nil)
    }
    public var hasDirectionalPad: Bool { provider == .androidTV || provider == .xbox || controls["st.keys"] != nil }
    public var hasChannels: Bool { provider == .androidTV || controls["st.channel"] != nil }
    /// Typing into the TV's search: Android TVs and the Xbox.
    public var canType: Bool { provider == .androidTV || provider == .xbox }
    /// The Xbox controller's own buttons (X, Y, Menu, View, the guide) on the remote.
    public var isXbox: Bool { provider == .xbox }

    /// The state expected once `command` is applied.
    public func applying(_ command: HomeCommand) -> HomeDevice {
        var copy = self
        switch command {
        case .power(let on): copy.isOn = on
        case .brightness(let value):
            copy.brightness = value
            // Dimming a light that's off turns it on in every app.
            if copy.isOn == false { copy.isOn = true }
        case .color(let color):
            copy.color = color
            if copy.isOn == false { copy.isOn = true }
        case .temperature(let value):
            copy.controls["targetTemperature"] = HomeText.number(value)
        }
        return copy
    }
}

/// The piece of a device's state a command changes. Commands for the same field replace each other.
public enum HomeField: Hashable, Sendable {
    case power, brightness, color, temperature
}

public enum HomeCommand: Sendable, Equatable, Hashable, Codable {
    case power(Bool)
    /// 0–1.
    case brightness(Double)
    case color(LightColor)
    /// An air conditioner's target, in °C.
    case temperature(Double)

    public var field: HomeField {
        switch self {
        case .power: .power
        case .brightness: .brightness
        case .color: .color
        case .temperature: .temperature
        }
    }
}

/// What went wrong talking to an account, in a form the UI can act on.
public enum ProviderError: Error, Equatable, Sendable {
    case unauthorized
    case network(String)
    case api(String)
    case unsupported

    public var message: String {
        switch self {
        case .unauthorized: tr("Chave inválida ou expirada")
        case .network(let message): message
        case .api(let message): message
        case .unsupported: tr("Este aparelho não aceita esse comando")
        }
    }
}

/// One cloud account: lists its devices and sends them commands.
public protocol DeviceProvider: Sendable {
    var provider: Provider { get }
    func devices() async throws -> [HomeDevice]
    func send(_ command: HomeCommand, to device: HomeDevice) async throws
}

/// A TV's remote: keys and apps (the TVs themselves, or the iPhone's TVs seen from the watch).
public protocol TVRemoteProvider: DeviceProvider {
    func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws
    func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App]
    func openApp(_ package: String, on device: HomeDevice) async throws
    func type(_ text: String, on device: HomeDevice) async throws
}

/// A camera's live video, as an HLS link that expires within minutes.
public protocol LiveVideoProvider: Sendable {
    func liveStreamURL(for device: HomeDevice) async throws -> URL
}

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public let defaultTransport: HTTPTransport = { request in try await URLSession.shared.data(for: request) }
