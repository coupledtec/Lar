import CommonCrypto
import CryptoKit
import Foundation

/// SRTP and SRTCP with AES_CM_128_HMAC_SHA1_80 (RFC 3711), the only suite HomeKit cameras use: the master key and
/// salt come from the iPhone; session keys are derived once.
struct SRTPContext {
    let rtpKey: Data
    let rtpAuth: Data
    let rtpSalt: Data
    private let rtcpKey: Data
    private let rtcpAuth: Data
    private let rtcpSalt: Data
    private var rollover: UInt32 = 0
    private var lastSequence: UInt16?
    private var rtcpIndex: UInt32 = 0

    init(masterKey: Data, masterSalt: Data) {
        func derive(_ label: UInt8, _ count: Int) -> Data {
            var iv = Data(masterSalt.prefix(14)) + Data(count: 2)
            iv[iv.startIndex + 7] ^= label
            return Self.aesCTR(Data(count: count), key: masterKey, iv: iv)
        }
        rtpKey = derive(0, 16)
        rtpAuth = derive(1, 20)
        rtpSalt = derive(2, 14)
        rtcpKey = derive(3, 16)
        rtcpAuth = derive(4, 20)
        rtcpSalt = derive(5, 14)
    }

    /// An RTP packet (12-byte header, no CSRC or extension) sealed: payload encrypted, 10-byte tag appended.
    mutating func protect(rtp packet: Data) -> Data {
        let bytes = [UInt8](packet)
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if let last = lastSequence, sequence < last, last - sequence > 0x8000 { rollover &+= 1 }
        lastSequence = sequence
        let ssrc = Data(bytes[8..<12])
        let index = UInt64(rollover) << 16 | UInt64(sequence)
        let iv = Self.iv(salt: rtpSalt, ssrc: ssrc, index: index)
        var out = Data(bytes[0..<12])
        out += Self.aesCTR(Data(bytes[12...]), key: rtpKey, iv: iv)
        let roc = withUnsafeBytes(of: rollover.bigEndian) { Data($0) }
        out += Self.tag(out + roc, key: rtpAuth)
        return out
    }

    /// An RTCP packet sealed: everything after the first 8 bytes encrypted, then E|index and the tag.
    mutating func protect(rtcp packet: Data) -> Data {
        let bytes = [UInt8](packet)
        let index = rtcpIndex
        rtcpIndex = (rtcpIndex &+ 1) & 0x7FFF_FFFF
        let iv = Self.iv(salt: rtcpSalt, ssrc: Data(bytes[4..<8]), index: UInt64(index))
        var out = Data(bytes[0..<8])
        out += Self.aesCTR(Data(bytes[8...]), key: rtcpKey, iv: iv)
        out += withUnsafeBytes(of: (index | 0x8000_0000).bigEndian) { Data($0) }
        out += Self.tag(out, key: rtcpAuth)
        return out
    }

    static func iv(salt: Data, ssrc: Data, index: UInt64) -> Data {
        var iv = [UInt8](salt.prefix(14)) + [0, 0]
        for (i, byte) in ssrc.enumerated() { iv[4 + i] ^= byte }
        for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (8 * UInt64(5 - i))) }
        return Data(iv)
    }

    static func tag(_ data: Data, key: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)).prefix(10))
    }

    static func aesCTR(_ data: Data, key: Data, iv: Data) -> Data {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0,
                                        CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: data.count)
        var moved = 0
        _ = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                CCCryptorUpdate(cryptor, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
            }
        }
        return out
    }
}
