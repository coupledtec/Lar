import Foundation

/// Xiaomi's MIoT model (also Dreame's): a device is services of numbered properties (siid/piid) and actions
/// (siid/aiid), described for each model at miot-spec.org. What Lar needs of a robot or a lock, found by the
/// services' and properties' standard names, so any model works without a table of its own.
struct MIoTMap: Codable, Sendable, Equatable {
    struct Property: Codable, Sendable, Equatable {
        var siid: Int
        var piid: Int
    }

    struct Action: Codable, Sendable, Equatable {
        var siid: Int
        var aiid: Int
    }

    var kind: DeviceKind
    var status: Property?
    /// The status values' names, as the spec gives them ("Sweeping", "Go Charging").
    var statusNames: [Int: String] = [:]
    var battery: Property?
    var start: Action?
    var dock: Action?
    /// A lock: locked or not, and the door open or closed.
    var lockState: Property?
    var lockNames: [Int: String] = [:]
    var doorState: Property?
    var doorNames: [Int: String] = [:]

    var properties: [Property] { [status, battery, lockState, doorState].compactMap { $0 } }

    /// The map of a model's spec (miot-spec.org's instance JSON); nil when it isn't a robot nor a lock.
    static func from(spec: [String: Any]) -> MIoTMap? {
        let services = spec.list("services")
        func name(_ urn: String?) -> String { urn?.split(separator: ":").dropFirst(3).first.map(String.init) ?? "" }
        func service(_ names: Set<String>) -> [String: Any]? { services.first { names.contains(name($0.string("type"))) } }
        func property(_ service: [String: Any]?, _ names: Set<String>) -> (Property, [Int: String])? {
            guard let service, let siid = service.int("iid"),
                  let item = service.list("properties").first(where: { names.contains(name($0.string("type"))) }),
                  let piid = item.int("iid") else { return nil }
            let values = Dictionary(item.list("value-list").compactMap { entry -> (Int, String)? in
                guard let value = entry.int("value") else { return nil }
                return (value, entry.string("description") ?? "")
            }, uniquingKeysWith: { first, _ in first })
            return (Property(siid: siid, piid: piid), values)
        }
        func action(_ service: [String: Any]?, _ names: [String]) -> Action? {
            guard let service, let siid = service.int("iid") else { return nil }
            for wanted in names {
                if let item = service.list("actions").first(where: { name($0.string("type")) == wanted }), let aiid = item.int("iid") {
                    return Action(siid: siid, aiid: aiid)
                }
            }
            return nil
        }
        let battery = property(service(["battery"]), ["battery-level"])?.0
        if let vacuum = service(["vacuum", "sweep", "robot-cleaner"]) {
            let status = property(vacuum, ["status"])
            let dock = action(service(["battery"]), ["start-charge"]) ?? action(vacuum, ["stop-and-gocharge", "return-to-dock", "go-charging"])
            return MIoTMap(kind: .vacuum, status: status?.0, statusNames: status?.1 ?? [:], battery: battery,
                           start: action(vacuum, ["start-sweep", "start-clean", "start-sweep-mop", "start-mop"]) ?? action(service(["vacuum-extend"]), ["start-clean"]),
                           dock: dock)
        }
        if let lock = service(["lock", "door-lock", "physical-controls-locked"]) {
            let state = property(lock, ["lock-state", "status", "locked-state"])
            let door = property(service(["door", "magnet-sensor"]), ["door-state", "contact-state", "status"]) ?? property(lock, ["door-state"])
            return MIoTMap(kind: .lock, battery: battery, lockState: state?.0, lockNames: state?.1 ?? [:],
                           doorState: door?.0, doorNames: door?.1 ?? [:])
        }
        return nil
    }

    // MARK: Reading

    /// The list's line for the values read (by property), as the other robots and locks show it.
    func device(provider: Provider, id: String, name: String, online: Bool, values: [Property: MIoTValue]) -> HomeDevice {
        var parts: [String] = []
        var isOn: Bool?
        if kind == .vacuum, let status, let value = values[status]?.int {
            let english = statusNames[value] ?? ""
            parts.append(Self.vacuumText(english))
            isOn = Self.isCleaning(english)
        }
        var controls: [String: String] = [:]
        if kind == .lock {
            if let lockState, let value = values[lockState]?.int {
                let text = Self.lockText(lockNames[value] ?? "", value: value)
                parts.append(text)
                controls["locked"] = text == tr("Trancada") ? "1" : "0"
            }
            if let doorState, let value = values[doorState] {
                let english = value.int.flatMap { doorNames[$0] } ?? (value == .bool(true) ? "Open" : "Closed")
                parts.append(english.lowercased().contains("open") ? tr("Porta aberta") : tr("Porta fechada"))
            }
        }
        if let battery, let level = values[battery]?.int { parts.append(tr("bateria \(level)%")) }
        return HomeDevice(provider: provider, rawID: id, name: name, kind: kind, isOnline: online, isOn: isOn,
                          detail: parts.joined(separator: " · "), controls: controls)
    }

    static func isCleaning(_ english: String) -> Bool {
        let text = english.lowercased()
        guard !text.contains("go ") && !text.contains("charg") && !text.contains("pause") else { return false }
        return ["sweep", "clean", "mop", "vacuum", "building", "busy", "working"].contains { text.contains($0) }
    }

    /// The spec's English status, in the words the list uses for every robot.
    static func vacuumText(_ english: String) -> String {
        let text = english.lowercased()
        if text.contains("go charg") || text.contains("return") || text.contains("go home") || text.contains("back") { return tr("Voltando à base") }
        if text.contains("charging completed") || text.contains("full") || text.contains("charged") { return tr("Carregado") }
        if text.contains("charg") { return tr("Carregando") }
        if text.contains("pause") { return tr("Pausado") }
        if text.contains("error") || text.contains("fault") || text.contains("stuck") { return tr("Com problema") }
        if text.contains("wash") { return tr("Lavando o pano") }
        if text.contains("dry") { return tr("Secando o pano") }
        if text.contains("upgrad") || text.contains("updat") { return tr("Atualizando") }
        if isCleaning(english) { return tr("Limpando") }
        if text.contains("sleep") { return tr("Em repouso") }
        return tr("Parado")
    }

    static func lockText(_ english: String, value: Int) -> String {
        let text = english.lowercased()
        if text.contains("unlock") || text.contains("open") { return tr("Destrancada") }
        if text.contains("lock") || text.contains("close") { return tr("Trancada") }
        return value == 0 ? tr("Destrancada") : tr("Trancada")
    }
}

extension MIoTMap.Property: Hashable {}

/// A property's value as the cloud returns it.
enum MIoTValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    case text(String)

    init?(_ value: Any) {
        if let number = value as? NSNumber {
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .int(number.intValue)
        } else if let text = value as? String {
            self = .text(text)
        } else {
            return nil
        }
    }

    var int: Int? {
        switch self {
        case .int(let value): value
        case .bool(let value): value ? 1 : 0
        case .text(let value): Int(value)
        }
    }
}

/// The spec catalog at miot-spec.org: which spec each model has (a big list, read once and kept per model).
enum MIoTSpecs {
    static func maps(for models: Set<String>, http: BrandHTTP) async throws -> [String: MIoTMap] {
        guard !models.isEmpty else { return [:] }
        let catalog = try await http.json("GET", "https://miot-spec.org/miot-spec-v2/instances", query: ["status": "all"])
        // The newest released spec of each model (or the newest at all, for models still in debug).
        var types: [String: (type: String, released: Bool, version: Int)] = [:]
        for entry in catalog.list("instances") {
            guard let model = entry.string("model"), models.contains(model), let type = entry.string("type") else { continue }
            let released = entry.string("status") == "released", version = entry.int("version") ?? 0
            if let current = types[model], (current.released && !released) || (current.released == released && current.version >= version) { continue }
            types[model] = (type, released, version)
        }
        var out: [String: MIoTMap] = [:]
        for (model, entry) in types {
            let spec = try await http.json("GET", "https://miot-spec.org/miot-spec-v2/instance", query: ["type": entry.type])
            if let map = MIoTMap.from(spec: spec) { out[model] = map }
        }
        return out
    }
}
