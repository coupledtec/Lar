import CryptoKit
import Foundation

/// Who the bridge is to the Home app, kept in the keychain: its pairing identifier, long-term key, setup code and the
/// controllers (iPhones, home hubs) paired with it.
struct HAPIdentity: Codable, Equatable {
    struct Pairing: Codable, Equatable {
        var publicKey: Data
        var admin: Bool
    }

    var id: String
    var privateKey: Data
    var setupCode: String
    var setupID: String
    var pairings: [String: Pairing] = [:]

    static let account = "homekit-bridge"

    static func make() -> HAPIdentity {
        let id = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
        let letters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return HAPIdentity(id: id, privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, setupCode: makeCode(),
                           setupID: String((0..<4).map { _ in letters.randomElement()! }))
    }

    /// Eight digits as XXX-XX-XXX, never one of the codes HomeKit refuses.
    static func makeCode() -> String {
        let refused: Set<String> = ["00000000", "11111111", "22222222", "33333333", "44444444", "55555555", "66666666",
                                    "77777777", "88888888", "99999999", "12345678", "87654321"]
        var digits: String
        repeat { digits = (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined() } while refused.contains(digits)
        let chars = Array(digits)
        return "\(String(chars[0..<3]))-\(String(chars[3..<5]))-\(String(chars[5..<8]))"
    }

    static func load() -> HAPIdentity {
        if let saved = Keychain.read(account).flatMap({ Data(base64Encoded: $0) }),
           let identity = try? JSONDecoder().decode(HAPIdentity.self, from: saved) {
            return identity
        }
        let identity = make()
        identity.save()
        return identity
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Keychain.write(data.base64EncodedString(), account: Self.account, label: "Lar – ponte do app Casa")
    }

    var signingKey: Curve25519.Signing.PrivateKey { try! Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) }

    var isPaired: Bool { !pairings.isEmpty }

    /// What the Home app's camera reads: X-HM:// with the category, "on the network" and the code in base 36, then
    /// the setup identifier.
    func setupURI(category: Int = 2) -> String {
        let code = UInt64(setupCode.filter(\.isNumber)) ?? 0
        let payload = code | (1 << 28) | (UInt64(category) << 31)
        let encoded = String(payload, radix: 36).uppercased()
        return "X-HM://" + String(repeating: "0", count: max(0, 9 - encoded.count)) + encoded + setupID
    }

    /// The Bonjour "sh": lets the Home app match the code it scanned with this bridge.
    var setupHash: String {
        Data(SHA512.hash(data: Data((setupID + id).utf8)).prefix(4)).base64EncodedString()
    }
}
