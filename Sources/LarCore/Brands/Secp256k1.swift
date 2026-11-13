import Foundation

/// Elliptic-curve Diffie–Hellman on secp256k1, the curve PS Remote Play's stream uses (CryptoKit only has the NIST
/// curves). Plain affine arithmetic on 256-bit numbers: a handful of operations per session, so speed and constant
/// time don't matter here.
enum Secp256k1 {
    /// A 256-bit number, least significant limb first.
    struct U256: Equatable {
        var limbs: [UInt64]

        init(_ limbs: [UInt64]) { self.limbs = limbs }

        init?(bytes: Data) {
            guard bytes.count == 32 else { return nil }
            let array = [UInt8](bytes)
            limbs = (0..<4).map { limb in
                (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(array[(3 - limb) * 8 + $1]) }
            }
        }

        var bytes: Data {
            var out = Data(capacity: 32)
            for limb in limbs.reversed() {
                for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((limb >> UInt64(shift)) & 0xff)) }
            }
            return out
        }

        var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

        func bit(_ index: Int) -> Bool { (limbs[index / 64] >> UInt64(index % 64)) & 1 == 1 }

        static func < (a: U256, b: U256) -> Bool {
            for i in stride(from: 3, through: 0, by: -1) where a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] }
            return false
        }
    }

    static let p = U256([0xFFFF_FFFE_FFFF_FC2F, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF])
    static let n = U256([0xBFD2_5E8C_D036_4141, 0xBAAE_DCE6_AF48_A03B, 0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF])
    static let gx = U256([0x59F2_815B_16F8_1798, 0x029B_FCDB_2DCE_28D9, 0x55A0_6295_CE87_0B07, 0x79BE_667E_F9DC_BBAC])
    static let gy = U256([0x9C47_D08F_FB10_D4B8, 0xFD17_B448_A685_5419, 0x5DA4_FBFC_0E11_08A8, 0x483A_DA77_26A3_C465])

    // MARK: Field arithmetic mod p

    /// a + b, with the carry out.
    static func add(_ a: U256, _ b: U256) -> (U256, Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var carry = false
        for i in 0..<4 {
            let (s1, c1) = a.limbs[i].addingReportingOverflow(b.limbs[i])
            let (s2, c2) = s1.addingReportingOverflow(carry ? 1 : 0)
            out[i] = s2
            carry = c1 || c2
        }
        return (U256(out), carry)
    }

    /// a − b, with the borrow out.
    static func sub(_ a: U256, _ b: U256) -> (U256, Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var borrow = false
        for i in 0..<4 {
            let (d1, b1) = a.limbs[i].subtractingReportingOverflow(b.limbs[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            out[i] = d2
            borrow = b1 || b2
        }
        return (U256(out), borrow)
    }

    static func addMod(_ a: U256, _ b: U256) -> U256 {
        let (sum, carry) = add(a, b)
        if carry || !(sum < p) { return sub(sum, p).0 }
        return sum
    }

    static func subMod(_ a: U256, _ b: U256) -> U256 {
        let (difference, borrow) = sub(a, b)
        return borrow ? add(difference, p).0 : difference
    }

    /// a·b mod p, folding the high half with p = 2²⁵⁶ − 0x1000003D1.
    static func mulMod(_ a: U256, _ b: U256) -> U256 {
        var wide = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = a.limbs[i].multipliedFullWidth(by: b.limbs[j])
                let (s1, c1) = wide[i + j].addingReportingOverflow(low)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                wide[i + j] = s2
                carry = high &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            wide[i + 4] = carry
        }
        return reduce(wide)
    }

    private static func reduce(_ wide: [UInt64]) -> U256 {
        let c: UInt64 = 0x1_0000_03D1
        // low + high·c, which fits in 5 limbs.
        var acc = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (high, low) = wide[i + 4].multipliedFullWidth(by: c)
            let (s1, c1) = wide[i].addingReportingOverflow(low)
            let (s2, c2) = s1.addingReportingOverflow(carry)
            acc[i] = s2
            carry = high &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
        }
        acc[4] = carry
        // The fifth limb once more: acc[4]·c added to the low four.
        let (high, low) = acc[4].multipliedFullWidth(by: c)
        var result = [UInt64](repeating: 0, count: 4)
        var extra = [low, high, 0, 0]
        var overflow = false
        for i in 0..<4 {
            let (s1, c1) = acc[i].addingReportingOverflow(extra[i])
            let (s2, c2) = s1.addingReportingOverflow(overflow ? 1 : 0)
            result[i] = s2
            overflow = c1 || c2
        }
        extra = [0, 0, 0, 0]
        var value = U256(result)
        if overflow { value = add(value, U256([c, 0, 0, 0])).0 }
        while !(value < p) { value = sub(value, p).0 }
        return value
    }

    static func powMod(_ base: U256, _ exponent: U256) -> U256 {
        var result = U256([1, 0, 0, 0])
        for index in stride(from: 255, through: 0, by: -1) {
            result = mulMod(result, result)
            if exponent.bit(index) { result = mulMod(result, base) }
        }
        return result
    }

    static func inverse(_ a: U256) -> U256 { powMod(a, sub(p, U256([2, 0, 0, 0])).0) }

    // MARK: Points

    struct Point: Equatable {
        var x: U256
        var y: U256
    }

    static func double(_ point: Point?) -> Point? {
        guard let point, !point.y.isZero else { return nil }
        let x2 = mulMod(point.x, point.x)
        let numerator = addMod(addMod(x2, x2), x2)
        let lambda = mulMod(numerator, inverse(addMod(point.y, point.y)))
        let x = subMod(subMod(mulMod(lambda, lambda), point.x), point.x)
        let y = subMod(mulMod(lambda, subMod(point.x, x)), point.y)
        return Point(x: x, y: y)
    }

    static func add(_ a: Point?, _ b: Point?) -> Point? {
        guard let a else { return b }
        guard let b else { return a }
        if a.x == b.x { return a.y == b.y ? double(a) : nil }
        let lambda = mulMod(subMod(b.y, a.y), inverse(subMod(b.x, a.x)))
        let x = subMod(subMod(mulMod(lambda, lambda), a.x), b.x)
        let y = subMod(mulMod(lambda, subMod(a.x, x)), a.y)
        return Point(x: x, y: y)
    }

    static func multiply(_ point: Point, by scalar: U256) -> Point? {
        var result: Point?
        for index in stride(from: 255, through: 0, by: -1) {
            result = double(result)
            if scalar.bit(index) { result = add(result, point) }
        }
        return result
    }

    static func onCurve(_ point: Point) -> Bool {
        let left = mulMod(point.y, point.y)
        let right = addMod(mulMod(mulMod(point.x, point.x), point.x), U256([7, 0, 0, 0]))
        return left == right
    }

    // MARK: Keys

    struct KeyPair {
        var privateKey: U256
        /// Uncompressed: 0x04, X, Y.
        var publicKey: Data
    }

    static func keyPair(privateKey bytes: Data? = nil) -> KeyPair {
        while true {
            let candidate = bytes ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            guard let key = U256(bytes: candidate), !key.isZero, key < n,
                  let point = multiply(Point(x: gx, y: gy), by: key) else { continue }
            return KeyPair(privateKey: key, publicKey: Data([4]) + point.x.bytes + point.y.bytes)
        }
    }

    /// The shared secret: the X coordinate of our key times theirs (an uncompressed public key).
    static func sharedSecret(_ privateKey: U256, publicKey: Data) -> Data? {
        guard publicKey.count == 65, publicKey.first == 4,
              let x = U256(bytes: publicKey.subdata(in: 1..<33)), let y = U256(bytes: publicKey.subdata(in: 33..<65)) else { return nil }
        let point = Point(x: x, y: y)
        guard onCurve(point), let shared = multiply(point, by: privateKey) else { return nil }
        return shared.x.bytes
    }
}
