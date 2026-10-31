import Foundation

/// The Echos of the Amazon account in the list: speakers with their volume and Do Not Disturb. Nothing to switch
/// on or off; their screen speaks, announces, asks Alexa, runs routines and plays or pauses.
public struct AlexaProvider: DeviceProvider {
    public let provider = Provider.alexa
    public let client: AlexaClient

    public init(client: AlexaClient) {
        self.client = client
    }

    public func devices() async throws -> [HomeDevice] {
        async let volumes = try? client.volumes()
        async let quiet = try? client.doNotDisturb()
        let echos = try await client.devices()
        let (volume, dnd) = await (volumes ?? [:], quiet ?? [:])
        return echos.map { Self.device($0, volume: volume[$0.serial], doNotDisturb: dnd[$0.serial]) }
    }

    static func device(_ echo: AlexaDevice, volume: Int?, doNotDisturb: Bool?) -> HomeDevice {
        var device = HomeDevice(provider: .alexa, rawID: echo.serial, name: echo.name, kind: .speaker,
                                isOnline: echo.online)
        device.controls["alexaType"] = echo.type
        device.controls["alexaFamily"] = echo.family
        device.controls["alexaMembers"] = echo.members.joined(separator: ",")
        var parts: [String] = []
        if let volume {
            device.controls["volume"] = String(volume)
            device.controls["maxVolume"] = "100"
            parts.append("Volume \(volume)")
        }
        if let doNotDisturb {
            device.controls["dnd"] = doNotDisturb ? "1" : "0"
            if doNotDisturb { parts.append(tr("Não perturbe")) }
        }
        device.detail = parts.joined(separator: " · ")
        return device
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        throw ProviderError.unsupported
    }
}

extension HomeDevice {
    /// An Echo, as the Alexa client takes it.
    public var echo: AlexaDevice? {
        guard provider == .alexa, let type = controls["alexaType"] else { return nil }
        let members = controls["alexaMembers"].map { $0.split(separator: ",").map(String.init) } ?? [rawID]
        return AlexaDevice(serial: rawID, type: type, name: name, family: controls["alexaFamily"] ?? "", online: isOnline,
                           members: members.isEmpty ? [rawID] : members)
    }
}

extension HomeStore {
    /// The Alexa account's client, when signed in.
    public var alexa: AlexaClient? { (provider(.alexa) as? AlexaProvider)?.client }

    /// The Echos in the list (online ones), for announcements.
    public var echos: [AlexaDevice] { devices.compactMap(\.echo).filter(\.online) }

    /// Says it on every Echo at once (the intercom ringing, the washer done); quietly nothing without the account.
    public func announceOnEchos(_ text: String, title: String = "Lar") {
        guard let alexa, !echos.isEmpty else { return }
        let targets = echos
        Task { try? await alexa.announce(text, title: title, on: targets) }
    }
}
