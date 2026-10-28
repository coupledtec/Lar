import Foundation

/// The same device reached two ways: through its own account and through the Home app (where it was added by
/// itself, by HomeKit or Matter). Matched by name and a compatible kind. The Home app's copy leaves the list, and the
/// device is marked so the Mac's bridge doesn't put it in the Home app a second time.
public enum HomeAppDuplicates {
    /// The accessories the Mac's bridge puts in the Home app say this maker, so they're never read back.
    public static let bridgeManufacturer = "Lar"

    /// Device id of the Home app's copy → id of the account's device.
    public static func matches(in devices: [HomeDevice], names: [String: String] = [:]) -> [String: String] {
        var byKey: [String: String] = [:]
        for device in devices where device.provider != .homeKit {
            for name in [device.name, names[device.id]].compactMap({ $0 }) {
                byKey[key(name, device.kind)] = byKey[key(name, device.kind)] ?? device.id
            }
        }
        guard !byKey.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for device in devices where device.provider == .homeKit {
            if let match = byKey[key(device.name, device.kind)] { out[device.id] = match }
        }
        return out
    }

    /// Lights, plugs, switches and fans are often added as one another (a smart bulb as a switch, a fan on a plug).
    static func family(_ kind: DeviceKind) -> String {
        switch kind {
        case .light, .plug, .fan, .other: "switch"
        default: kind.rawValue
        }
    }

    static func key(_ name: String, _ kind: DeviceKind) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        return family(kind) + ":" + String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
