import CryptoKit
import Foundation

/// The setup code's proof (SRP-6a, as HomeKit uses it: the 3072-bit group of RFC 5054, generator 5, SHA-512, user
/// "Pair-Setup"). The accessory's side only: it holds the verifier made from the code and checks the iPhone's proof.
struct HAPSRPServer {
    static let username = "Pair-Setup"
    static let group = Modulus(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510\
        15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
        BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)
    static let generator = Data([5])

    let salt: Data
    /// The public value sent to the iPhone (B), as wide as the group.
    let publicKey: Data
    private let verifier: [UInt64]
    private let secret: Data

    init(code: String, salt: Data = Self.random(16), secret: Data = Self.random(32)) {
        let group = Self.group
        self.salt = salt
        self.secret = secret
        let x = Self.hash(salt, Self.hash(Data("\(Self.username):\(code)".utf8)))
        verifier = group.power(group.words(Self.generator), group.words(x))
        let k = group.words(Self.hash(group.modulusBytes, group.padded(Self.generator)))
        let gb = group.power(group.words(Self.generator), group.words(secret))
        publicKey = group.bytes(group.add(group.multiply(k, verifier), gb))
    }

    /// The session key and the accessory's proof (M2) when the iPhone's public value (A) and proof (M1) match the
    /// code; nil otherwise.
    func verify(clientKey: Data, proof: Data) -> (key: Data, proof: Data)? {
        let group = Self.group
        guard clientKey.count <= group.byteCount else { return nil }
        let a = group.words(clientKey)
        guard group.isReduced(a), !Modulus.isZero(a) else { return nil }
        let paddedA = group.bytes(a)
        let u = group.words(Self.hash(paddedA, publicKey))
        guard !Modulus.isZero(u) else { return nil }
        let base = group.multiply(a, group.power(verifier, u))
        let s = group.bytes(group.power(base, group.words(secret)))
        let key = Self.hash(s)
        let hn = Self.hash(group.modulusBytes), hg = Self.hash(Self.generator)
        let expected = Self.hash(Data(zip(hn, hg).map { $0 ^ $1 }), Self.hash(Data(Self.username.utf8)), salt, paddedA,
                                 publicKey, key)
        guard expected == proof else { return nil }
        return (key, Self.hash(paddedA, proof, key))
    }

    static func hash(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// Numbers modulo a fixed odd modulus, as little-endian 64-bit words of the modulus' width, multiplied in
/// Montgomery form. Only what SRP needs; not constant-time (the secret exponent changes at every pairing).
struct Modulus: Sendable {
    let modulus: [UInt64]
    let modulusBytes: Data
    let byteCount: Int
    private let count: Int
    /// −modulus⁻¹ mod 2⁶⁴.
    private let inverse: UInt64
    /// R² mod modulus, R = 2^(64·count).
    private let rSquared: [UInt64]

    init(hex: String) {
        let digits = Array(hex.utf8)
        let bytes = Data(stride(from: 0, to: digits.count, by: 2).map {
            UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
        modulusBytes = bytes
        byteCount = bytes.count
        count = (bytes.count + 7) / 8
        var words = [UInt64](repeating: 0, count: count)
        for (index, byte) in bytes.reversed().enumerated() { words[index / 8] |= UInt64(byte) << (8 * UInt64(index % 8)) }
        modulus = words
        var x: UInt64 = 1
        for _ in 0..<7 { x = x &* (2 &- words[0] &* x) }
        inverse = 0 &- x
        // R² by doubling 1 (2 · 64 · count) times, reducing each time.
        var r = [UInt64](repeating: 0, count: count)
        r[0] = 1
        for _ in 0..<(2 * 64 * count) {
            var carry: UInt64 = 0
            for i in 0..<count {
                let next = r[i] >> 63
                r[i] = (r[i] << 1) | carry
                carry = next
            }
            if carry == 1 || !Self.less(r, words) { Self.subtract(&r, words) }
        }
        rSquared = r
    }

    /// Big-endian bytes as words; the value must fit the modulus' width.
    func words(_ bytes: Data) -> [UInt64] {
        var words = [UInt64](repeating: 0, count: count)
        for (index, byte) in bytes.reversed().enumerated() where index < 8 * count {
            words[index / 8] |= UInt64(byte) << (8 * UInt64(index % 8))
        }
        return words
    }

    /// Big-endian, padded to the modulus' width.
    func bytes(_ words: [UInt64]) -> Data {
        var out = Data(count: 8 * count)
        for i in 0..<(8 * count) { out[8 * count - 1 - i] = UInt8(truncatingIfNeeded: words[i / 8] >> (8 * UInt64(i % 8))) }
        return Data(out.suffix(byteCount))
    }

    func padded(_ bytes: Data) -> Data { Data(count: max(0, byteCount - bytes.count)) + bytes }

    func isReduced(_ a: [UInt64]) -> Bool { Self.less(a, modulus) }

    /// a · b mod modulus (both reduced).
    func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] { montgomery(montgomery(a, b), rSquared) }

    /// a + b mod modulus (both reduced).
    func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var sum = a
        var carry = false
        for i in 0..<count {
            let (s1, o1) = sum[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry ? 1 : 0)
            sum[i] = s2
            carry = o1 || o2
        }
        if carry || !Self.less(sum, modulus) { Self.subtract(&sum, modulus) }
        return sum
    }

    /// base^exponent mod modulus (base reduced).
    func power(_ base: [UInt64], _ exponent: [UInt64]) -> [UInt64] {
        let b = montgomery(base, rSquared)
        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1
        var result = montgomery(one, rSquared)
        var started = false
        for word in exponent.reversed() {
            for bit in stride(from: 63, through: 0, by: -1) {
                if started { result = montgomery(result, result) }
                if (word >> UInt64(bit)) & 1 == 1 {
                    result = montgomery(result, b)
                    started = true
                }
            }
        }
        return montgomery(result, one)
    }

    /// a · b · R⁻¹ mod modulus (CIOS).
    private func montgomery(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let s = count
        var t = [UInt64](repeating: 0, count: s + 2)
        for i in 0..<s {
            var carry: UInt64 = 0
            for j in 0..<s {
                let (hi, lo) = a[j].multipliedFullWidth(by: b[i])
                let (s1, o1) = lo.addingReportingOverflow(t[j])
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            let (top, overflow) = t[s].addingReportingOverflow(carry)
            t[s] = top
            t[s + 1] = overflow ? 1 : 0
            let m = t[0] &* inverse
            let (hi0, lo0) = m.multipliedFullWidth(by: modulus[0])
            let (_, o0) = lo0.addingReportingOverflow(t[0])
            carry = hi0 &+ (o0 ? 1 : 0)
            for j in 1..<s {
                let (hi, lo) = m.multipliedFullWidth(by: modulus[j])
                let (s1, o1) = lo.addingReportingOverflow(t[j])
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[j - 1] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            let (last, o) = t[s].addingReportingOverflow(carry)
            t[s - 1] = last
            t[s] = t[s + 1] &+ (o ? 1 : 0)
        }
        var result = Array(t[0..<s])
        if t[s] != 0 || !Self.less(result, modulus) { Self.subtract(&result, modulus) }
        return result
    }

    static func isZero(_ a: [UInt64]) -> Bool { a.allSatisfy { $0 == 0 } }

    private static func less(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func subtract(_ a: inout [UInt64], _ b: [UInt64]) {
        var borrow = false
        for i in 0..<a.count {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            a[i] = d2
            borrow = o1 || o2
        }
    }
}
