import Foundation

/// The cloud account a device comes from.
public enum Provider: String, Sendable, CaseIterable, Codable {
    case lg, tuya, smartThings, androidTV

    public var name: String {
        switch self {
        case .lg: "LG ThinQ"
        case .tuya: "Smart Life"
        case .smartThings: "SmartThings"
        case .androidTV: "Android TV"
        }
    }
}

/// What a device is, as far as the list and its icon are concerned.
public enum DeviceKind: String, Sendable, CaseIterable, Codable {
    case airConditioner, light, plug, tv, speaker, camera, laundry, kitchen, fan, climateSensor, other
}

/// A color as the apps show it: hue 0–360, saturation 0–1.
public struct LightColor: Sendable, Equatable, Codable {
    public var hue: Double
    public var saturation: Double

    public init(hue: Double, saturation: Double) {
        self.hue = hue
        self.saturation = saturation
    }
}

/// Any device from any account, flattened to what the list shows and what can be changed.
public struct HomeDevice: Sendable, Equatable, Identifiable {
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

    /// A TV off the network can still be tried: it may wake by Wake-on-LAN.
    public var canSwitch: Bool { isOn != nil && (isOnline || (kind == .tv && controls["mac"] != nil)) }
    public var canDim: Bool { brightness != nil && isOnline }
    public var hasColor: Bool { color != nil && isOnline }
    public var hasLiveVideo: Bool { kind == .camera && provider == .tuya && isOnline }

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
        }
        return copy
    }
}

/// The piece of a device's state a command changes. Commands for the same field replace each other.
public enum HomeField: Hashable, Sendable {
    case power, brightness, color
}

public enum HomeCommand: Sendable, Equatable {
    case power(Bool)
    /// 0–1.
    case brightness(Double)
    case color(LightColor)

    public var field: HomeField {
        switch self {
        case .power: .power
        case .brightness: .brightness
        case .color: .color
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
        case .unauthorized: "Chave inválida ou expirada"
        case .network(let message): message
        case .api(let message): message
        case .unsupported: "Este aparelho não aceita esse comando"
        }
    }
}

/// One cloud account: lists its devices and sends them commands.
public protocol DeviceProvider: Sendable {
    var provider: Provider { get }
    func devices() async throws -> [HomeDevice]
    func send(_ command: HomeCommand, to device: HomeDevice) async throws
}

/// A camera's live video, as an HLS link that expires within minutes.
public protocol LiveVideoProvider: Sendable {
    func liveStreamURL(for device: HomeDevice) async throws -> URL
}

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public let defaultTransport: HTTPTransport = { request in try await URLSession.shared.data(for: request) }
