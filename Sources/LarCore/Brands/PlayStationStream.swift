import CryptoKit
import Foundation

/// The pieces of PS Remote Play's stream that the controller needs, as chiaki-ng documents them (rewritten in Swift):
/// the stream's cipher (GKCrypt), its packets (Takion) and the few protobuf messages that open it. No video or audio
/// is decoded: the Lar only sends the controller.
extension PlayStationRemotePlay {
    // MARK: GKCrypt

    /// The stream's cipher: an AES-CTR-like key stream from a key and IV derived from the ECDH secret, and 4-byte
    /// GMAC tags whose key is refreshed every 45000 bytes of key position.
    struct GKCrypt {
        static let refreshKeyPos: UInt64 = 45000
        static let refreshIVOffset: UInt64 = 44910

        let keyBase: Data
        let iv: Data
        let gmacBase: Data

        init(index: UInt8, handshakeKey: Data, secret: Data) {
            let digest = BrandCrypto.hmacSHA256(key: secret, Data([1, index, 0]) + handshakeKey + Data([1, 0]))
            keyBase = digest.prefix(16)
            iv = digest.suffix(16)
            gmacBase = Self.gmacKey(index: 0, base: keyBase, iv: iv)
        }

        /// `base` + `value`, little endian, as the IV's counter.
        static func counterAdd(_ base: Data, _ value: UInt64) -> Data {
            var out = [UInt8](base)
            var carry = value
            var index = 0
            while index < 16, carry > 0 {
                let sum = UInt64(out[index]) + carry
                out[index] = UInt8(sum & 0xff)
                carry = sum >> 8
                index += 1
            }
            return Data(out)
        }

        static func gmacKey(index: UInt64, base: Data, iv: Data) -> Data {
            let digest = BrandCrypto.sha256(base + counterAdd(iv, index &* refreshIVOffset))
            return Data((0..<16).map { digest[$0] ^ digest[$0 + 16] })
        }

        func keyStream(at position: UInt64, count: Int) -> Data {
            var blocks = Data()
            for block in 0..<UInt64((count + 15) / 16) { blocks.append(Self.counterAdd(iv, position / 16 + block)) }
            return (try? BrandCrypto.aes(true, key: keyBase, blocks, padding: false)) ?? Data()
        }

        /// Encrypts (or decrypts) `data` at a key position.
        func crypt(_ data: Data, at position: UInt64) -> Data {
            let before = Int(position % 16)
            let stream = keyStream(at: position - UInt64(before), count: before + data.count)
            return Data(data.enumerated().map { $0.element ^ stream[before + $0.offset] })
        }

        func gmac(_ data: Data, at position: UInt64) -> Data {
            let index = (position > 0 ? position - 1 : 0) / Self.refreshKeyPos
            let key = index == 0 ? gmacBase : Self.gmacKey(index: index, base: gmacBase, iv: iv)
            let nonce = Self.counterAdd(iv, position / 16)
            guard let sealed = try? AES.GCM.seal(Data(), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce),
                                                 authenticating: data) else { return Data(count: 4) }
            return Data(sealed.tag.prefix(4))
        }
    }

    // MARK: Protobuf

    /// Just enough protobuf for the stream's messages.
    enum Proto {
        static func varint(_ value: UInt64) -> Data {
            var value = value
            var out = Data()
            repeat {
                var byte = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                out.append(byte)
            } while value != 0
            return out
        }

        static func field(_ number: Int, varint value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
        static func field(_ number: Int, bytes value: Data) -> Data {
            varint(UInt64(number << 3 | 2)) + varint(UInt64(value.count)) + value
        }

        /// A message's fields: varints as numbers, length-delimited as data.
        static func fields(_ data: Data) -> [(Int, UInt64?, Data?)] {
            var out: [(Int, UInt64?, Data?)] = []
            var index = data.startIndex
            func readVarint() -> UInt64? {
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while index < data.endIndex {
                    let byte = data[index]
                    index += 1
                    value |= UInt64(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                    if shift > 63 { return nil }
                }
                return nil
            }
            while index < data.endIndex {
                guard let key = readVarint() else { break }
                let number = Int(key >> 3)
                switch key & 7 {
                case 0:
                    guard let value = readVarint() else { return out }
                    out.append((number, value, nil))
                case 2:
                    guard let length = readVarint(), index + Int(length) <= data.endIndex else { return out }
                    out.append((number, nil, data.subdata(in: index..<index + Int(length))))
                    index += Int(length)
                case 1: index += 8
                case 5: index += 4
                default: return out
                }
            }
            return out
        }
    }

    enum MessageType: UInt64 {
        case big = 0, bang = 1, heartbeat = 3, disconnect = 8, streamInfo = 13, streamInfoAck = 14, controllerConnection = 21
    }

    /// The launch spec, as the PS5 expects it (the client's wishes for the stream; the smallest one, since the Lar
    /// never shows it).
    static func launchSpec(handshakeKey: Data) -> String {
        "{\"sessionId\":\"sessionId4321\",\"streamResolutions\":[{\"resolution\":{\"width\":640,\"height\":360},\"maxFps\":30,\"score\":10}],"
            + "\"network\":{\"bwKbpsSent\":2000,\"bwLoss\":0.001000,\"mtu\":1454,\"rtt\":1,\"ports\":[53,2053]},\"slotId\":1,"
            + "\"appSpecification\":{\"minFps\":30,\"minBandwidth\":0,\"extTitleId\":\"ps3\",\"version\":1,\"timeLimit\":1,"
            + "\"startTimeout\":100,\"afkTimeout\":100,\"afkTimeoutDisconnect\":100},"
            + "\"konan\":{\"ps3AccessToken\":\"accessToken\",\"ps3RefreshToken\":\"refreshToken\"},"
            + "\"requestGameSpecification\":{\"model\":\"bravia_tv\",\"platform\":\"android\",\"audioChannels\":\"5.1\",\"language\":\"sp\","
            + "\"acceptButton\":\"X\",\"connectedControllers\":[\"xinput\",\"ds3\",\"ds4\"],\"yuvCoefficient\":\"bt601\","
            + "\"videoEncoderProfile\":\"hw4.1\",\"audioEncoderProfile\":\"audio1\",\"adaptiveStreamMode\": \"resize\"},"
            + "\"userProfile\":{\"onlineId\":\"psnId\",\"npId\":\"npId\",\"region\":\"US\",\"languagesUsed\":[\"en\",\"jp\"]},"
            + "\"videoCodec\":\"avc\",\"dynamicRange\":\"SDR\",\"handshakeKey\":\"\(handshakeKey.base64EncodedString())\"}"
    }

    /// BIG: the client's version, the session id, the launch spec (encrypted with the session's cipher) and our ECDH
    /// key signed with the handshake key.
    static func big(sessionID: String, handshakeKey: Data, publicKey: Data, crypt: Crypt) -> Data {
        var json = Data(launchSpec(handshakeKey: handshakeKey).utf8)
        json.append(0)
        // The session cipher's key stream (zeros encrypted) XORed in: not the same as encrypting the text in CFB.
        let stream = crypt.crypt(Data(count: json.count), encrypt: true, counter: 0)
        let spec = Data(zip(json, stream).map { $0 ^ $1 }).base64EncodedString()
        let signature = BrandCrypto.hmacSHA256(key: handshakeKey, publicKey)
        let payload = Proto.field(1, varint: 12) + Proto.field(2, bytes: Data(sessionID.utf8)) + Proto.field(3, bytes: Data(spec.utf8))
            + Proto.field(4, bytes: Data(count: 4)) + Proto.field(5, bytes: publicKey) + Proto.field(6, bytes: signature)
        return Proto.field(1, varint: MessageType.big.rawValue) + Proto.field(2, bytes: payload)
    }

    static func simpleMessage(_ type: MessageType) -> Data { Proto.field(1, varint: type.rawValue) }

    /// The DualSense, connected.
    static func controllerConnection() -> Data {
        Proto.field(1, varint: MessageType.controllerConnection.rawValue)
            + Proto.field(22, bytes: Proto.field(2, varint: 1) + Proto.field(3, varint: 6))
    }

    static func disconnectMessage() -> Data {
        Proto.field(1, varint: MessageType.disconnect.rawValue) + Proto.field(10, bytes: Proto.field(1, bytes: Data("Client Disconnecting".utf8)))
    }

    /// BANG's ECDH key and signature, when the console accepted the version and key.
    static func bang(_ message: Data) -> (publicKey: Data, signature: Data)? {
        let fields = Proto.fields(message)
        guard fields.first(where: { $0.0 == 1 })?.1 == MessageType.bang.rawValue,
              let payload = fields.first(where: { $0.0 == 3 })?.2 else { return nil }
        let inner = Proto.fields(payload)
        guard inner.first(where: { $0.0 == 3 })?.1 == 1, inner.first(where: { $0.0 == 4 })?.1 == 1,
              let key = inner.first(where: { $0.0 == 8 })?.2, let signature = inner.first(where: { $0.0 == 9 })?.2 else { return nil }
        return (key, signature)
    }

    static func messageType(_ message: Data) -> MessageType? {
        Proto.fields(message).first(where: { $0.0 == 1 })?.1.flatMap(MessageType.init)
    }

    // MARK: Controller

    /// The DualSense's buttons, as the console's history events name them.
    public enum Button: String, CaseIterable, Sendable {
        case cross, circle, square, triangle, up, down, left, right, l1, r1, l2, r2, l3, r3, options, create, touchpad, ps

        /// The event for pressing or releasing it.
        func event(_ pressed: Bool) -> Data {
            switch self {
            case .cross: Data([0x80, 0x88, pressed ? 0xff : 0])
            case .circle: Data([0x80, 0x89, pressed ? 0xff : 0])
            case .square: Data([0x80, 0x8a, pressed ? 0xff : 0])
            case .triangle: Data([0x80, 0x8b, pressed ? 0xff : 0])
            case .left: Data([0x80, 0x82, pressed ? 0xff : 0])
            case .right: Data([0x80, 0x83, pressed ? 0xff : 0])
            case .up: Data([0x80, 0x80, pressed ? 0xff : 0])
            case .down: Data([0x80, 0x81, pressed ? 0xff : 0])
            case .l1: Data([0x80, 0x84, pressed ? 0xff : 0])
            case .r1: Data([0x80, 0x85, pressed ? 0xff : 0])
            case .l2: Data([0x80, 0x86, pressed ? 0xff : 0])
            case .r2: Data([0x80, 0x87, pressed ? 0xff : 0])
            case .l3: Data([0x80, pressed ? 0xaf : 0x8f])
            case .r3: Data([0x80, pressed ? 0xb0 : 0x90])
            case .options: Data([0x80, pressed ? 0xac : 0x8c])
            case .create: Data([0x80, pressed ? 0xad : 0x8d])
            case .touchpad: Data([0x80, pressed ? 0xb1 : 0x91])
            case .ps: Data([0x80, pressed ? 0xae : 0x8e])
            }
        }
    }

    /// The sticks (−32768…32767, up is negative on Y) and motion at rest, as the feedback state's 28 bytes.
    static func feedbackState(leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) -> Data {
        func scaled(_ value: Float, _ minimum: Float, _ maximum: Float) -> [UInt8] {
            let v = UInt16(Float(0xffff) * (value - minimum) / (maximum - minimum))
            return [UInt8(v & 0xff), UInt8(v >> 8)]
        }
        var out: [UInt8] = [0xa0]
        out += scaled(0, -30, 30) + scaled(0, -30, 30) + scaled(0, -30, 30)
        out += scaled(0, -5, 5) + scaled(1, -5, 5) + scaled(0, -5, 5)
        // The orientation at rest (w = 1), compressed as chiaki-ng does: the largest component's index and sign, and
        // the other three in 9 bits each.
        let half = Float(0.5).squareRoot()
        let middle = UInt32((half) * Float(0x1ff) / (2 * half))
        let orientation: UInt32 = (3 << 1) | middle << 3 | middle << 12 | middle << 21
        out += [UInt8(orientation & 0xff), UInt8((orientation >> 8) & 0xff), UInt8((orientation >> 16) & 0xff), UInt8(orientation >> 24)]
        for value in [leftX, leftY, rightX, rightY] {
            let raw = UInt16(bitPattern: value)
            out += [UInt8(raw >> 8), UInt8(raw & 0xff)]
        }
        out += [0, 0, 1]
        return Data(out)
    }
}
