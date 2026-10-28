import Foundation

/// The account's Xbox consoles, in a "Jogos" section of their own, with a remote: on/off (from sleep), the controller's buttons, volume, the
/// installed games and apps, and what's playing.
public final class XboxProvider: TVRemoteProvider, @unchecked Sendable {
    public let provider = Provider.xbox
    private let client: XboxClient
    private let expected = ExpectedPower()

    public init(client: XboxClient) {
        self.client = client
    }

    public func devices() async throws -> [HomeDevice] {
        let consoles = try await client.consoles()
        let playing = consoles.isEmpty ? nil : try? await client.nowPlaying()
        var out: [HomeDevice] = []
        for console in consoles {
            let status = try? await client.status(of: console.id)
            let state = status?.power ?? console.powerState
            let on = await expected.power(of: console.id, reported: state == "On")
            var detail = ""
            if !console.remoteManagementEnabled {
                detail = tr("Recursos remotos desligados no Xbox")
            } else if on, let playing {
                detail = playing
            } else if state == "Off" {
                // Energy saving: the cloud can't wake it.
                detail = tr("Em economia de energia")
            }
            out.append(HomeDevice(provider: .xbox, rawID: console.id, name: console.name, kind: .gameConsole,
                                  isOnline: console.remoteManagementEnabled, isOn: on, detail: detail,
                                  controls: status?.playback.map { ["playback": $0] } ?? [:]))
        }
        return out
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command else { throw ProviderError.unsupported }
        try await client.command("Power", on ? "WakeUp" : "TurnOff", on: device.rawID)
        // The cloud takes a while to see the change: keep it until it agrees (a minute at most).
        await expected.set(on, for: device.rawID)
    }

    // MARK: Remote

    public func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {
        let id = device.rawID
        switch key {
        case .up: try await client.command("Shell", "InjectKey", parameters: ["keyType": "Up"], on: id)
        case .down: try await client.command("Shell", "InjectKey", parameters: ["keyType": "Down"], on: id)
        case .left: try await client.command("Shell", "InjectKey", parameters: ["keyType": "Left"], on: id)
        case .right: try await client.command("Shell", "InjectKey", parameters: ["keyType": "Right"], on: id)
        case .select: try await client.command("Shell", "InjectKey", parameters: ["keyType": "A"], on: id)
        case .back: try await client.command("Shell", "InjectKey", parameters: ["keyType": "B"], on: id)
        case .home: try await client.command("Shell", "GoHome", on: id)
        case .playPause:
            // No toggle: Play, unless something is playing.
            let playing = device.controls["playback"] == "Playing"
            try await client.command("Media", playing ? "Pause" : "Play", on: id)
        case .volumeUp: try await client.command("Audio", "Volume", parameters: ["direction": "Up", "amount": "1"], on: id)
        case .volumeDown: try await client.command("Audio", "Volume", parameters: ["direction": "Down", "amount": "1"], on: id)
        case .mute: try await client.command("Audio", "Mute", on: id)
        case .inputs, .channelUp, .channelDown: throw ProviderError.unsupported
        }
    }

    /// The controller's buttons the TV remote doesn't have: X, Y, Menu, View and the Xbox button (the guide).
    public enum Button: String, Sendable, CaseIterable {
        case x = "X", y = "Y", menu = "Menu", view = "View", guide = "Guide"
    }

    public func press(_ button: Button, on device: HomeDevice) async throws {
        try await client.command("Shell", "InjectKey", parameters: ["keyType": button.rawValue], on: device.rawID)
    }

    public func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] {
        try await client.installedApps(on: device.rawID).map { AndroidTVProvider.App(package: $0.productID, name: $0.name) }
    }

    public func openApp(_ package: String, on device: HomeDevice) async throws {
        try await client.command("Shell", "ActivateApplicationWithOneStoreProductId",
                                 parameters: ["oneStoreProductId": package], on: device.rawID)
    }

    public func type(_ text: String, on device: HomeDevice) async throws {
        guard !text.isEmpty else { return }
        try await client.command("Shell", "InjectString", parameters: ["replacementString": text], on: device.rawID)
    }
}

/// The last power command per console, until the cloud reports the same or a minute goes by.
actor ExpectedPower {
    private var states: [String: (on: Bool, until: Date)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func set(_ on: Bool, for id: String) {
        states[id] = (on, now().addingTimeInterval(60))
    }

    func power(of id: String, reported: Bool) -> Bool {
        guard let state = states[id], state.until > now(), state.on != reported else {
            states[id] = nil
            return reported
        }
        return state.on
    }
}
