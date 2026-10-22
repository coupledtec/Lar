import Foundation
import Security

/// The Mac's ADB key: an RSA 2048 pair kept in the keychain. The TV asks "Allow USB debugging?" the first time it
/// sees it; after "Always allow" it's let in silently.
public struct ADBKey: @unchecked Sendable {
    let privateKey: SecKey
    let publicKey: SecKey

    static let account = "adb-key"

    /// Like adb's own ~/.android/adbkey: a file only this user can read. Not the keychain, whose access is tied to
    /// the app's signature and asks again after every rebuild.
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lar/adbkey")
    }

    /// The saved key, or a new one (saved right away, so the TV's approval isn't lost). A key from the keychain
    /// (older versions) moves to the file once, so the TVs that approved it don't ask again.
    public static func loadOrCreate(file: URL = defaultFile) throws -> ADBKey {
        if let data = try? Data(contentsOf: file), let key = try? ADBKey(privateKeyData: data) {
            return key
        }
        let key: ADBKey
        if let saved = Keychain.read(account), let data = Data(base64Encoded: saved), let old = try? ADBKey(privateKeyData: data) {
            key = old
        } else {
            key = try generate()
        }
        try save(key, to: file)
        Keychain.delete(account)
        return key
    }

    static func save(_ key: ADBKey, to file: URL) throws {
        guard let data = SecKeyCopyExternalRepresentation(key.privateKey, nil) as Data? else {
            throw ADBError.key("não deu para guardar a chave")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func generate() throws -> ADBKey {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ADBError.key(error?.takeRetainedValue().localizedDescription ?? "RSA")
        }
        return try ADBKey(privateKey: privateKey)
    }

    init(privateKeyData: Data) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        guard let key = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, nil) else {
            throw ADBError.key("chave guardada ilegível")
        }
        try self.init(privateKey: key)
    }

    init(privateKey: SecKey) throws {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw ADBError.key("sem chave pública") }
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    /// adbd signs nothing itself: it hands over a 20-byte token and checks it as if it were a SHA-1 digest.
    func sign(_ token: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) else {
            throw ADBError.key(error?.takeRetainedValue().localizedDescription ?? "assinatura")
        }
        return signature as Data
    }

    /// The public key in adbd's format: its RSAPublicKey struct in base64, then a name, NUL-terminated.
    func publicKeyBlob(name: String) throws -> Data {
        guard let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let (modulus, exponent) = Self.parseRSAPublicKey(der)
        else { throw ADBError.key("chave pública ilegível") }
        let blob = Self.androidKeyStruct(modulusBigEndian: modulus, exponent: exponent)
        return Data((blob.base64EncodedString() + " \(name)\0").utf8)
    }

    // MARK: Format

    /// adbd's struct: word count, n0inv, modulus and R² mod n as little-endian 32-bit words, then the exponent.
    static func androidKeyStruct(modulusBigEndian: [UInt8], exponent: UInt32) -> Data {
        let n = BigWords(bigEndian: modulusBigEndian, words: 64)
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(64)
        put(n0inv(n.words[0]))
        n.words.forEach(put)
        rSquared(n).words.forEach(put)
        put(exponent)
        return data
    }

    /// −n⁻¹ mod 2³² (n is odd), by Newton's iteration.
    static func n0inv(_ n0: UInt32) -> UInt32 {
        var inverse: UInt32 = n0
        for _ in 0..<5 { inverse = inverse &* (2 &- n0 &* inverse) }
        return 0 &- inverse
    }

    /// 2⁴⁰⁹⁶ mod n, by doubling 4096 times and subtracting n whenever the value reaches it.
    static func rSquared(_ n: BigWords) -> BigWords {
        var x = BigWords(words: [UInt32](repeating: 0, count: n.words.count))
        x.words[0] = 1
        for _ in 0..<(n.words.count * 32 * 2) {
            let carry = x.shiftLeftOne()
            if carry || x >= n { x.subtract(n) }
        }
        return x
    }

    /// Reads SEQUENCE { INTEGER modulus, INTEGER exponent } (PKCS #1), as the keychain exports RSA public keys.
    static func parseRSAPublicKey(_ der: Data) -> (modulus: [UInt8], exponent: UInt32)? {
        let bytes = [UInt8](der)
        var index = 0
        func length() -> Int? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]; index += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7f)
            guard count <= 4, index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count { value = value << 8 | Int(bytes[index]); index += 1 }
            return value
        }
        func integer() -> [UInt8]? {
            guard index < bytes.count, bytes[index] == 0x02 else { return nil }
            index += 1
            guard let size = length(), index + size <= bytes.count else { return nil }
            var value = Array(bytes[index..<index + size])
            index += size
            while value.count > 1, value.first == 0 { value.removeFirst() }
            return value
        }
        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard length() != nil, let modulus = integer(), let exponentBytes = integer(), exponentBytes.count <= 4 else { return nil }
        let exponent = exponentBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (modulus, exponent)
    }
}

/// An unsigned number as little-endian 32-bit words: just enough arithmetic for R² mod n.
struct BigWords: Comparable {
    var words: [UInt32]

    init(words: [UInt32]) { self.words = words }

    init(bigEndian bytes: [UInt8], words count: Int) {
        var words = [UInt32](repeating: 0, count: count)
        for (offset, byte) in bytes.reversed().enumerated() where offset / 4 < count {
            words[offset / 4] |= UInt32(byte) << (8 * UInt32(offset % 4))
        }
        self.words = words
    }

    /// Doubles the number; true when a bit falls off the top.
    mutating func shiftLeftOne() -> Bool {
        var carry: UInt32 = 0
        for i in words.indices {
            let next = words[i] >> 31
            words[i] = words[i] << 1 | carry
            carry = next
        }
        return carry != 0
    }

    mutating func subtract(_ other: BigWords) {
        var borrow: UInt64 = 0
        for i in words.indices {
            let value = UInt64(words[i]) &- UInt64(other.words[i]) &- borrow
            words[i] = UInt32(truncatingIfNeeded: value)
            borrow = (value >> 63) & 1
        }
    }

    static func < (a: BigWords, b: BigWords) -> Bool {
        for i in a.words.indices.reversed() where a.words[i] != b.words[i] { return a.words[i] < b.words[i] }
        return false
    }
}

public enum ADBError: Error, Equatable, Sendable {
    case key(String)
    case connection(String)
    case waitingForApproval
    case rejected
    case protocolError(String)

    public var message: String {
        switch self {
        case .key(let message): "Chave ADB: \(message)"
        case .connection(let message): message
        case .waitingForApproval: "Aceite “Permitir depuração USB?” na TV (marque “Sempre permitir”)"
        case .rejected: "A TV recusou a conexão"
        case .protocolError(let message): "ADB: \(message)"
        }
    }
}
