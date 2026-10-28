import Foundation

/// Every Android TV / Google TV on the local network: whether it's awake, what's on screen, power, remote keys and
/// opening apps. Two ways in, per TV:
/// - the Google TV remote protocol (TVRemoteClient), once the TV is paired with the code it shows: nothing to turn
///   on in the TV, and the iPhone's way;
/// - ADB (debugging on, port 5555), when allowed (the Mac): also lists the TV's apps. A TV that hasn't let the Mac
///   in yet asks "Allow USB debugging?" on its screen.
///
/// TVs are found by themselves (TVDiscovery, every refresh, so a new TV or a new address is picked up) plus any
/// address typed in Settings. Each TV is known by its serial number, never by its address, and TVs seen before are
/// remembered, so one that's off the network shows as offline instead of vanishing.
public actor AndroidTVProvider: TVRemoteProvider {
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
    private let useADB: Bool
    private let makeIdentity: @Sendable () throws -> TVRemoteIdentity
    private let makePairingIdentity: @Sendable () throws -> TVRemoteIdentity
    private let rememberPaired: @Sendable ([String]) -> Void
    private let clientName: String
    private let probe: @Sendable (String, UInt16) async -> Bool
    /// The TVs paired with the remote protocol, by their advertised name (or address, for one typed by hand).
    private var paired: Set<String>
    /// Each paired TV's certificate (SHA-256), pinned at the first connection after pairing.
    private var pins: [String: String]
    private let rememberPins: @Sendable ([String: String]) -> Void
    private var remotes: [String: TVRemoteClient] = [:]
    private var pairings: [String: TVRemotePairing] = [:]
    private var identity: TVRemoteIdentity?

    /// - Parameters:
    ///   - probe: whether a port answers at all, to tell a TV that's on (but not reachable by ADB) from one that's off.
    ///   - useADB: try ADB for TVs not paired with the remote protocol (off on the iPhone).
    ///   - paired: TVs paired with the remote protocol; `rememberPaired` saves the list when it changes.
    ///   - clientName: how this device shows on the TV while pairing.
    ///   - pins: the paired TVs' pinned certificates; `rememberPins` saves them when they change.
    public init(
        manualHosts: [String] = [],
        known: [KnownTV] = [],
        discover: @escaping @Sendable () async -> [TVDiscovery.Found] = { await TVDiscovery.scan() },
        makeKey: @escaping @Sendable () throws -> ADBKey = { try ADBKey.loadOrCreate() },
        remember: @escaping @Sendable ([KnownTV]) -> Void = { _ in },
        useADB: Bool = true,
        paired: [String] = [],
        makeIdentity: @escaping @Sendable () throws -> TVRemoteIdentity = { try TVRemoteIdentity.loadOrCreate() },
        makePairingIdentity: @escaping @Sendable () throws -> TVRemoteIdentity = {
            try TVRemoteIdentity.loadOrCreate(allowReplacing: true)
        },
        rememberPaired: @escaping @Sendable ([String]) -> Void = { _ in },
        clientName: String = "Lar",
        pins: [String: String] = [:],
        rememberPins: @escaping @Sendable ([String: String]) -> Void = { _ in },
        probe: @escaping @Sendable (String, UInt16) async -> Bool = { await TVDiscovery.answers(host: $0, port: $1) }
    ) {
        self.probe = probe
        self.pins = pins
        self.rememberPins = rememberPins
        self.manualHosts = manualHosts
        self.discover = discover
        self.makeKey = makeKey
        self.remember = remember
        self.known = Dictionary(known.map { ($0.serial, $0) }, uniquingKeysWith: { _, last in last })
        self.useADB = useADB
        self.paired = Set(paired)
        self.makeIdentity = makeIdentity
        self.makePairingIdentity = makePairingIdentity
        self.rememberPaired = rememberPaired
        self.clientName = clientName
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
            device.controls["pairingKey"] = tv.name
            if paired.contains(tv.name) { device.controls["link"] = "remote" }
            device.detail = tr("Desligada ou fora da rede")
            out.append(device)
        }
        return out
    }

    /// One TV's state, by the remote protocol when paired, else by ADB when allowed. A TV that doesn't let this device
    /// in comes back offline, saying why; one that could be paired says so in `controls["pairable"]`.
    private func read(host: String, advertisedName: String?) async -> HomeDevice {
        let pairingKey = advertisedName ?? host
        if paired.contains(pairingKey) {
            do {
                return try await readRemote(host: host, name: advertisedName, pairingKey: pairingKey)
            } catch TVRemoteError.notPaired {
                // The TV forgot this device (reset, or removed from its list): offer pairing again.
                forgetPairing(pairingKey)
            } catch {
                // Paired but silent: off (in standby it leaves the network). Still worth a try to switch on.
                let detail = (error as? TVRemoteError).flatMap { if case .identity = $0 { $0.message } else { nil } }
                var device = offline(host: host, advertisedName: advertisedName, pairingKey: pairingKey,
                                     detail: detail ?? tr("Desligada ou fora da rede"))
                device.isOn = false
                device.controls["link"] = "remote"
                return device
            }
        }
        if useADB {
            var device = await readADB(host: host, advertisedName: advertisedName)
            device.controls["pairingKey"] = pairingKey
            device.controls["pairable"] = "1"
            if device.isOnline { return device }
            // No ADB (debugging off, not approved): on all the same when its remote port answers, and pairable.
            guard await reachable(host) else { return device }
            return pairable(device, detail: tr("Sem ADB: pareie com o código da TV"))
        }
        let device = offline(host: host, advertisedName: advertisedName, pairingKey: pairingKey, detail: tr("Desligada ou fora da rede"))
        // The network may still advertise a TV gone to standby: only one that answers can be paired.
        guard await reachable(host) else { return device }
        return pairable(device, detail: tr("Pareie com o código da TV"))
    }

    /// A TV that's on but not reachable yet: no switch (its state is unknown) until it's paired.
    private func pairable(_ device: HomeDevice, detail: String) -> HomeDevice {
        var device = device
        device.isOnline = true
        device.isOn = nil
        device.detail = detail
        device.controls["pairable"] = "1"
        return device
    }

    private func reachable(_ host: String) async -> Bool {
        await probe(host, TVRemoteProtocol.remotePort)
    }

    private func readRemote(host: String, name: String?, pairingKey: String) async throws -> HomeDevice {
        let state = try await remote(host, key: pairingKey).currentState()
        let saved = known.values.first { $0.host == host || $0.name == pairingKey }
        let isOn = state.isOn ?? true
        var device = HomeDevice(provider: .androidTV, rawID: saved?.serial ?? pairingKey,
                                name: saved?.name ?? name ?? "TV", kind: .tv, isOn: isOn)
        device.controls["host"] = host
        device.controls["serial"] = device.rawID
        device.controls["link"] = "remote"
        device.controls["pairingKey"] = pairingKey
        device.controls["app"] = state.app ?? ""
        if let volume = state.volume, let max = state.maxVolume, max > 0 {
            device.controls["volume"] = state.isMuted ? "0" : String(volume)
            device.controls["maxVolume"] = String(max)
        }
        if let mac = saved?.mac { device.controls["mac"] = mac }
        device.detail = isOn ? state.app.map(Self.appName) ?? "" : tr("Em repouso")
        return device
    }

    private func offline(host: String, advertisedName: String?, pairingKey: String, detail: String) -> HomeDevice {
        let serial = known.values.first { $0.host == host }?.serial
        var device = HomeDevice(
            provider: .androidTV, rawID: serial ?? pairingKey, name: advertisedName ?? known[serial ?? ""]?.name ?? "TV",
            kind: .tv, isOnline: false
        )
        device.controls["host"] = host
        device.controls["pairingKey"] = pairingKey
        if let mac = known[serial ?? ""]?.mac { device.controls["mac"] = mac }
        device.detail = detail
        return device
    }

    private func readADB(host: String, advertisedName: String?) async -> HomeDevice {
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
        device.detail = awake ? package.map(Self.appName) ?? "" : tr("Em repouso")
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
        if isRemote(device) {
            if on, !device.isOnline, let mac = device.controls["mac"] {
                WakeOnLAN.send(mac: mac, host: host)
                try? await Task.sleep(for: .seconds(6))
            }
            // POWER toggles: only when the TV isn't already as asked.
            do {
                try await remoteCall(device) { client in
                    if try await client.currentState().isOn != on { try await client.press(keyCode: 26) }
                }
            } catch where on && !device.isOnline {
                throw ProviderError.api(tr("A TV não ligou pela rede; ligue pelo controle"))
            }
            return
        }
        if on {
            // Awake on the network: WAKEUP. In standby the TV may have dropped off the network: Wake-on-LAN first.
            if !device.isOnline, let mac = device.controls["mac"] {
                WakeOnLAN.send(mac: mac, host: host)
                try? await Task.sleep(for: .seconds(6))
            }
            do {
                _ = try await shell("input keyevent 224", host: host)
            } catch {
                throw ProviderError.api(tr("A TV não ligou pela rede; ligue pelo controle"))
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
        case channelUp = 166, channelDown = 167
    }

    public func press(_ key: Key, on device: HomeDevice) async throws {
        if isRemote(device) {
            return try await remoteCall(device) { try await $0.press(keyCode: key.rawValue) }
        }
        _ = try await shell("input keyevent \(key.rawValue)", host: try host(of: device))
    }

    /// Types into the TV's focused field (its keyboard open, e.g. a search).
    public func type(_ text: String, on device: HomeDevice) async throws {
        guard !text.isEmpty else { return }
        if isRemote(device) {
            return try await remoteCall(device) { try await $0.type(text) }
        }
        _ = try await shell("input text \(Self.shellText(text))", host: try host(of: device))
    }

    /// `input text` takes %s for spaces; the rest goes single-quoted for the shell.
    static func shellText(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: " ", with: "%s")
        return "'" + spaced.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public struct App: Sendable, Equatable, Identifiable, Codable {
        public var package: String
        public var name: String
        public var id: String { package }
    }

    /// The apps on the TV's launcher, the well-known ones first.
    public func apps(on device: HomeDevice) async throws -> [App] {
        if isRemote(device) {
            // The remote protocol can't list apps: ADB's list when it answers, else the common ones.
            if useADB, let adb = try? await adbApps(on: device) { return adb }
            return Self.commonApps(current: device.controls["app"])
        }
        return try await adbApps(on: device)
    }

    private func adbApps(on device: HomeDevice) async throws -> [App] {
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
        if isRemote(device) {
            return try await remoteCall(device) { try await $0.open(link: Self.link(forApp: package)) }
        }
        _ = try await shell("monkey -p \(package) -c android.intent.category.LEANBACK_LAUNCHER 1", host: try host(of: device))
    }

    static let names: [String: String] = [
        "com.netflix.ninja": "Netflix", "com.google.android.youtube.tv": "YouTube",
        "com.amazon.amazonvideo.livingroom": "Prime Video", "com.stremio.one": "Stremio",
        "com.apple.atve.androidtv.appletv": "Apple TV", "com.globo.globotv": "Globoplay",
        "com.crunchyroll.crunchyroid": "Crunchyroll", "com.wbd.stream": "Max", "com.disney.disneyplus": "Disney+",
        "com.spotify.tv.android": "Spotify", "com.apple.android.music": "Apple Music",
        "com.mediatek.wwtv.tvcenter": "TV ao vivo", "com.google.android.tvlauncher": "Início",
        "com.google.android.apps.tv.launcherx": "Início", "com.xm.csee": "iCSee", "com.ionitech.airscreen": "AirScreen",
        "com.google.android.youtube.tvmusic": "YouTube Music", "com.cbs.ca": "Paramount+", "tunein.player": "TuneIn",
        "com.xcloud.app": "XCloudTV", "gamepass.fire.tv": "Xbox", "com.google.android.tv": "Google TV",
    ]

    /// Not apps anyone opens from a remote.
    static let hidden: Set = ["com.android.tv.settings", "com.google.android.tv.remote.service", "com.mediatek.wwtv.mediaplayer",
                              "com.airoha.btd", "com.android.vending", "com.google.android.tvlauncher"]

    /// The apps most TVs have, for a TV whose list can't be read; the one on screen too, when it's not among them.
    static func commonApps(current: String?) -> [App] {
        let packages = ["com.netflix.ninja", "com.google.android.youtube.tv", "com.amazon.amazonvideo.livingroom",
                        "com.disney.disneyplus", "com.wbd.stream", "com.globo.globotv", "com.apple.atve.androidtv.appletv",
                        "com.spotify.tv.android", "com.google.android.youtube.tvmusic"]
        var apps = packages.map { App(package: $0, name: appName($0)) }
        if let current, !current.isEmpty, !packages.contains(current), !hidden.contains(current) {
            apps.insert(App(package: current, name: appName(current)), at: 0)
        }
        return apps
    }

    /// How the remote protocol opens an app: the web address the big apps claim, else the Play Store's link, which
    /// opens any installed app by package.
    static func link(forApp package: String) -> String {
        let links = [
            "com.netflix.ninja": "https://www.netflix.com/title", "com.google.android.youtube.tv": "https://www.youtube.com",
            "com.amazon.amazonvideo.livingroom": "https://app.primevideo.com", "com.disney.disneyplus": "https://www.disneyplus.com",
        ]
        return links[package] ?? "market://launch?id=\(package)"
    }

    public static func appName(_ package: String) -> String {
        if let name = names[package] { return name }
        // The most telling part of the name: "com.xcloud.app" → "Xcloud", "tv.pluto.android" → "Pluto".
        let generic: Set = ["app", "android", "tv", "mobile", "atv", "leanback", "com", "br", "launcher", "client"]
        let parts = package.split(separator: ".").map(String.init)
        let word = parts.last { !generic.contains($0.lowercased()) } ?? parts.last ?? package
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    // MARK: Pairing

    /// Makes the TV show its pairing code (6 symbols), to be typed into `finishPairing`.
    public func startPairing(_ device: HomeDevice) async throws {
        let host = try host(of: device)
        await pairings[host]?.cancel()
        do {
            if identity == nil { identity = try makePairingIdentity() }
            let pairing = TVRemotePairing(host: host, identity: identity!, clientName: clientName)
            pairings[host] = pairing
            try await pairing.start()
        } catch let error as TVRemoteError {
            pairings[host] = nil
            throw ProviderError.api(error.message)
        }
    }

    /// Sends the code; from then on the TV is used through the remote protocol.
    public func finishPairing(_ device: HomeDevice, code: String) async throws {
        let host = try host(of: device)
        guard let pairing = pairings[host] else { throw ProviderError.api(tr("Comece o pareamento de novo")) }
        do {
            try await pairing.finish(code: code)
        } catch let error as TVRemoteError {
            // A wrong code typed twice: the TV keeps showing it, so the same session can take another try.
            if error != .wrongCode { pairings[host] = nil }
            throw ProviderError.api(error.message)
        }
        pairings[host] = nil
        let key = device.controls["pairingKey"] ?? host
        paired.insert(key)
        rememberPaired(paired.sorted())
        // A new pairing pins the TV's certificate again, on the next connection.
        if pins.removeValue(forKey: key) != nil { rememberPins(pins) }
        await remotes.removeValue(forKey: host)?.close()
    }

    public func cancelPairing(_ device: HomeDevice) async {
        guard let host = device.controls["host"] else { return }
        await pairings[host]?.cancel()
        pairings[host] = nil
    }

    private func forgetPairing(_ key: String) {
        guard paired.remove(key) != nil else { return }
        rememberPaired(paired.sorted())
        if pins.removeValue(forKey: key) != nil { rememberPins(pins) }
    }

    // MARK: Remote protocol

    private func isRemote(_ device: HomeDevice) -> Bool {
        device.controls["link"] == "remote" || paired.contains(device.controls["pairingKey"] ?? "")
    }

    private func remote(_ host: String, key: String) throws -> TVRemoteClient {
        if let client = remotes[host] { return client }
        if identity == nil { identity = try makeIdentity() }
        let client = TVRemoteClient(host: host, identity: identity!, model: clientName, pin: pins[key]) { [weak self] pin in
            Task { await self?.savePin(pin, for: key) }
        }
        remotes[host] = client
        return client
    }

    private func savePin(_ pin: String, for key: String) {
        pins[key] = pin
        rememberPins(pins)
    }

    private func remoteCall(_ device: HomeDevice, _ body: (TVRemoteClient) async throws -> Void) async throws {
        let host = try host(of: device)
        do {
            try await body(try remote(host, key: device.controls["pairingKey"] ?? host))
        } catch let error as TVRemoteError {
            throw ProviderError.api(error.message)
        }
    }

    // MARK: ADB

    /// The TVs the Mac has reached by ADB (their last addresses).
    public func adbHosts() -> [String] {
        guard useADB else { return [] }
        return Array(Set(known.values.map(\.host) + manualHosts)).filter { !$0.isEmpty }
    }

    /// One ADB shell command on a TV, by address.
    public func shellOn(_ host: String, _ command: String) async throws -> String {
        try await shell(command, host: host)
    }

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
