import Foundation

/// Every Android TV / Google TV on the local network, through each one's ADB (debugging on, port 5555): whether it's
/// awake, what's on screen, power, remote keys and opening apps.
///
/// TVs are found by themselves (TVDiscovery, every refresh, so a new TV or a new address is picked up) plus any
/// address typed in Settings. Each TV is known by its serial number, never by its address, and TVs seen before are
/// remembered, so one that's off the network shows as offline instead of vanishing. A TV that hasn't let the Mac in
/// yet asks "Allow USB debugging?" on its screen.
public actor AndroidTVProvider: DeviceProvider {
    public nonisolated let provider = Provider.androidTV

    /// A TV seen before: its serial (the device's id), name and last address.
    public struct KnownTV: Codable, Sendable, Equatable {
        public var serial: String
        public var name: String
        public var host: String
        /// The network card's address, for waking it from standby (Wake-on-LAN).
        public var mac: String?

        public init(serial: String, name: String, host: String, mac: String? = nil) {
            self.serial = serial
            self.name = name
            self.host = host
            self.mac = mac
        }
    }

    private let manualHosts: [String]
    private let discover: @Sendable () async -> [TVDiscovery.Found]
    private let makeKey: @Sendable () throws -> ADBKey
    private let remember: @Sendable ([KnownTV]) -> Void
    private var known: [String: KnownTV]
    private var clients: [String: ADBClient] = [:]
    private var key: ADBKey?

    public init(
        manualHosts: [String] = [],
        known: [KnownTV] = [],
        discover: @escaping @Sendable () async -> [TVDiscovery.Found] = { await TVDiscovery.scan() },
        makeKey: @escaping @Sendable () throws -> ADBKey = { try ADBKey.loadOrCreate() },
        remember: @escaping @Sendable ([KnownTV]) -> Void = { _ in }
    ) {
        self.manualHosts = manualHosts
        self.discover = discover
        self.makeKey = makeKey
        self.remember = remember
        self.known = Dictionary(known.map { ($0.serial, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Devices

    public func devices() async throws -> [HomeDevice] {
        let found = await discover()
        var targets: [(host: String, name: String?)] = found.map { ($0.host, $0.name) }
        for host in manualHosts where !targets.contains(where: { $0.host == host }) { targets.append((host, nil)) }

        var out: [HomeDevice] = []
        await withTaskGroup(of: HomeDevice.self) { group in
            for target in targets {
                group.addTask { await self.read(host: target.host, advertisedName: target.name) }
            }
            for await device in group { out.append(device) }
        }

        // Remember what answered; show the rest of what's known as offline.
        var changed = false
        for device in out where device.isOnline && device.controls["serial"] != nil {
            let tv = KnownTV(serial: device.rawID, name: device.name, host: device.controls["host"] ?? "",
                             mac: device.controls["mac"] ?? known[device.rawID]?.mac)
            if known[tv.serial] != tv {
                known[tv.serial] = tv
                changed = true
            }
        }
        if changed { remember(Array(known.values)) }
        let present = Set(out.map(\.rawID))
        let presentHosts = Set(out.compactMap { $0.controls["host"] })
        for tv in known.values where !present.contains(tv.serial) && !presentHosts.contains(tv.host) {
            var device = HomeDevice(provider: .androidTV, rawID: tv.serial, name: tv.name, kind: .tv, isOnline: false, isOn: false)
            device.controls["host"] = tv.host
            if let mac = tv.mac { device.controls["mac"] = mac }
            device.detail = "Desligada ou fora da rede"
            out.append(device)
        }
        return out
    }

    /// One TV's state; a TV that doesn't let the Mac in comes back offline, saying why.
    private func read(host: String, advertisedName: String?) async -> HomeDevice {
        do {
            let output = try await shell(
                "echo \"name=$(settings get global device_name)\"; echo \"serial=$(getprop ro.serialno)\"; "
                    + "dumpsys power | grep -m1 mWakefulness=; dumpsys activity activities | grep -m1 mResumedActivity; "
                    + "ip addr show eth0 2>/dev/null | grep -m1 link/ether; ip addr show wlan0 2>/dev/null | grep -m1 link/ether",
                host: host
            )
            return Self.device(fromStatus: output, host: host, fallbackName: advertisedName)
        } catch {
            let serial = known.values.first { $0.host == host }?.serial
            var device = HomeDevice(
                provider: .androidTV, rawID: serial ?? host, name: advertisedName ?? known[serial ?? ""]?.name ?? "TV",
                kind: .tv, isOnline: false
            )
            device.controls["host"] = host
            if let mac = known[serial ?? ""]?.mac { device.controls["mac"] = mac }
            device.detail = (error as? ProviderError)?.message ?? "Sem resposta"
            return device
        }
    }

    /// Reads "name=…", "serial=…", "mWakefulness=Awake" and the resumed activity's package.
    static func device(fromStatus output: String, host: String, fallbackName: String? = nil) -> HomeDevice {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
                .flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        }
        let serial = value("serial")
        let awake = lines.contains { $0.contains("mWakefulness=Awake") }
        let package = lines.first { $0.contains("mResumedActivity") }.flatMap(Self.package(inActivityLine:))
        var device = HomeDevice(
            provider: .androidTV, rawID: serial ?? host, name: value("name") ?? fallbackName ?? "TV", kind: .tv, isOn: awake
        )
        device.controls["host"] = host
        device.controls["app"] = package ?? ""
        if let serial { device.controls["serial"] = serial }
        // The first card with an address: the cable's when there is one, then Wi-Fi's.
        if let ether = lines.first(where: { $0.hasPrefix("link/ether ") }) {
            let mac = ether.split(separator: " ")[1]
            if mac != "00:00:00:00:00:00" { device.controls["mac"] = String(mac) }
        }
        device.detail = awake ? package.map(Self.appName) ?? "" : "Em repouso"
        return device
    }

    /// "ActivityRecord{5abc941 u0 com.netflix.ninja/.MainActivity t11}" → "com.netflix.ninja".
    static func package(inActivityLine line: String) -> String? {
        guard let slash = line.firstIndex(of: "/") else { return nil }
        let before = line[..<slash]
        guard let space = before.lastIndex(of: " ") else { return nil }
        return String(before[before.index(after: space)...])
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command else { throw ProviderError.unsupported }
        let host = try host(of: device)
        if on {
            // Awake on the network: WAKEUP. In standby the TV may have dropped off the network: Wake-on-LAN first.
            if !device.isOnline, let mac = device.controls["mac"] {
                WakeOnLAN.send(mac: mac, host: host)
                try? await Task.sleep(for: .seconds(6))
            }
            do {
                _ = try await shell("input keyevent 224", host: host)
            } catch {
                throw ProviderError.api("A TV não ligou pela rede; ligue pelo controle")
            }
        } else {
            // KEYCODE_SLEEP is ignored by some TVs (MediaTek); POWER toggles, so only when it's awake.
            let state = try await shell("dumpsys power | grep -m1 mWakefulness=", host: host)
            if state.contains("Awake") { _ = try await shell("input keyevent 26", host: host) }
        }
    }

    // MARK: Remote

    public enum Key: Int, Sendable, CaseIterable {
        case up = 19, down = 20, left = 21, right = 22, select = 23, back = 4, home = 3
        case playPause = 85, volumeUp = 24, volumeDown = 25, mute = 164, inputs = 178
    }

    public func press(_ key: Key, on device: HomeDevice) async throws {
        _ = try await shell("input keyevent \(key.rawValue)", host: try host(of: device))
    }

    public struct App: Sendable, Equatable, Identifiable {
        public var package: String
        public var name: String
        public var id: String { package }
    }

    /// The apps on the TV's launcher, the well-known ones first.
    public func apps(on device: HomeDevice) async throws -> [App] {
        let output = try await shell(
            "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER",
            host: try host(of: device)
        )
        return Self.apps(fromQuery: output)
    }

    static func apps(fromQuery output: String) -> [App] {
        var seen = Set<String>()
        let packages = output.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let slash = text.firstIndex(of: "/"), !text.contains(" ") else { return nil }
            let package = String(text[..<slash])
            return Self.hidden.contains(package) || !seen.insert(package).inserted ? nil : package
        }
        let known = Self.names.keys
        return packages.map { App(package: $0, name: appName($0)) }.sorted { a, b in
            let ka = known.contains(a.package), kb = known.contains(b.package)
            return ka != kb ? ka : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func openApp(_ package: String, on device: HomeDevice) async throws {
        guard package.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else {
            throw ProviderError.unsupported
        }
        _ = try await shell("monkey -p \(package) -c android.intent.category.LEANBACK_LAUNCHER 1", host: try host(of: device))
    }

    static let names: [String: String] = [
        "com.netflix.ninja": "Netflix", "com.google.android.youtube.tv": "YouTube",
        "com.amazon.amazonvideo.livingroom": "Prime Video", "com.stremio.one": "Stremio",
        "com.apple.atve.androidtv.appletv": "Apple TV", "com.globo.globotv": "Globoplay",
        "com.crunchyroll.crunchyroid": "Crunchyroll", "com.wbd.stream": "Max", "com.disney.disneyplus": "Disney+",
        "com.spotify.tv.android": "Spotify", "com.apple.android.music": "Apple Music",
        "com.mediatek.wwtv.tvcenter": "TV ao vivo", "io.freemytv": "Início", "com.google.android.tvlauncher": "Início",
        "com.google.android.apps.tv.launcherx": "Início", "com.xm.csee": "iCSee", "com.ionitech.airscreen": "AirScreen",
        "com.google.android.youtube.tvmusic": "YouTube Music", "com.cbs.ca": "Paramount+", "tunein.player": "TuneIn",
        "com.xcloud.app": "XCloudTV", "gamepass.fire.tv": "Xbox", "com.google.android.tv": "Google TV",
    ]

    /// Not apps anyone opens from a remote.
    static let hidden: Set = ["com.android.tv.settings", "com.google.android.tv.remote.service", "com.mediatek.wwtv.mediaplayer",
                              "com.airoha.btd", "com.android.vending", "io.freemytv", "com.google.android.tvlauncher"]

    public static func appName(_ package: String) -> String {
        if let name = names[package] { return name }
        // The most telling part of the name: "com.xcloud.app" → "Xcloud", "tv.pluto.android" → "Pluto".
        let generic: Set = ["app", "android", "tv", "mobile", "atv", "leanback", "com", "br", "launcher", "client"]
        let parts = package.split(separator: ".").map(String.init)
        let word = parts.last { !generic.contains($0.lowercased()) } ?? parts.last ?? package
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    // MARK: ADB

    private func host(of device: HomeDevice) throws -> String {
        guard let host = device.controls["host"], !host.isEmpty else { throw ProviderError.unsupported }
        return host
    }

    private func shell(_ command: String, host: String) async throws -> String {
        do {
            if key == nil { key = try makeKey() }
            let client = clients[host] ?? ADBClient(host: host, key: key!)
            clients[host] = client
            return try await client.shell(command)
        } catch let error as ADBError {
            throw ProviderError.api(error.message)
        }
    }
}
