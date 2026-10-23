import CryptoKit
import Foundation

/// The messages of the Google TV remote protocol ("Android TV Remote v2", the one the Google TV app uses): pairing on
/// port 6467, the remote itself on 6466, both over TLS with the phone's own certificate. Every message is a protocol
/// buffer preceded by its length as a varint.
/// Field numbers: polo.proto and remotemessage.proto, as in the open androidtvremote2 library.
enum TVRemoteProtocol {
    static let pairingPort: UInt16 = 6467
    static let remotePort: UInt16 = 6466

    /// What the phone says it can do (ping, keys, IME, power, volume, app links), as the Google TV app does.
    static let features: UInt64 = 622

    // MARK: Pairing

    static let statusOK: UInt64 = 200
    static let statusBadSecret: UInt64 = 402
    /// Hexadecimal code of 6 symbols, entered on the phone (the phone's role is "input").
    static let encodingHex: UInt64 = 3, codeLength: UInt64 = 6, roleInput: UInt64 = 1

    static func pairingMessage(_ build: (inout ProtoWriter) -> Void) -> Data {
        var message = ProtoWriter()
        message.varint(1, 2)
        message.varint(2, statusOK)
        build(&message)
        return message.data
    }

    static func pairingRequest(clientName: String) -> Data {
        pairingMessage { message in
            message.message(10) { request in
                request.string(1, "atvremote")
                request.string(2, clientName)
            }
        }
    }

    static func pairingOptions() -> Data {
        pairingMessage { message in
            message.message(20) { options in
                options.message(1) { encoding in
                    encoding.varint(1, encodingHex)
                    encoding.varint(2, codeLength)
                }
                options.varint(3, roleInput)
            }
        }
    }

    static func pairingConfiguration() -> Data {
        pairingMessage { message in
            message.message(30) { configuration in
                configuration.message(1) { encoding in
                    encoding.varint(1, encodingHex)
                    encoding.varint(2, codeLength)
                }
                configuration.varint(2, roleInput)
            }
        }
    }

    static func pairingSecret(_ secret: Data) -> Data {
        pairingMessage { message in
            message.message(40) { $0.bytes(1, secret) }
        }
    }

    /// The secret proves the phone saw the code: SHA-256 of both public keys (modulus and exponent, big-endian
    /// without leading zeros) and the code's last 4 symbols; the code's first 2 symbols are the hash's first byte, so
    /// a mistyped code is caught here, before the TV sees it.
    static func pairingSecret(code: String, client: RSAPublicNumbers, server: RSAPublicNumbers) -> Data? {
        let code = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 6, let bytes = Data(hex: code) else { return nil }
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: bytes.dropFirst())
        let digest = Data(hash.finalize())
        return digest.first == bytes.first ? digest : nil
    }

    // MARK: Remote

    /// Direction of a key: a short press.
    static let keyShort: UInt64 = 3

    /// The answer to the TV's RemoteConfigure: who the phone is and what it does.
    static func configure(model: String) -> Data {
        var message = ProtoWriter()
        message.message(1) { configure in
            configure.varint(1, features)
            configure.message(2) { info in
                info.string(1, model)
                info.string(2, "Lar")
                info.varint(3, 1)
                info.string(4, "1")
                info.string(5, "atvremote")
                info.string(6, "1.0.0")
            }
        }
        return message.data
    }

    static func setActive() -> Data {
        var message = ProtoWriter()
        message.message(2) { $0.varint(1, features) }
        return message.data
    }

    static func pingResponse(_ value: UInt64) -> Data {
        var message = ProtoWriter()
        message.message(9) { $0.varint(1, value) }
        return message.data
    }

    static func key(_ code: Int) -> Data {
        var message = ProtoWriter()
        message.message(10) { key in
            key.varint(1, UInt64(code))
            key.varint(2, keyShort)
        }
        return message.data
    }

    /// Replaces the text of the TV's focused field (its on-screen keyboard open), as the Google TV app's keyboard
    /// does: the counters are the ones the TV last sent, so it knows which field and edit this is.
    static func text(_ value: String, imeCounter: UInt64, fieldCounter: UInt64) -> Data {
        var message = ProtoWriter()
        message.message(21) { batch in
            batch.varint(1, imeCounter)
            batch.varint(2, fieldCounter)
            batch.message(3) { edit in
                edit.varint(1, 1)
                edit.message(2) { field in
                    let length = UInt64(value.utf16.count)
                    field.varint(1, length)
                    field.varint(2, length)
                    field.string(3, value)
                }
            }
        }
        return message.data
    }

    static func openLink(_ link: String) -> Data {
        var message = ProtoWriter()
        message.message(90) { $0.string(1, link) }
        return message.data
    }

    /// What a message from the TV means to the phone.
    enum Incoming: Equatable {
        case configure
        case setActive
        case ping(UInt64)
        /// The screen is on (true) or in standby (false).
        case power(Bool)
        case volume(level: Int, max: Int, muted: Bool)
        /// The app in front, by package.
        case app(String)
        /// The TV's keyboard state: which edit and which field come next.
        case keyboard(imeCounter: UInt64, fieldCounter: UInt64)
        case error
        case other
    }

    static func incoming(_ data: Data) throws -> Incoming {
        let message = try ProtoReader(data)
        if message.has(1) { return .configure }
        if message.has(2) { return .setActive }
        if message.has(3) { return .error }
        if let ping = try message.message(8) { return .ping(ping.int(1) ?? 0) }
        if let start = try message.message(40) { return .power(start.int(1) == 1) }
        if let volume = try message.message(50) {
            return .volume(level: Int(volume.int(7) ?? 0), max: Int(volume.int(6) ?? 0), muted: volume.int(8) == 1)
        }
        if let ime = try message.message(20), let info = try ime.message(1), let package = info.string(12), !package.isEmpty {
            return .app(package)
        }
        if let batch = try message.message(21) {
            return .keyboard(imeCounter: batch.int(1) ?? 0, fieldCounter: batch.int(2) ?? 0)
        }
        return .other
    }

    // MARK: Framing

    /// The length-prefixed message.
    static func frame(_ message: Data) -> Data {
        var out = Data()
        ProtoWriter.appendVarint(UInt64(message.count), to: &out)
        out.append(message)
        return out
    }

    /// The first whole message in `buffer` and how many bytes it took, or nil while it's still arriving.
    static func unframe(_ buffer: Data) throws -> (message: Data, consumed: Int)? {
        var index = buffer.startIndex
        guard let length = try ProtoReader.readVarint(buffer, at: &index) else { return nil }
        guard length <= 1 << 20 else { throw TVRemoteError.protocolError("mensagem grande demais") }
        let end = index + Int(length)
        guard end <= buffer.endIndex else { return nil }
        return (Data(buffer[index..<end]), end - buffer.startIndex)
    }
}

/// An RSA public key as the pairing hash wants it: modulus and exponent, big-endian, no leading zeros.
struct RSAPublicNumbers: Equatable {
    var modulus: Data
    var exponent: Data

    /// From PKCS #1 (SEQUENCE { INTEGER modulus, INTEGER exponent }), as the keychain exports RSA public keys.
    init?(pkcs1 der: Data) {
        guard let (modulus, exponent) = ADBKey.parseRSAPublicKey(der) else { return nil }
        self.modulus = Data(modulus)
        var bytes = withUnsafeBytes(of: exponent.bigEndian) { Array($0) }
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        self.exponent = Data(bytes)
    }

    init(modulus: Data, exponent: Data) {
        self.modulus = modulus
        self.exponent = exponent
    }
}

public enum TVRemoteError: Error, Equatable, Sendable {
    case identity(String)
    case connection(String)
    /// The TV doesn't know this phone (never paired, or the TV forgot it).
    case notPaired
    case wrongCode
    case protocolError(String)

    public var message: String {
        switch self {
        case .identity(let message): "Certificado do controle: \(message)"
        case .connection(let message): message
        case .notPaired: "Pareie a TV com o código que aparece nela"
        case .wrongCode: "Código errado; confira o que aparece na TV"
        case .protocolError(let message): "Controle da TV: \(message)"
        }
    }
}

// MARK: - Protocol buffers

/// Just enough protocol buffers for the remote: varints and length-delimited fields (bytes, text, messages).
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        Self.appendVarint(UInt64(field << 3), to: &data)
        Self.appendVarint(value, to: &data)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        Self.appendVarint(UInt64(field << 3 | 2), to: &data)
        Self.appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }

    /// A nested message, written even when empty (an empty message still says the field is there).
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        bytes(field, nested.data)
    }

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}

/// A message's fields by number; the last value wins, as in protocol buffers.
struct ProtoReader {
    private var varints: [Int: UInt64] = [:]
    private var lengthDelimited: [Int: Data] = [:]

    init(_ data: Data) throws {
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = try Self.readVarint(data, at: &index) else { throw TVRemoteError.protocolError("mensagem cortada") }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = try Self.readVarint(data, at: &index) else { throw TVRemoteError.protocolError("mensagem cortada") }
                varints[field] = value
            case 2:
                guard let length = try Self.readVarint(data, at: &index), index + Int(length) <= data.endIndex else {
                    throw TVRemoteError.protocolError("mensagem cortada")
                }
                lengthDelimited[field] = Data(data[index..<index + Int(length)])
                index += Int(length)
            case 1: index += 8
            case 5: index += 4
            default: throw TVRemoteError.protocolError("campo desconhecido")
            }
        }
    }

    func has(_ field: Int) -> Bool { varints[field] != nil || lengthDelimited[field] != nil }
    func int(_ field: Int) -> UInt64? { varints[field] }
    func bytes(_ field: Int) -> Data? { lengthDelimited[field] }
    func string(_ field: Int) -> String? { lengthDelimited[field].map { String(decoding: $0, as: UTF8.self) } }
    func message(_ field: Int) throws -> ProtoReader? { try lengthDelimited[field].map(ProtoReader.init) }

    /// A varint at `index` (moved past it), or nil when the data ends first.
    static func readVarint(_ data: Data, at index: inout Data.Index) throws -> UInt64? {
        var value: UInt64 = 0, shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return value }
            shift += 7
            guard shift < 64 else { throw TVRemoteError.protocolError("número inválido") }
        }
        return nil
    }
}

extension Data {
    /// "1A2B" → [0x1A, 0x2B]; nil for an odd length or anything that isn't hexadecimal.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
