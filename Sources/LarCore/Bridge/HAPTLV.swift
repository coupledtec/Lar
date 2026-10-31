import CryptoKit
import Foundation

/// HomeKit's pairing messages: type, length, value; values over 255 bytes go in consecutive pieces of the same type.
struct HAPTLV: Equatable {
    enum Kind: UInt8 {
        case method = 0, identifier = 1, salt = 2, publicKey = 3, proof = 4, encryptedData = 5, state = 6, error = 7
        case retryDelay = 8, signature = 10, permissions = 11, flags = 19, separator = 255
    }

    enum Failure: UInt8 {
        case unknown = 1, authentication = 2, backoff = 3, maxPeers = 4, maxTries = 5, unavailable = 6, busy = 7
    }

    private(set) var items: [(Kind, Data)] = []

    init(_ items: [(Kind, Data)] = []) { self.items = items }

    init(decoding data: Data) {
        var index = data.startIndex
        var lastType: UInt8?
        while index + 1 < data.endIndex {
            let type = data[index], length = Int(data[index + 1])
            let start = index + 2, end = min(start + length, data.endIndex)
            let value = Data(data[start..<end])
            if type == lastType, type != Kind.separator.rawValue, items.last?.0.rawValue == type {
                items[items.count - 1].1.append(value)
            } else if let kind = Kind(rawValue: type) {
                items.append((kind, value))
            }
            lastType = type
            index = end
        }
    }

    subscript(kind: Kind) -> Data? { items.first { $0.0 == kind }?.1 }

    func byte(_ kind: Kind) -> UInt8? { self[kind]?.first }

    mutating func append(_ kind: Kind, _ value: Data) { items.append((kind, value)) }
    mutating func append(_ kind: Kind, _ byte: UInt8) { items.append((kind, Data([byte]))) }

    var encoded: Data {
        var out = Data()
        for (kind, value) in items {
            if value.isEmpty {
                out.append(contentsOf: [kind.rawValue, 0])
                continue
            }
            var offset = value.startIndex
            while offset < value.endIndex {
                let end = min(offset + 255, value.endIndex)
                out.append(contentsOf: [kind.rawValue, UInt8(end - offset)])
                out.append(value[offset..<end])
                offset = end
            }
        }
        return out
    }

    static func == (lhs: HAPTLV, rhs: HAPTLV) -> Bool { lhs.encoded == rhs.encoded }

    static func error(state: UInt8, _ failure: Failure) -> HAPTLV { HAPTLV([(.state, Data([state])), (.error, Data([failure.rawValue]))]) }
}

/// The key derivations and the sealed messages of pairing.
enum HAPCrypto {
    static func key(_ secret: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8), info: Data(info.utf8),
                               outputByteCount: 32)
    }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// The 12-byte nonce: four zeros, then the label ("PS-Msg05") or the counter (little-endian).
    static func nonce(_ label: String) -> ChaChaPoly.Nonce { try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8)) }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: counter.littleEndian) { Data($0) })
    }

    static func seal(_ plain: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) -> Data {
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) -> Data? {
        guard sealed.count >= 16 else { return nil }
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}
