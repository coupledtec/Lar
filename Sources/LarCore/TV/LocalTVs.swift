import Foundation

/// LG (webOS) and Samsung (Tizen) TVs controlled directly on the home network: the full remote, apps, inputs, text
/// and power, beyond what their clouds (ThinQ, SmartThings) offer. Each one paired once with a prompt on the TV.
public struct LocalTV: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case lg, samsung

        public var provider: Provider { self == .lg ? .lgTV : .samsungTV }
        public var name: String { self == .lg ? tr("TV LG (webOS)") : tr("TV Samsung (Tizen)") }
    }

    public var kind: Kind
    public var host: String
    public var name: String
    /// LG's client key or Samsung's token: the TV's permission (kept in the keychain).
    public var key: String?
    /// For waking it from standby.
    public var mac: String?
    /// The device in the list it gives its remote to (the LG TV from ThinQ, the Samsung from SmartThings): then it
    /// doesn't show twice.
    public var linkedDeviceID: String?

    public var id: String { "\(kind.rawValue):\(host)" }

    public init(kind: Kind, host: String, name: String, key: String? = nil, mac: String? = nil, linkedDeviceID: String? = nil) {
        self.linkedDeviceID = linkedDeviceID
        self.kind = kind
        self.host = host
        self.name = name
        self.key = key
        self.mac = mac
    }
}

extension AppSettings {
    /// The paired LG and Samsung TVs (one keychain item: their keys are secrets).
    public static var localTVs: [LocalTV] {
        get { Keychain.read("local-tvs").flatMap { try? JSONDecoder().decode([LocalTV].self, from: Data($0.utf8)) } ?? [] }
        set {
            if newValue.isEmpty {
                Keychain.delete("local-tvs")
            } else if let data = try? JSONEncoder().encode(newValue) {
                Keychain.write(String(decoding: data, as: UTF8.self), account: "local-tvs", label: "Lar – TVs LG e Samsung")
            }
        }
    }
}

/// The connections to the paired TVs, kept between reads and commands (a WebSocket each).
actor LocalTVConnections {
    static let shared = LocalTVConnections()
    private var lg: [String: LGWebOSClient] = [:]
    private var samsung: [String: SamsungTVClient] = [:]
    /// Play and pause alternate (neither TV has one toggle key).
    private var playing: [String: Bool] = [:]

    func lgClient(_ tv: LocalTV) -> LGWebOSClient {
        if let client = lg[tv.id] { return client }
        let client = LGWebOSClient(host: tv.host, clientKey: tv.key)
        lg[tv.id] = client
        return client
    }

    func samsungClient(_ tv: LocalTV) -> SamsungTVClient {
        if let client = samsung[tv.id] { return client }
        let client = SamsungTVClient(host: tv.host, token: tv.key)
        samsung[tv.id] = client
        return client
    }

    func togglePlaying(_ id: String) -> Bool {
        let now = !(playing[id] ?? true)
        playing[id] = now
        return now
    }
}

public enum LocalTVs {
    /// Pairs with a TV: the owner accepts on its screen. Returns it with its key, name and MAC, saved.
    public static func pair(_ kind: LocalTV.Kind, host: String, linkedTo deviceID: String? = nil) async throws -> LocalTV {
        let host = host.trimmingCharacters(in: .whitespaces)
        var tv = LocalTV(kind: kind, host: host, name: kind == .lg ? "TV LG" : "TV Samsung", linkedDeviceID: deviceID)
        switch kind {
        case .lg:
            let client = LGWebOSClient(host: host, clientKey: nil)
            tv.key = try await client.connect()
            if let info = try? await client.request("system/getSystemInfo"), let model = info["modelName"]?.string { tv.name = "TV LG \(model)" }
            if let network = try? await client.request("com.webos.service.connectionmanager/getinfo") {
                tv.mac = network["wiredInfo"]?["macAddress"]?.string ?? network["wifiInfo"]?["macAddress"]?.string
            }
            await client.close()
        case .samsung:
            let client = SamsungTVClient(host: host, token: nil)
            tv.key = try await client.connect()
            let info = await SamsungTVClient.info(host: host)
            if let name = info.name { tv.name = name }
            tv.mac = info.mac
            await client.close()
        }
        var all = AppSettings.localTVs.filter { $0.id != tv.id && (deviceID == nil || $0.linkedDeviceID != deviceID) }
        all.append(tv)
        AppSettings.localTVs = all
        return tv
    }

    public static func forget(_ tv: LocalTV) {
        AppSettings.localTVs = AppSettings.localTVs.filter { $0.id != tv.id }
    }

    /// Wake-on-LAN: the magic packet to the whole network (the Mac; the iPhone needs Apple's permission for
    /// broadcasts, so it's tried and may not reach).
    static func wake(mac: String) {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count == 12, let bytes = Data(hex: hex) else { return }
        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(bytes) }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return }
        defer { close(socket) }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = INADDR_BROADCAST
        _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    #if os(macOS)
    /// The LG and Samsung TVs answering SSDP on the network, by address (the Mac only, like the other broadcasts).
    public static func discover() async -> [String: LocalTV.Kind] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard socket >= 0 else { return continuation.resume(returning: [:]) }
                defer { close(socket) }
                var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(1900).bigEndian
                inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
                for target in ["urn:lge-com:service:webos-second-screen:1", "urn:samsung.com:device:RemoteControlReceiver:1"] {
                    let message = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n".utf8)
                    _ = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socket, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                var found: [String: LocalTV.Kind] = [:]
                let end = Date().addingTimeInterval(2.5)
                var buffer = [UInt8](repeating: 0, count: 4096)
                while Date() < end {
                    var from = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = withUnsafeMutablePointer(to: &from) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
                    }
                    guard count > 0 else { continue }
                    let text = String(decoding: buffer[0..<count], as: UTF8.self).lowercased()
                    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &from.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: host)
                    if text.contains("lge") || text.contains("webos") { found[ip] = .lg }
                    else if text.contains("samsung") { found[ip] = .samsung }
                }
                continuation.resume(returning: found)
            }
        }
    }
    #endif
}

/// The paired TVs of one brand in the list, with the full remote.
public struct LocalTVProvider: TVRemoteProvider {
    public let provider: Provider
    let tvs: [LocalTV]

    public init(kind: LocalTV.Kind, tvs: [LocalTV]) {
        provider = kind.provider
        self.tvs = tvs.filter { $0.kind == kind }
    }

    /// The remote of a device in the list that a paired TV is linked to.
    public static func linked(to device: HomeDevice) -> LocalTVProvider? {
        let tvs = AppSettings.localTVs
        guard let tv = tvs.first(where: { $0.linkedDeviceID == device.id }) else { return nil }
        return LocalTVProvider(kind: tv.kind, tvs: tvs)
    }

    public func devices() async throws -> [HomeDevice] {
        await withTaskGroup(of: HomeDevice.self) { group in
            // The linked ones show as their account's device.
            for tv in tvs where tv.linkedDeviceID == nil { group.addTask { await Self.device(tv) } }
            var out: [HomeDevice] = []
            for await device in group { out.append(device) }
            return out.sorted { $0.name < $1.name }
        }
    }

    static func device(_ tv: LocalTV) async -> HomeDevice {
        var isOn = false
        var reachable = false
        var detail = ""
        switch tv.kind {
        case .lg:
            let client = await LocalTVConnections.shared.lgClient(tv)
            if let power = try? await client.request("com.webos.service.tvpower/power/getPowerState") {
                reachable = true
                let state = power["state"]?.string ?? "Active"
                isOn = state == "Active"
                if isOn, let app = try? await client.foregroundApp() {
                    detail = (try? await client.apps())?.first { $0.id == app }?.title ?? app
                }
            }
        case .samsung:
            if let state = await SamsungTVClient.powerState(host: tv.host) {
                reachable = true
                isOn = state == "on"
            }
        }
        // A TV that can be woken stays in the list (off) when it doesn't answer.
        return HomeDevice(provider: tv.kind.provider, rawID: tv.id, name: tv.name, kind: .tv,
                          isOnline: reachable || tv.mac != nil, isOn: isOn,
                          detail: detail.isEmpty ? (isOn ? tr("Ligada") : tr("Desligada")) : detail,
                          controls: ["localTV": tv.kind.rawValue])
    }

    private func tv(_ device: HomeDevice) throws -> LocalTV {
        guard let tv = tvs.first(where: { $0.id == device.rawID || $0.linkedDeviceID == device.id }) else { throw ProviderError.unsupported }
        return tv
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command else { throw ProviderError.unsupported }
        let tv = try tv(device)
        if on {
            if let mac = tv.mac { LocalTVs.wake(mac: mac) }
            // An LG in quick start answers while "off": it turns on by request.
            if tv.kind == .lg { try? await LocalTVConnections.shared.lgClient(tv).request("system/turnOn") }
            return
        }
        switch tv.kind {
        case .lg: try await LocalTVConnections.shared.lgClient(tv).turnOff()
        case .samsung: try await LocalTVConnections.shared.samsungClient(tv).key("KEY_POWER")
        }
    }

    public func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {
        let tv = try tv(device)
        switch tv.kind {
        case .lg:
            let client = await LocalTVConnections.shared.lgClient(tv)
            if key == .playPause {
                try await client.button(await LocalTVConnections.shared.togglePlaying(tv.id) ? "PLAY" : "PAUSE")
            } else {
                try await client.button(LGWebOSClient.buttonName(key))
            }
        case .samsung:
            let client = await LocalTVConnections.shared.samsungClient(tv)
            if key == .playPause {
                try await client.key(await LocalTVConnections.shared.togglePlaying(tv.id) ? "KEY_PLAY" : "KEY_PAUSE")
            } else {
                try await client.key(SamsungTVClient.keyName(key))
            }
        }
    }

    public func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] {
        let tv = try tv(device)
        switch tv.kind {
        case .lg:
            let client = await LocalTVConnections.shared.lgClient(tv)
            let inputs = (try? await client.inputs()) ?? []
            return (inputs + (try await client.apps())).map { AndroidTVProvider.App(package: $0.id, name: $0.title) }
        case .samsung:
            return try await LocalTVConnections.shared.samsungClient(tv).apps().map { AndroidTVProvider.App(package: $0.id, name: $0.name) }
        }
    }

    public func openApp(_ package: String, on device: HomeDevice) async throws {
        let tv = try tv(device)
        switch tv.kind {
        case .lg: try await LocalTVConnections.shared.lgClient(tv).open(package)
        case .samsung: try await LocalTVConnections.shared.samsungClient(tv).open(package)
        }
    }

    public func type(_ text: String, on device: HomeDevice) async throws {
        let tv = try tv(device)
        switch tv.kind {
        case .lg: try await LocalTVConnections.shared.lgClient(tv).type(text)
        case .samsung: try await LocalTVConnections.shared.samsungClient(tv).type(text)
        }
    }
}
