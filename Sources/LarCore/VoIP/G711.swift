import Foundation

/// G.711 (μ-law, payload 0; A-law, payload 8): 8 kHz, one byte per sample. Every intercom and PBX speaks it.
enum G711 {
    static func encodeMuLaw(_ sample: Int16) -> UInt8 {
        let bias = 0x84, clip = 32_635
        var value = Int(sample)
        let sign = value < 0 ? 0x80 : 0
        if value < 0 { value = -value }
        value = min(value, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, value & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return ~UInt8(sign | (exponent << 4) | mantissa)
    }

    static func decodeMuLaw(_ byte: UInt8) -> Int16 {
        let value = Int(~byte)
        let sign = value & 0x80, exponent = (value >> 4) & 0x07, mantissa = value & 0x0F
        let magnitude = ((mantissa << 3) + 0x84) << exponent - 0x84
        return Int16(sign != 0 ? -magnitude : magnitude)
    }

    static func encodeALaw(_ sample: Int16) -> UInt8 {
        var value = Int(sample) >> 3
        let sign: Int
        if value >= 0 {
            sign = 0xD5
        } else {
            sign = 0x55
            value = -value - 1
        }
        let segments = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]
        let segment = segments.firstIndex { value <= $0 } ?? 8
        if segment >= 8 { return UInt8(0x7F ^ sign) }
        let mantissa = segment < 2 ? (value >> 1) & 0x0F : (value >> segment) & 0x0F
        return UInt8(((segment << 4) | mantissa) ^ sign)
    }

    static func decodeALaw(_ byte: UInt8) -> Int16 {
        let value = Int(byte ^ 0x55)
        var magnitude = (value & 0x0F) << 4
        let segment = (value & 0x70) >> 4
        switch segment {
        case 0: magnitude += 8
        case 1: magnitude += 0x108
        default: magnitude = (magnitude + 0x108) << (segment - 1)
        }
        return Int16(value & 0x80 != 0 ? magnitude : -magnitude)
    }
}
