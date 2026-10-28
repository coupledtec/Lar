import CryptoKit
import Foundation
import Network
import os

/// Lar's devices in Apple's Home app: the Mac is a HomeKit bridge on the home network (the accessory protocol over
/// IP, paired with the setup code or its QR code). Lights, plugs, fans and other switches, the air conditioners as
/// thermostats and the thermometers; the Home app, Siri and the home hubs then control them through Lar.
@MainActor
public final class HAPBridge {
    public static let isEnabledKey = "homeKitBridge"
    private static let aidsKey = "homeKitBridgeAccessories"
    private static let configKey = "homeKitBridgeConfiguration"
    nonisolated static let log = Logger(subsystem: "com.coupled.lar", category: "homekit")

    private(set) var identity: HAPIdentity
    private let devices: @MainActor () -> [HomeDevice]
    private let perform: @MainActor (HomeCommand, String) -> Void
    /// A camera's live HLS link (it expires within minutes: asked for at each stream).
    private let liveURL: @MainActor (String) async throws -> URL
    #if os(macOS)
    private let cameras = HAPCameras()
    #endif
    private let name: String
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: HAPSession] = [:]
    private var watcher: Task<Void, Never>?
    /// Device id → accessory id (2 onward; 1 is the bridge). Kept, so the Home app keeps rooms and names.
    private var aids: [String: Int]
    private var configuration: (number: Int, signature: String)
    /// The last values sent, by "aid.iid", to tell the subscribed controllers what changed.
    private var lastValues: [String: String] = [:]
    /// Calls back when pairing changes (the settings show it).
    public var onChange: (() -> Void)?

    public init(name: String = "Lar", devices: @escaping @MainActor () -> [HomeDevice],
                perform: @escaping @MainActor (HomeCommand, String) -> Void,
                liveURL: @escaping @MainActor (String) async throws -> URL = { _ in throw ProviderError.unsupported }) {
        self.name = name
        self.devices = devices
        self.perform = perform
        self.liveURL = liveURL
        identity = HAPIdentity.load()
        aids = (Preferences.object(forKey: Self.aidsKey) as? [String: Int]) ?? [:]
        let saved = Preferences.object(forKey: Self.configKey) as? [String: Any]
        configuration = ((saved?["number"] as? Int) ?? 1, (saved?["signature"] as? String) ?? "")
    }

    public static var isEnabled: Bool {
        get { Preferences.bool(forKey: isEnabledKey) ?? false }
        set { Preferences.set(newValue, forKey: isEnabledKey) }
    }

    public var setupCode: String { identity.setupCode }
    public var setupURI: String { identity.setupURI() }
    public var isPaired: Bool { identity.isPaired }
    public var isRunning: Bool { listener != nil }

    public func start() {
        guard listener == nil else { return }
        #if os(macOS)
        cameras.onStatusChange = { [weak self] aid in
            guard let self, let value = self.cameras.value(13, aid: aid) else { return }
            for session in self.sessions.values where session.subscriptions.contains("\(aid).13") {
                session.sendEvent([["aid": aid, "iid": 13, "value": value]])
            }
        }
        #endif
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { Self.log.error("listener: \(error.localizedDescription, privacy: .public)") }
            }
            self.listener = listener
            updateConfiguration()
            advertise()
            listener.start(queue: .main)
        } catch {
            Self.log.error("start: \(error.localizedDescription, privacy: .public)")
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.tick()
            }
        }
    }

    public func stop() {
        #if os(macOS)
        cameras.stopAll()
        #endif
        watcher?.cancel()
        watcher = nil
        listener?.cancel()
        listener = nil
        for session in sessions.values { session.close() }
        sessions = [:]
    }

    /// Forgets every pairing and makes a new code and identity (the Home app sees a new bridge).
    public func reset() {
        let running = isRunning
        stop()
        Keychain.delete(HAPIdentity.account)
        identity = HAPIdentity.load()
        Preferences.set(nil, forKey: Self.aidsKey)
        aids = [:]
        if running { start() }
        onChange?()
    }

    private func advertise() {
        var txt = NWTXTRecord()
        txt["c#"] = String(configuration.number)
        txt["ff"] = "0"
        txt["id"] = identity.id
        txt["md"] = name
        txt["pv"] = "1.1"
        txt["s#"] = "1"
        txt["sf"] = identity.isPaired ? "0" : "1"
        txt["ci"] = "2"
        txt["sh"] = identity.setupHash
        listener?.service = NWListener.Service(name: name, type: "_hap._tcp", domain: nil, txtRecord: txt)
    }

    private func accept(_ connection: NWConnection) {
        let session = HAPSession(connection: connection, bridge: self)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onClose = { [weak self] in self?.sessions[key] = nil }
        session.start()
    }

    // MARK: Pairings

    func savePairing(_ id: String, publicKey: Data, admin: Bool) {
        let wasPaired = identity.isPaired
        identity.pairings[id] = .init(publicKey: publicKey, admin: admin)
        identity.save()
        if !wasPaired { advertise() }
        onChange?()
    }

    func removePairing(_ id: String) {
        identity.pairings[id] = nil
        identity.save()
        for session in sessions.values where session.controller == id { session.closeSoon() }
        if !identity.isPaired {
            for session in sessions.values { session.closeSoon() }
            advertise()
        }
        onChange?()
    }

    // MARK: Accessories

    private struct Entry {
        let aid: Int
        let device: HomeDevice
        let role: HAPRole
    }

    private func entries() -> [Entry] {
        var list: [Entry] = []
        var changed = false
        for device in devices() {
            guard let role = HAPRole(device) else { continue }
            let aid: Int
            if let known = aids[device.id] {
                aid = known
            } else {
                aid = (aids.values.max() ?? 1) + 1
                aids[device.id] = aid
                changed = true
            }
            list.append(Entry(aid: aid, device: device, role: role))
            if list.count == 149 { break }
        }
        if changed { Preferences.set(aids, forKey: Self.aidsKey) }
        return list.sorted { $0.aid < $1.aid }
    }

    /// A new configuration number when the accessories change, so the controllers read them again.
    private func updateConfiguration() {
        let signature = entries().map { "\($0.aid)\($0.role.signature)\($0.device.name)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest != configuration.signature else { return }
        configuration = (configuration.signature.isEmpty ? configuration.number : configuration.number % 65535 + 1, digest)
        Preferences.set(["number": configuration.number, "signature": digest], forKey: Self.configKey)
        if listener != nil { advertise() }
    }

    func accessoriesJSON() -> Data {
        var accessories: [[String: Any]] = [[
            "aid": 1,
            "services": [
                ["iid": 1, "type": "3E", "characteristics": HAPAccessories.information(
                    name: name, model: "Lar Bridge", serial: identity.id).map { HAPAccessories.json($0.0, value: $0.1) }],
                ["iid": 8, "type": "A2", "characteristics": [
                    HAPAccessories.json(HAPCharacteristic(iid: 9, type: "37", format: "string", perms: ["pr"]), value: "1.1.0"),
                ]],
            ],
        ]]
        for entry in entries() {
            let device = entry.device
            var services: [[String: Any]] = [
                ["iid": 1, "type": "3E", "characteristics": HAPAccessories.information(
                    name: HAPAccessories.cleanName(device.name), model: device.provider.name,
                    serial: String(device.id.prefix(64))).map { HAPAccessories.json($0.0, value: $0.1) }],
                ["iid": HAPAccessories.mainService, "type": HAPAccessories.serviceType(entry.role), "primary": true,
                 "characteristics": HAPAccessories.characteristics(entry.role).map {
                     HAPAccessories.json($0, value: HAPAccessories.value($0.iid, of: device, role: entry.role))
                 }],
            ]
            if case .temperatureSensor(true) = entry.role {
                services.append(["iid": HAPAccessories.humidityService, "type": "82", "characteristics": [
                    HAPAccessories.json(HAPAccessories.humidity, value: HAPAccessories.value(21, of: device, role: entry.role)),
                ]])
            }
            accessories.append(["aid": entry.aid, "services": services])
        }
        return (try? JSONSerialization.data(withJSONObject: ["accessories": accessories])) ?? Data()
    }

    private func find(_ aid: Int) -> Entry? { entries().first { $0.aid == aid } }

    private func characteristic(_ iid: Int, of entry: Entry) -> HAPCharacteristic? {
        if case .temperatureSensor(true) = entry.role, iid == HAPAccessories.humidity.iid { return HAPAccessories.humidity }
        return HAPAccessories.characteristics(entry.role).first { $0.iid == iid }
    }

    /// A read: the value, or the status when it can't be read.
    func read(aid: Int, iid: Int) -> (value: Any?, status: HAPStatus) {
        if aid == 1 {
            if iid == 9 { return ("1.1.0", .ok) }
            let info = HAPAccessories.information(name: name, model: "Lar Bridge", serial: identity.id)
            guard let found = info.first(where: { $0.0.iid == iid }) else { return (nil, .notFound) }
            return found.0.perms.contains("pr") ? (found.1, .ok) : (nil, .writeOnly)
        }
        guard let entry = find(aid) else { return (nil, .notFound) }
        #if os(macOS)
        if entry.role == .camera, iid >= 9 {
            guard characteristic(iid, of: entry) != nil else { return (nil, .notFound) }
            return (cameras.value(iid, aid: aid), .ok)
        }
        #endif
        if (2...7).contains(iid) {
            let info = HAPAccessories.information(name: HAPAccessories.cleanName(entry.device.name),
                                                  model: entry.device.provider.name, serial: String(entry.device.id.prefix(64)))
            guard let found = info.first(where: { $0.0.iid == iid }) else { return (nil, .notFound) }
            return found.0.perms.contains("pr") ? (found.1, .ok) : (nil, .writeOnly)
        }
        guard characteristic(iid, of: entry) != nil else { return (nil, .notFound) }
        return (HAPAccessories.value(iid, of: entry.device, role: entry.role), .ok)
    }

    /// Writes of one request, as commands to the devices (a hue and a saturation together become one color).
    func write(_ writes: [(aid: Int, iid: Int, value: Any)], local: String? = nil) -> [HAPStatus] {
        var colors: [String: LightColor] = [:]
        var statuses: [HAPStatus] = []
        for write in writes {
            if (2...7).contains(write.iid) || write.aid == 1 {
                statuses.append(write.iid == 2 ? .ok : .readOnly)
                continue
            }
            guard let entry = find(write.aid), let characteristic = characteristic(write.iid, of: entry) else {
                statuses.append(.notFound)
                continue
            }
            guard characteristic.perms.contains("pw") else {
                statuses.append(.readOnly)
                continue
            }
            #if os(macOS)
            if entry.role == .camera {
                let id = entry.device.id, liveURL = liveURL
                statuses.append(cameras.write(write.iid, aid: write.aid, value: write.value, local: local,
                                              url: { try await liveURL(id) }))
                continue
            }
            #endif
            guard entry.device.isOnline || entry.device.canSwitch else {
                statuses.append(.communicationFailure)
                continue
            }
            var color = colors[entry.device.id]
            guard let command = HAPAccessories.command(write.iid, value: write.value, device: entry.device,
                                                       role: entry.role, color: &color) else {
                statuses.append(.invalidValue)
                continue
            }
            if let color { colors[entry.device.id] = color }
            if let command { perform(command, entry.device.id) }
            statuses.append(.ok)
        }
        for (id, color) in colors { perform(.color(color), id) }
        return statuses
    }

    /// A camera's still for the Home app's tile (POST /resource).
    func snapshot(aid: Int, width: Int) async -> Data? {
        #if os(macOS)
        guard let entry = find(aid), entry.role == .camera else { return nil }
        let id = entry.device.id, liveURL = liveURL
        return await cameras.snapshot(aid: aid, id: id, width: width, url: { try await liveURL(id) })
        #else
        return nil
        #endif
    }

    // MARK: Events

    private func tick() {
        updateConfiguration()
        let subscribed = sessions.values.filter { !$0.subscriptions.isEmpty }
        var current: [String: (aid: Int, iid: Int, value: Any)] = [:]
        for entry in entries() {
            var iids = HAPAccessories.characteristics(entry.role).filter { $0.perms.contains("ev") }.map(\.iid)
            if case .temperatureSensor(true) = entry.role { iids.append(HAPAccessories.humidity.iid) }
            for iid in iids {
                guard let value = HAPAccessories.value(iid, of: entry.device, role: entry.role) else { continue }
                current["\(entry.aid).\(iid)"] = (entry.aid, iid, value)
            }
        }
        var changed: [String] = []
        for (key, item) in current {
            let text = "\(item.value)"
            if lastValues[key] != text {
                if lastValues[key] != nil { changed.append(key) }
                lastValues[key] = text
            }
        }
        guard !changed.isEmpty else { return }
        for session in subscribed {
            let mine = changed.filter { session.subscriptions.contains($0) }.compactMap { current[$0] }
            if !mine.isEmpty { session.sendEvent(mine.map { ["aid": $0.aid, "iid": $0.iid, "value": $0.value] }) }
        }
    }
}
