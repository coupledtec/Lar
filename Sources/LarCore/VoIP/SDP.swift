import Foundation

/// The audio part of a call's description (RFC 4566): where to send RTP, and which codec.
public struct SDPAudio: Equatable, Sendable {
    public var address: String
    public var port: UInt16
    /// 0 (PCMU) or 8 (PCMA).
    public var payload: UInt8
    /// RFC 4733 telephone-event (keys during the call), when the other side has it.
    public var dtmfPayload: UInt8?

    static let dtmfDefault: UInt8 = 101

    /// Our offer or answer: both G.711 laws (or the one chosen) and the keypad events.
    static func make(address: String, port: UInt16, payloads: [UInt8] = [0, 8], dtmf: UInt8 = dtmfDefault) -> Data {
        let session = UInt32.random(in: 1...UInt32.max)
        var lines = [
            "v=0", "o=Lar \(session) \(session) IN IP4 \(address)", "s=Lar", "c=IN IP4 \(address)", "t=0 0",
            "m=audio \(port) RTP/AVP \((payloads.map(String.init) + [String(dtmf)]).joined(separator: " "))",
        ]
        for payload in payloads { lines.append("a=rtpmap:\(payload) \(payload == 0 ? "PCMU" : "PCMA")/8000") }
        lines += ["a=rtpmap:\(dtmf) telephone-event/8000", "a=fmtp:\(dtmf) 0-15", "a=ptime:20", "a=sendrecv"]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The other side's audio, if it offers a G.711 we speak.
    static func parse(_ body: Data) -> SDPAudio? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var session: String?, media: String?, port: UInt16?, payloads: [UInt8] = [], dtmf: UInt8?
        var inAudio = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                let parts = line.dropFirst(2).split(separator: " ")
                inAudio = parts.first == "audio"
                if inAudio, parts.count > 3 {
                    port = UInt16(parts[1])
                    payloads = parts.dropFirst(3).compactMap { UInt8($0) }
                }
            } else if line.hasPrefix("c=IN IP4 ") {
                let address = String(line.dropFirst(9)).split(separator: "/").first.map(String.init)
                if inAudio { media = address } else { session = address }
            } else if inAudio, line.hasPrefix("a=rtpmap:"), line.lowercased().contains("telephone-event") {
                dtmf = UInt8(line.dropFirst(9).split(separator: " ").first ?? "")
            }
        }
        guard let address = media ?? session, let port, port > 0,
              let payload = payloads.first(where: { $0 == 0 || $0 == 8 }) else { return nil }
        return SDPAudio(address: address, port: port, payload: payload, dtmfPayload: dtmf)
    }
}
