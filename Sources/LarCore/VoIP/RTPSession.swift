#if !os(watchOS)
import AVFoundation
import Foundation
import Network

/// A call's audio: RTP over UDP (RFC 3550) with G.711, 20 ms per packet, from the microphone and to the speaker,
/// with the system's echo cancellation. Sends from the port it receives on, so a server behind NAT (or one that
/// relays media) finds its way back. Keys go as RFC 4733 events.
public final class RTPSession: @unchecked Sendable {
    public let localPort: UInt16
    private var connection: NWConnection?
    private var audio: AudioIO?
    private var remote: SDPAudio?
    private let lock = NSLock()
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var muted = false

    public init() {
        // An even port in the usual RTP range (RTCP would take the odd one above).
        localPort = UInt16.random(in: 20_000...29_999) & ~1
    }

    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// Starts sending and playing, once the other side's address and codec are known.
    public func start(remote: SDPAudio) throws {
        self.remote = remote
        guard let port = NWEndpoint.Port(rawValue: remote.port), let local = NWEndpoint.Port(rawValue: localPort) else { return }
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: local)
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: NWEndpoint.Host(remote.address), port: port, using: parameters)
        self.connection = connection
        connection.start(queue: .global(qos: .userInteractive))
        receive(on: connection)
        let audio = AudioIO { [weak self] frame in self?.send(frame) }
        try audio.start()
        self.audio = audio
    }

    public func stop() {
        audio?.stop()
        audio = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: Sending

    private func send(_ samples: [Int16]) {
        guard let remote, let connection else { return }
        let silent = isMuted
        let payload = samples.map { sample -> UInt8 in
            let value: Int16 = silent ? 0 : sample
            return remote.payload == 8 ? G711.encodeALaw(value) : G711.encodeMuLaw(value)
        }
        let packet = lock.withLock { () -> Data in
            let header = Self.header(payloadType: remote.payload, marker: false, sequence: sequence, timestamp: timestamp, ssrc: ssrc)
            sequence &+= 1
            timestamp &+= UInt32(samples.count)
            return header + Data(payload)
        }
        connection.send(content: packet, completion: .idempotent)
    }

    /// Keys during the call ("*1" opens many gates): each one as an RFC 4733 event, or as SIP INFO when the other
    /// side doesn't take events (the caller handles that case).
    public func sendDTMF(_ digits: String) async {
        guard let remote, let event = remote.dtmfPayload, let connection else { return }
        for digit in digits {
            guard let code = Self.dtmfCode(digit) else { continue }
            let start = lock.withLock { () -> UInt32 in
                let value = timestamp
                timestamp &+= 1600
                return value
            }
            // Three updates while pressed, then three end packets (the end is sent three times, as the RFC asks).
            for step in 1...6 {
                let isEnd = step > 3
                let duration = UInt16(min(step, 4) * 400)
                var body = Data([code, (isEnd ? 0x80 : 0) | 10])
                body.append(contentsOf: withUnsafeBytes(of: duration.bigEndian) { Array($0) })
                let packet = lock.withLock { () -> Data in
                    let header = Self.header(payloadType: event, marker: step == 1, sequence: sequence, timestamp: start, ssrc: ssrc)
                    sequence &+= 1
                    return header + body
                }
                connection.send(content: packet, completion: .idempotent)
                try? await Task.sleep(for: .milliseconds(isEnd ? 5 : 50))
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    static func dtmfCode(_ digit: Character) -> UInt8? {
        switch digit {
        case "0"..."9": UInt8(String(digit))
        case "*": 10
        case "#": 11
        case "A"..."D": UInt8(12 + Int(digit.asciiValue! - Character("A").asciiValue!))
        default: nil
        }
    }

    static func header(payloadType: UInt8, marker: Bool, sequence: UInt16, timestamp: UInt32, ssrc: UInt32) -> Data {
        var data = Data([0x80, (marker ? 0x80 : 0) | (payloadType & 0x7F)])
        data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian) { Array($0) })
        return data
    }

    // MARK: Receiving

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let samples = self.decode(data) { self.audio?.play(samples) }
            if error == nil, self.connection === connection { self.receive(on: connection) }
        }
    }

    /// The samples in an RTP packet of the call's codec (other payloads, like key events, are skipped).
    func decode(_ packet: Data) -> [Int16]? {
        Self.decode(packet, payloadType: remote?.payload ?? 0)
    }

    static func decode(_ packet: Data, payloadType: UInt8) -> [Int16]? {
        let bytes = [UInt8](packet)
        guard bytes.count > 12, bytes[0] >> 6 == 2, bytes[1] & 0x7F == payloadType else { return nil }
        var start = 12 + Int(bytes[0] & 0x0F) * 4
        if bytes[0] & 0x10 != 0, bytes.count >= start + 4 {
            start += 4 + Int(UInt16(bytes[start + 2]) << 8 | UInt16(bytes[start + 3])) * 4
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0, let padding = bytes.last { end -= Int(padding) }
        guard start < end else { return nil }
        return bytes[start..<end].map { payloadType == 8 ? G711.decodeALaw($0) : G711.decodeMuLaw($0) }
    }
}

/// Microphone in, speaker out, at the call's 8 kHz, with the system's voice processing (echo cancellation).
final class AudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let onFrame: ([Int16]) -> Void
    private var pending: [Int16] = []
    private let callFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!

    init(onFrame: @escaping ([Int16]) -> Void) {
        self.onFrame = onFrame
    }

    func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: callFormat) else { throw URLError(.cannotDecodeContentData) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer, with: converter)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        try engine.start()
        player.play()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 8000 / buffer.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: callFormat, frameCapacity: capacity) else { return }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard let samples = output.int16ChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        while pending.count >= 160 {
            onFrame(Array(pending.prefix(160)))
            pending.removeFirst(160)
        }
    }

    func play(_ samples: [Int16]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32_768 }
        player.scheduleBuffer(buffer)
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
#endif
