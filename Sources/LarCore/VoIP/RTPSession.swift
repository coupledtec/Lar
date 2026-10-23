#if !os(watchOS)
import AVFoundation
import Foundation
import Network
import os

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
    private var sent = 0, received = 0, skipped = 0
    static let log = Logger(subsystem: "com.coupled.lar", category: "rtp")

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
        Self.log.notice("media \(self.localPort) <-> \(remote.address, privacy: .public):\(remote.port), payload \(remote.payload), events \(remote.dtmfPayload.map(String.init) ?? "-", privacy: .public)")
        connection.stateUpdateHandler = { state in
            Self.log.notice("media connection: \(String(describing: state), privacy: .public)")
        }
        connection.start(queue: .global(qos: .userInteractive))
        receive(on: connection)
        let audio = AudioIO { [weak self] frame in self?.send(frame) }
        try audio.start()
        self.audio = audio
    }

    public func stop() {
        lock.withLock { Self.log.notice("media ended: sent \(self.sent), received \(self.received), skipped \(self.skipped)") }
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
            sent += 1
            if sent == 1 || sent % 500 == 0 { Self.log.info("sent \(self.sent) packets, received \(self.received)") }
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

    private func count(_ counter: ReferenceWritableKeyPath<RTPSession, Int>) {
        lock.withLock {
            self[keyPath: counter] += 1
            if counter == \.received, received == 1 || received % 500 == 0 {
                Self.log.info("received \(self.received) packets (skipped \(self.skipped))")
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                if let samples = self.decode(data) {
                    self.audio?.play(samples)
                    self.count(\.received)
                } else {
                    self.count(\.skipped)
                }
            }
            if let error { Self.log.error("media receive: \(error.localizedDescription, privacy: .public)") }
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

/// Microphone in, speaker out, at the call's 8 kHz; on the iPhone with the system's voice processing (echo
/// cancellation).
final class AudioIO: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let onFrame: ([Int16]) -> Void
    private let lock = NSLock()
    private var pending: [Int16] = []
    private var heard = false
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
        #if os(macOS)
        // On the Mac voice processing fails to build its device whenever there are virtual audio devices (meeting
        // and streaming apps add them), and a failed try leaves the engine unusable: the plain microphone, then.
        try run(voiceProcessing: false)
        #else
        do {
            try run(voiceProcessing: true)
        } catch {
            RTPSession.log.error("audio with voice processing: \(error.localizedDescription, privacy: .public)")
            try restartPlain()
        }
        #endif
    }

    /// A fresh engine without voice processing (one that failed to start with it stays unusable).
    private func restartPlain() throws {
        teardown()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        try run(voiceProcessing: false)
    }

    private func run(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch {
                RTPSession.log.error("voice processing: \(error.localizedDescription, privacy: .public)")
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        RTPSession.log.notice("microphone: \(inputFormat.channelCount) ch at \(inputFormat.sampleRate) Hz, voice processing \(input.isVoiceProcessingEnabled)")
        // The Mac's microphones come as several channels with no known layout (the converter's own downmix gives
        // silence): they're averaged here into one, then converted to the call's rate.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: callFormat) else { throw URLError(.cannotDecodeContentData) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let mixed = Self.mix(buffer, into: mono) else { return }
            self?.convert(mixed, with: converter)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
    }

    /// The average of the buffer's channels, as one float channel.
    static func mix(_ buffer: AVAudioPCMBuffer, into mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let channels = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let out = output.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channelCount : 1
        output.frameLength = buffer.frameLength
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += buffer.format.isInterleaved ? channels[0][frame * stride + channel] : channels[channel][frame]
            }
            out[frame] = sum / Float(channelCount)
        }
        return output
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 8000 / buffer.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: callFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { RTPSession.log.error("microphone conversion: \(error.localizedDescription, privacy: .public)") }
        guard let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return }
        let frames: [[Int16]] = lock.withLock {
            if !heard, UnsafeBufferPointer(start: samples, count: Int(output.frameLength)).contains(where: { $0 != 0 }) {
                heard = true
                RTPSession.log.notice("microphone: sound")
            }
            pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            var frames: [[Int16]] = []
            while pending.count >= 160 {
                frames.append(Array(pending.prefix(160)))
                pending.removeFirst(160)
            }
            return frames
        }
        frames.forEach(onFrame)
    }

    func play(_ samples: [Int16]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32_768 }
        player.scheduleBuffer(buffer)
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    func stop() {
        teardown()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
#endif
