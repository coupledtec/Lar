import CryptoKit
import Foundation

/// A SIP request or response (RFC 3261): the start line, headers in order, and a body. One per UDP datagram.
struct SIPMessage: Equatable, Sendable {
    var startLine: String
    var headers: [(name: String, value: String)]
    var body: Data

    static func == (a: SIPMessage, b: SIPMessage) -> Bool {
        a.startLine == b.startLine && a.body == b.body
            && a.headers.map { "\($0.name):\($0.value)" } == b.headers.map { "\($0.name):\($0.value)" }
    }

    /// Compact header names, as some servers send them.
    static let compact = ["v": "Via", "f": "From", "t": "To", "i": "Call-ID", "m": "Contact", "l": "Content-Length",
                          "c": "Content-Type", "k": "Supported"]

    init(startLine: String, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.startLine = startLine
        self.headers = headers
        self.body = body
    }

    static func request(_ method: String, uri: String, headers: [(String, String)], body: Data = Data()) -> SIPMessage {
        SIPMessage(startLine: "\(method) \(uri) SIP/2.0", headers: headers.map { (name: $0.0, value: $0.1) }, body: body)
    }

    var isRequest: Bool { !startLine.hasPrefix("SIP/2.0") }
    /// "INVITE", or for a response the method of its CSeq.
    var method: String {
        isRequest ? String(startLine.split(separator: " ").first ?? "") : String(header("CSeq")?.split(separator: " ").last ?? "")
    }
    var statusCode: Int? { isRequest ? nil : Int(startLine.split(separator: " ").dropFirst().first ?? "") }
    var callID: String? { header("Call-ID") }
    var cseq: Int? { header("CSeq").flatMap { Int($0.split(separator: " ").first ?? "") } }

    func header(_ name: String) -> String? { headers(name).first }

    func headers(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    mutating func set(_ name: String, _ value: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        headers.append((name: name, value: value))
    }

    static func parse(_ data: Data) -> SIPMessage? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let start = lines.removeFirst()
        guard start.hasPrefix("SIP/2.0 ") || start.hasSuffix(" SIP/2.0") else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines {
            // A folded line continues the previous header.
            if line.first == " " || line.first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            var name = line[..<colon].trimmingCharacters(in: .whitespaces)
            name = compact[name.lowercased()] ?? name
            headers.append((name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        var body = Data(data[separator.upperBound...])
        if let length = headers.first(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }).flatMap({ Int($0.value) }),
           length < body.count {
            body = body.prefix(length)
        }
        return SIPMessage(startLine: start, headers: headers, body: body)
    }

    func serialized() -> Data {
        var text = startLine + "\r\n"
        for (name, value) in headers where name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        return Data(text.utf8) + body
    }

    /// A parameter of a header value: `tag` in `<sip:a@b>;tag=xyz`, `received` in a Via.
    static func parameter(_ name: String, in value: String) -> String? {
        for part in value.split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.first?.caseInsensitiveCompare(name) == .orderedSame { return pair.count > 1 ? pair[1] : "" }
        }
        return nil
    }

    /// The URI inside a From/To/Contact value: `"Porteiro" <sip:100@host>;tag=1` → `sip:100@host`.
    static func uri(in value: String) -> String {
        if let open = value.firstIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            return String(value[value.index(after: open)..<close])
        }
        return String(value.split(separator: ";").first ?? Substring(value)).trimmingCharacters(in: .whitespaces)
    }

    /// The display name, or the user part of the URI: `"Porteiro" <sip:100@host>` → `Porteiro`.
    static func displayName(in value: String) -> String {
        if let open = value.firstIndex(of: "<") {
            let name = value[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !name.isEmpty { return name }
        }
        let uri = uri(in: value)
        let user = uri.split(separator: ":").dropFirst().first?.split(separator: "@").first
        return user.map(String.init) ?? uri
    }

    static func random(_ count: Int = 10) -> String {
        String((0..<count).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }
}

/// HTTP-style Digest authentication (RFC 2617 / 8760), as SIP servers ask with 401 / 407.
struct SIPDigest: Equatable, Sendable {
    var realm: String
    var nonce: String
    var algorithm: String
    var qop: String?
    var opaque: String?

    init?(challenge: String) {
        guard challenge.lowercased().hasPrefix("digest") else { return nil }
        var values: [String: String] = [:]
        // key="value with, commas", key=token
        let scanner = Scanner(string: String(challenge.dropFirst(6)))
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\t")
        while !scanner.isAtEnd {
            guard let key = scanner.scanUpToString("=") else { break }
            _ = scanner.scanString("=")
            let value: String?
            if scanner.scanString("\"") != nil {
                value = scanner.scanUpToString("\"") ?? ""
                _ = scanner.scanString("\"")
            } else {
                value = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: ","))
            }
            values[key.trimmingCharacters(in: .whitespaces).lowercased()] = value?.trimmingCharacters(in: .whitespaces)
        }
        guard let realm = values["realm"], let nonce = values["nonce"] else { return nil }
        self.realm = realm
        self.nonce = nonce
        algorithm = values["algorithm"] ?? "MD5"
        // "auth" when offered (also in "auth,auth-int").
        qop = values["qop"].flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("auth") ? "auth" : nil }
        opaque = values["opaque"]
    }

    static func hash(_ text: String, algorithm: String) -> String {
        let data = Data(text.utf8)
        if algorithm.uppercased().hasPrefix("SHA-256") {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The Authorization / Proxy-Authorization value for one request.
    func authorization(method: String, uri: String, user: String, password: String, cnonce: String = SIPMessage.random(16),
                       nc: Int = 1) -> String {
        let ha1 = Self.hash("\(user):\(realm):\(password)", algorithm: algorithm)
        let ha2 = Self.hash("\(method):\(uri)", algorithm: algorithm)
        let count = String(format: "%08x", nc)
        var value = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", algorithm=\(algorithm)"
        if let qop {
            let response = Self.hash("\(ha1):\(nonce):\(count):\(cnonce):\(qop):\(ha2)", algorithm: algorithm)
            value += ", response=\"\(response)\", qop=\(qop), nc=\(count), cnonce=\"\(cnonce)\""
        } else {
            value += ", response=\"\(Self.hash("\(ha1):\(nonce):\(ha2)", algorithm: algorithm))\""
        }
        if let opaque { value += ", opaque=\"\(opaque)\"" }
        return value
    }
}
