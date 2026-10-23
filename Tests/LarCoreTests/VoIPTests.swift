import Foundation
import Testing
@testable import LarCore

@Suite struct SIPBasicsTests {
    @Test func digestMatchesRFC2617() throws {
        let challenge = #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
        let digest = try #require(SIPDigest(challenge: challenge))
        #expect(digest.qop == "auth")
        let value = digest.authorization(method: "GET", uri: "/dir/index.html", user: "Mufasa", password: "Circle Of Life",
                                         cnonce: "0a4f113b", nc: 1)
        #expect(value.contains(#"response="6629fae49393a05397450978507c4ef1""#))
        #expect(value.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
    }

    @Test func parsesAResponseWithCompactHeaders() throws {
        let text = "SIP/2.0 401 Unauthorized\r\nv: SIP/2.0/UDP 10.0.0.2:5060;branch=z9hG4bKx;received=200.1.2.3;rport=40000\r\n"
            + "f: <sip:100@pbx.example>;tag=a\r\nt: <sip:100@pbx.example>;tag=b\r\ni: abc@lar\r\nCSeq: 1 REGISTER\r\n"
            + "WWW-Authenticate: Digest realm=\"pbx\",\r\n nonce=\"n1\"\r\nl: 0\r\n\r\n"
        let message = try #require(SIPMessage.parse(Data(text.utf8)))
        #expect(message.statusCode == 401)
        #expect(message.method == "REGISTER")
        #expect(message.callID == "abc@lar")
        #expect(message.cseq == 1)
        #expect(SIPMessage.parameter("received", in: message.header("Via") ?? "") == "200.1.2.3")
        #expect(SIPMessage.parameter("rport", in: message.header("Via") ?? "") == "40000")
        #expect(SIPMessage.parameter("tag", in: message.header("To") ?? "") == "b")
        #expect(SIPDigest(challenge: message.header("WWW-Authenticate") ?? "")?.nonce == "n1")
        #expect(SIPMessage.parse(message.serialized())?.statusCode == 401)
    }

    @Test func names() {
        #expect(SIPMessage.displayName(in: #""Portaria" <sip:200@pbx>;tag=1"#) == "Portaria")
        #expect(SIPMessage.displayName(in: "<sip:200@pbx>") == "200")
        #expect(SIPMessage.uri(in: #""Portaria" <sip:200@pbx>;tag=1"#) == "sip:200@pbx")
    }

    @Test func g711RoundTrips() {
        #expect(G711.encodeMuLaw(0) == 0xFF)
        #expect(G711.decodeMuLaw(0xFF) == 0)
        #expect(G711.encodeALaw(0) == 0xD5)
        for sample: Int16 in [-32_000, -8000, -1000, -100, 0, 100, 1000, 8000, 32_000] {
            let mu = Int(G711.decodeMuLaw(G711.encodeMuLaw(sample))), a = Int(G711.decodeALaw(G711.encodeALaw(sample)))
            // Logarithmic: about 3% error at most, a few units near zero.
            let tolerance = max(40, abs(Int(sample)) / 16)
            #expect(abs(mu - Int(sample)) <= tolerance, "μ \(sample) → \(mu)")
            #expect(abs(a - Int(sample)) <= tolerance, "A \(sample) → \(a)")
        }
    }

    @Test func sdpOfferAndAnswer() throws {
        let offer = SDPAudio.make(address: "192.168.1.10", port: 40_000)
        let parsed = try #require(SDPAudio.parse(offer))
        #expect(parsed == SDPAudio(address: "192.168.1.10", port: 40_000, payload: 0, dtmfPayload: 101))
        let alawOnly = "v=0\r\no=- 1 1 IN IP4 1.2.3.4\r\ns=-\r\nc=IN IP4 1.2.3.4\r\nt=0 0\r\nm=audio 5000 RTP/AVP 18 8\r\na=rtpmap:8 PCMA/8000\r\n"
        #expect(SDPAudio.parse(Data(alawOnly.utf8)) == SDPAudio(address: "1.2.3.4", port: 5000, payload: 8, dtmfPayload: nil))
        #expect(SDPAudio.parse(Data("m=audio 5000 RTP/AVP 18\r\nc=IN IP4 1.2.3.4\r\n".utf8)) == nil)
    }
}

/// A PBX in the test: takes what the phone sends and answers like a server would.
final class FakePBX: SIPTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sentMessages: [SIPMessage] = []
    var handle: (SIPMessage, FakePBX) -> Void = { _, _ in }

    init() { (incoming, continuation) = AsyncStream<Data>.makeStream() }

    var sent: [SIPMessage] { lock.withLock { sentMessages } }

    func start() async throws {}
    func stop() async {}
    func localAddress() async -> (host: String, port: UInt16) { ("192.168.1.20", 5062) }

    func send(_ data: Data) async {
        guard let message = SIPMessage.parse(data) else { return }
        lock.withLock { sentMessages.append(message) }
        handle(message, self)
    }

    func deliver(_ message: SIPMessage) { continuation.yield(message.serialized()) }

    func reply(_ request: SIPMessage, _ code: Int, _ reason: String, headers: [(String, String)] = [], body: Data = Data(), toTag: String? = "srv") {
        var to = request.header("To") ?? ""
        if let toTag, SIPMessage.parameter("tag", in: to) == nil { to += ";tag=\(toTag)" }
        var via = request.header("Via") ?? ""
        if via.hasSuffix(";rport") { via += "=40001;received=200.10.20.30" }
        let base: [(String, String)] = [("Via", via), ("From", request.header("From") ?? ""), ("To", to),
                                        ("Call-ID", request.callID ?? ""), ("CSeq", request.header("CSeq") ?? "")]
        deliver(SIPMessage(startLine: "SIP/2.0 \(code) \(reason)", headers: (base + headers).map { (name: $0.0, value: $0.1) }, body: body))
    }
}

/// Events from the phone, collected.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SIPEvent] = []
    func add(_ event: SIPEvent) { lock.withLock { all.append(event) } }
    var events: [SIPEvent] { lock.withLock { all } }

    func wait(for check: @escaping (SIPEvent) -> Bool) async -> Bool {
        for _ in 0..<60 {
            if events.contains(where: check) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

@Suite struct SIPClientTests {
    static let account = SIPAccount(server: "pbx.example", user: "1001", password: "segredo")

    @Test func registersWithDigestAndLearnsThePublicAddress() async throws {
        let pbx = FakePBX(), log = EventLog()
        pbx.handle = { message, pbx in
            guard message.method == "REGISTER" else { return }
            if let auth = message.header("Authorization") {
                let digest = SIPDigest(challenge: "Digest realm=\"pbx\", nonce=\"n1\"")!
                let cnonce = SIPMessage.parameter("cnonce", in: auth.replacingOccurrences(of: ", ", with: ";"))?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let expected = digest.authorization(method: "REGISTER", uri: "sip:pbx.example", user: "1001", password: "segredo",
                                                    cnonce: cnonce ?? "")
                pbx.reply(message, expected == auth ? 200 : 403, expected == auth ? "OK" : "Forbidden", headers: [("Expires", "300")])
            } else {
                pbx.reply(message, 401, "Unauthorized", headers: [("WWW-Authenticate", "Digest realm=\"pbx\", nonce=\"n1\"")])
            }
        }
        let phone = SIPClient(account: Self.account, transport: pbx) { log.add($0) }
        await phone.start()
        #expect(await log.wait { $0 == .registration(.registered) })
        // After learning it, the phone registers again with the address the server sees.
        #expect(pbx.sent.last?.header("Contact")?.contains("200.10.20.30:40001") == true)
        await phone.stop()
    }

    @Test func incomingCallRingsIsAnsweredAndHungUpByTheOtherSide() async throws {
        let pbx = FakePBX(), log = EventLog()
        pbx.handle = { message, pbx in
            if message.method == "REGISTER" { pbx.reply(message, 200, "OK") }
        }
        let phone = SIPClient(account: Self.account, transport: pbx) { log.add($0) }
        await phone.start()
        let offer = SDPAudio.make(address: "10.0.0.5", port: 30_000, payloads: [8])
        let invite = SIPMessage.request("INVITE", uri: "sip:1001@192.168.1.20:5062", headers: [
            ("Via", "SIP/2.0/UDP pbx.example;branch=z9hG4bKin1"), ("From", "\"Portaria\" <sip:200@pbx.example>;tag=p1"),
            ("To", "<sip:1001@pbx.example>"), ("Call-ID", "call-1"), ("CSeq", "1 INVITE"), ("Contact", "<sip:200@10.0.0.5>"),
            ("Content-Type", "application/sdp"),
        ], body: offer)
        pbx.deliver(invite)
        #expect(await log.wait { $0 == .incoming(callID: "call-1", from: "Portaria") })
        #expect(pbx.sent.contains { $0.statusCode == 180 })
        let media = await phone.answer("call-1", sdp: SDPAudio.make(address: "192.168.1.20", port: 40_000))
        #expect(media == SDPAudio(address: "10.0.0.5", port: 30_000, payload: 8, dtmfPayload: 101))
        let ok = try #require(pbx.sent.last { $0.statusCode == 200 && $0.method == "INVITE" })
        #expect(SDPAudio.parse(ok.body)?.port == 40_000)
        #expect(SIPMessage.parameter("tag", in: ok.header("To") ?? "") != nil)

        let bye = SIPMessage.request("BYE", uri: "sip:1001@192.168.1.20:5062", headers: [
            ("Via", "SIP/2.0/UDP pbx.example;branch=z9hG4bKbye"), ("From", "\"Portaria\" <sip:200@pbx.example>;tag=p1"),
            ("To", ok.header("To") ?? ""), ("Call-ID", "call-1"), ("CSeq", "2 BYE"),
        ])
        pbx.deliver(bye)
        #expect(await log.wait { if case .ended("call-1", _) = $0 { true } else { false } })
        #expect(pbx.sent.contains { $0.method == "BYE" && $0.statusCode == 200 })
        await phone.stop()
    }

    @Test func outgoingCallWithProxyAuthIsAnsweredAndHungUp() async throws {
        let pbx = FakePBX(), log = EventLog()
        pbx.handle = { message, pbx in
            switch message.method {
            case "REGISTER": pbx.reply(message, 200, "OK")
            case "INVITE" where message.isRequest:
                if message.header("Proxy-Authorization") == nil {
                    pbx.reply(message, 407, "Proxy Authentication Required",
                              headers: [("Proxy-Authenticate", "Digest realm=\"pbx\", nonce=\"n2\", qop=\"auth\"")])
                } else {
                    pbx.reply(message, 180, "Ringing")
                    pbx.reply(message, 200, "OK", headers: [("Contact", "<sip:200@10.0.0.5>"), ("Content-Type", "application/sdp")],
                              body: SDPAudio.make(address: "10.0.0.5", port: 30_002, payloads: [0]))
                }
            case "BYE" where message.isRequest: pbx.reply(message, 200, "OK")
            default: break
            }
        }
        let phone = SIPClient(account: Self.account, transport: pbx) { log.add($0) }
        await phone.start()
        let callID = await phone.dial("200", offer: SDPAudio.make(address: "192.168.1.20", port: 40_002))
        #expect(await log.wait { $0 == .ringing(callID: callID) })
        #expect(await log.wait { if case .answered(callID, let media) = $0 { media.port == 30_002 } else { false } })
        let invites = pbx.sent.filter { $0.isRequest && $0.method == "INVITE" }
        #expect(invites.count == 2)
        #expect(invites.last?.cseq == 2)
        #expect(pbx.sent.filter { $0.isRequest && $0.method == "ACK" }.count == 2)
        // The ACK for the 200 goes to the other side's Contact.
        #expect(pbx.sent.last { $0.isRequest && $0.method == "ACK" }?.startLine == "ACK sip:200@10.0.0.5 SIP/2.0")
        await phone.hangup(callID)
        #expect(pbx.sent.contains { $0.isRequest && $0.method == "BYE" && $0.startLine.contains("sip:200@10.0.0.5") })
        #expect(await log.wait { if case .ended(callID, _) = $0 { true } else { false } })
        await phone.stop()
    }
}

@Suite struct RTPTests {
    @Test func packetsRoundTrip() throws {
        let samples: [Int16] = [0, 1000, -1000, 8000]
        let header = RTPSession.header(payloadType: 8, marker: true, sequence: 7, timestamp: 160, ssrc: 42)
        #expect(header.count == 12)
        #expect(header[1] == 0x88)
        let packet = header + Data(samples.map(G711.encodeALaw))
        let decoded = try #require(RTPSession.decode(packet, payloadType: 8))
        #expect(decoded.count == 4)
        #expect(abs(Int(decoded[1]) - 1000) < 64)
        // Another payload type (a key event) isn't audio.
        #expect(RTPSession.decode(packet, payloadType: 0) == nil)
    }

    @Test func keyCodes() {
        #expect(RTPSession.dtmfCode("1") == 1)
        #expect(RTPSession.dtmfCode("*") == 10)
        #expect(RTPSession.dtmfCode("#") == 11)
        #expect(RTPSession.dtmfCode("x") == nil)
    }
}
