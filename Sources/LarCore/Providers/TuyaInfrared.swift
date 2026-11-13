import Foundation

/// Smart Life's infrared remotes (an IR blaster, "Smart IR", with the remotes made in the Smart Life app, from its
/// library of brands or learned key by key): each one in the list as what it controls, a TV or box with the remote's
/// keys, an air conditioner with power and temperature, through Tuya's infrared API.
extension TuyaClient: TVRemoteProvider {
    /// Tuya's IR categories: what each remote controls.
    static func infraredKind(_ category: Int) -> DeviceKind {
        switch category {
        case 1, 2, 3, 4, 6: .tv
        case 5: .airConditioner
        case 7: .speaker
        case 8: .fan
        default: .other
        }
    }

    /// The list with the IR hubs' remotes marked (and added, when the list doesn't have them).
    func withInfrared(_ devices: [HomeDevice]) async -> [HomeDevice] {
        let hubs = devices.filter { $0.controls["tuyaCategory"] == "wnykq" || $0.controls["category"] == "wnykq" }
        guard !hubs.isEmpty else { return devices }
        var out = devices
        for hub in hubs {
            guard let remotes = try? await call("GET", "/v2.0/infrareds/\(hub.rawID)/remotes").array else { continue }
            for remote in remotes {
                guard let id = remote["remote_id"]?.string, let category = remote["category_id"]?.double.map(Int.init) else { continue }
                var device = out.first { $0.rawID == id }
                    ?? HomeDevice(provider: .tuya, rawID: id, name: remote["remote_name"]?.string ?? id, kind: .other, isOnline: hub.isOnline)
                device.kind = Self.infraredKind(category)
                device.controls["irHub"] = hub.rawID
                device.controls["irCategory"] = String(category)
                if device.kind == .airConditioner {
                    device.controls["ir"] = "ac"
                    // The remote's last state (what the Lar or the app sent): IR has no way back.
                    if let status = try? await call("GET", "/v2.0/infrareds/\(hub.rawID)/remotes/\(id)/ac/status") {
                        device.isOn = (status["power"]?.string ?? status["power"]?.double.map { String(Int($0)) }) == "1"
                        if let temp = status["temp"]?.string.flatMap(Double.init) ?? status["temp"]?.double {
                            device.controls["targetTemperature"] = HomeText.number(temp)
                        }
                    } else {
                        device.isOn = false
                    }
                    device.detail = device.isOn == true ? tr("Ligado por infravermelho") : tr("Infravermelho")
                } else {
                    device.controls["ir"] = "remote"
                    // Stateless: power is a key, so it shows as off and the switch sends Power.
                    device.isOn = false
                    device.detail = tr("Controle por infravermelho")
                }
                out.removeAll { $0.rawID == id }
                out.append(device)
            }
        }
        return out
    }

    /// The keys a remote has (from the brand's library, or learned).
    func keys(of device: HomeDevice) async throws -> (category: Int, keys: [(key: String, id: Int)]) {
        if let cached = infraredKeys[device.rawID] { return cached }
        guard let hub = device.controls["irHub"] else { throw ProviderError.unsupported }
        let answer = try await call("GET", "/v2.0/infrareds/\(hub)/remotes/\(device.rawID)/keys")
        let category = answer["category_id"]?.double.map(Int.init) ?? Int(device.controls["irCategory"] ?? "") ?? 2
        let keys = (answer["key_list"]?.array ?? []).compactMap { item -> (String, Int)? in
            guard let key = item["key"]?.string, let id = item["key_id"]?.double else { return nil }
            return (key, Int(id))
        }
        infraredKeys[device.rawID] = (category, keys)
        return (category, keys)
    }

    /// The remote's key for one of the Lar's (their names vary by brand: "Power", "power_on", "Vol+"…).
    static func infraredKey(_ key: AndroidTVProvider.Key?, power: Bool = false, in keys: [(key: String, id: Int)]) -> (key: String, id: Int)? {
        let wanted: [String]
        if power {
            wanted = ["power", "poweron", "onoff", "power_on"]
        } else {
            switch key {
            case .up?: wanted = ["up", "navup"]
            case .down?: wanted = ["down", "navdown"]
            case .left?: wanted = ["left", "navleft"]
            case .right?: wanted = ["right", "navright"]
            case .select?, .enter?: wanted = ["ok", "enter", "select", "confirm"]
            case .back?: wanted = ["back", "return", "exit"]
            case .home?: wanted = ["home", "menu"]
            case .playPause?: wanted = ["play", "playpause", "pause"]
            case .volumeUp?: wanted = ["volumeup", "volup", "vol", "volume"]
            case .volumeDown?: wanted = ["volumedown", "voldown", "vol-", "volume-"]
            case .mute?: wanted = ["mute"]
            case .inputs?: wanted = ["input", "source", "tvav", "av"]
            case .channelUp?: wanted = ["channelup", "chup", "ch", "channel"]
            case .channelDown?: wanted = ["channeldown", "chdown", "ch-", "channel-"]
            case nil: wanted = []
            }
        }
        func normalized(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "+", with: "up").replacingOccurrences(of: "-", with: "down")
                .filter { $0.isLetter || $0.isNumber }
        }
        let names = wanted.map(normalized)
        return names.lazy.compactMap { name in keys.first { normalized($0.key) == name } }.first
    }

    func sendKey(_ found: (key: String, id: Int), category: Int, to device: HomeDevice) async throws {
        guard let hub = device.controls["irHub"] else { throw ProviderError.unsupported }
        _ = try await call("POST", "/v2.0/infrareds/\(hub)/remotes/\(device.rawID)/command",
                           body: ["category_id": .number(Double(category)), "key_id": .number(Double(found.id)), "key": .string(found.key)])
    }

    func sendInfrared(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard let hub = device.controls["irHub"] else { throw ProviderError.unsupported }
        if device.controls["ir"] == "ac" {
            let path = "/v2.0/infrareds/\(hub)/air-conditioners/\(device.rawID)/command"
            switch command {
            case .power(let on): _ = try await call("POST", path, body: ["code": "power", "value": .number(on ? 1 : 0)])
            case .temperature(let value): _ = try await call("POST", path, body: ["code": "temp", "value": .number(value.rounded())])
            default: throw ProviderError.unsupported
            }
            return
        }
        guard case .power = command else { throw ProviderError.unsupported }
        let (category, keys) = try await keys(of: device)
        guard let power = Self.infraredKey(nil, power: true, in: keys) else { throw ProviderError.api(tr("Esse controle não tem a tecla Power")) }
        try await sendKey(power, category: category, to: device)
    }

    // MARK: TVRemoteProvider (the IR remotes)

    public func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {
        let (category, keys) = try await keys(of: device)
        guard let found = Self.infraredKey(key, in: keys) else { throw ProviderError.api(tr("Esse controle não tem essa tecla")) }
        try await sendKey(found, category: category, to: device)
    }

    public func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] { [] }

    public func openApp(_ package: String, on device: HomeDevice) async throws { throw ProviderError.unsupported }

    public func type(_ text: String, on device: HomeDevice) async throws { throw ProviderError.unsupported }
}
