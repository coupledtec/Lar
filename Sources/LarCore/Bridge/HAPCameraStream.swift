#if os(macOS)
import AVFoundation
import CoreImage
import Darwin
import Foundation
import VideoToolbox

/// One camera's live video toward the Home app: the camera's HLS link played (muted) on the Mac, each frame
/// re-encoded as H.264 at the size and rate the iPhone asked for, cut in RTP packets (RFC 6184) and sent over SRTP.
/// Re-encoding (on the Mac's hardware encoder) means any camera stream fits what the Home app expects.
@MainActor
final class HAPCameraStream {
    struct Request {
        var host: String
        var isIPv6: Bool
        var port: UInt16
        var key: Data
        var salt: Data
        var ssrc: UInt32
        var payloadType: UInt8
        var width: Int
        var height: Int
        var fps: Int
        var bitrate: Int
        var mtu: Int
        var profile: Int
    }

    private let request: Request
    private let socket: UDPSocket
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var timer: Timer?
    private let sender: RTPSender
    private var encoder: VTCompressionSession?
    private var scaler: VTPixelTransferSession?
    private let started = Date()
    /// The newest frame (snapshots while streaming).
    private(set) var lastFrame: CVPixelBuffer?
    var onEnd: (() -> Void)?

    init?(url: URL, request: Request, socket: UDPSocket) {
        self.request = request
        self.socket = socket
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        sender = RTPSender(socket: socket, request: request)
        guard makeEncoder() else { return nil }
    }

    func start() {
        player.play()
        let interval = 1 / Double(max(5, min(30, request.fps)))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        socket.onReceive = { [weak self] in self?.sender.heard() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        sender.sendBye()
        socket.close()
    }

    private func pull() {
        // The iPhone stopped answering (RTCP): it left without saying.
        if sender.silentFor > 30, Date().timeIntervalSince(started) > 30 {
            onEnd?()
            return
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        lastFrame = frame
        encode(frame)
    }

    private func makeEncoder() -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(request.width), height: Int32(request.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        let profile: CFString = switch request.profile {
        case 2: kVTProfileLevel_H264_High_AutoLevel
        case 1: kVTProfileLevel_H264_Main_AutoLevel
        default: kVTProfileLevel_H264_Baseline_AutoLevel
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: request.bitrate * 1000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [request.bitrate * 1000 / 8 * 3 / 2, 1] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: request.fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        if let transfer {
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        }
        scaler = transfer
        return true
    }

    private var frameCount: Int64 = 0

    private func encode(_ frame: CVPixelBuffer) {
        guard let encoder else { return }
        var source = frame
        if CVPixelBufferGetWidth(frame) != request.width || CVPixelBufferGetHeight(frame) != request.height,
           let scaler, let pool = VTCompressionSessionGetPixelBufferPool(encoder) {
            var scaled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
            if let scaled, VTPixelTransferSessionTransferImage(scaler, from: frame, to: scaled) == noErr { source = scaled }
        }
        let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 90000)
        let forceKey = frameCount < 3
        frameCount += 1
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let sender = sender
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: source, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return }
            sender.send(sample)
        }
    }
}

/// Cuts encoded frames in RTP packets and sends them sealed, with a sender report every second.
final class RTPSender: @unchecked Sendable {
    private let socket: UDPSocket
    private let queue = DispatchQueue(label: "com.coupled.lar.rtp")
    private var srtp: SRTPContext
    private let ssrc: UInt32
    private let payloadType: UInt8
    private let maxPayload: Int
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private let timestampBase = UInt32.random(in: 0...UInt32.max)
    private var packets: UInt32 = 0
    private var octets: UInt32 = 0
    private var lastReport = Date.distantPast
    private var lastHeard = Date()
    private let lock = NSLock()

    init(socket: UDPSocket, request: HAPCameraStream.Request) {
        self.socket = socket
        srtp = SRTPContext(masterKey: request.key, masterSalt: request.salt)
        ssrc = request.ssrc
        payloadType = request.payloadType
        maxPayload = max(500, min(1400, request.mtu) - 12 - 10)
    }

    /// Seconds since the iPhone last sent anything (its RTCP reports).
    var silentFor: TimeInterval { lock.withLock { Date().timeIntervalSince(lastHeard) } }

    func heard() { lock.withLock { lastHeard = Date() } }

    func send(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample)
        else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var nals: [Data] = []
        if isKey {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                      parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    nals.append(Data(bytes: pointer, count: size))
                }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return }
        let data = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard size > 0, offset + size <= data.count else { break }
            nals.append(Data(data[offset..<offset + size]))
            offset += size
        }
        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let timestamp = timestampBase &+ UInt32(truncatingIfNeeded: Int64(seconds * 90000))
        queue.async { [self] in
            for (index, nal) in nals.enumerated() { packetize(nal, timestamp: timestamp, last: index == nals.count - 1) }
            if Date().timeIntervalSince(lastReport) >= 1 { report(timestamp: timestamp) }
        }
    }

    private func packetize(_ nal: Data, timestamp: UInt32, last: Bool) {
        let bytes = [UInt8](nal)
        guard let first = bytes.first else { return }
        if bytes.count <= maxPayload {
            emit(Data(bytes), timestamp: timestamp, marker: last)
            return
        }
        let indicator = (first & 0xE0) | 28
        var offset = 1
        while offset < bytes.count {
            let end = min(offset + maxPayload - 2, bytes.count)
            var header = first & 0x1F
            if offset == 1 { header |= 0x80 }
            if end == bytes.count { header |= 0x40 }
            emit(Data([indicator, header] + bytes[offset..<end]), timestamp: timestamp, marker: last && end == bytes.count)
            offset = end
        }
    }

    private func emit(_ payload: Data, timestamp: UInt32, marker: Bool) {
        var packet = Data([0x80, (marker ? 0x80 : 0) | payloadType])
        packet += withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
        packet += withUnsafeBytes(of: timestamp.bigEndian) { Data($0) }
        packet += withUnsafeBytes(of: ssrc.bigEndian) { Data($0) }
        packet += payload
        sequence &+= 1
        packets &+= 1
        octets &+= UInt32(payload.count)
        socket.send(srtp.protect(rtp: packet))
    }

    private func report(timestamp: UInt32) {
        lastReport = Date()
        let ntp = Date().timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(ntp), fraction = UInt32((ntp - floor(ntp)) * 4_294_967_296)
        var packet = Data([0x80, 200, 0, 6])
        for word in [ssrc, seconds, fraction, timestamp, packets, octets] {
            packet += withUnsafeBytes(of: word.bigEndian) { Data($0) }
        }
        socket.send(srtp.protect(rtcp: packet))
    }

    func sendBye() {
        queue.sync {
            var packet = Data([0x81, 203, 0, 1])
            packet += withUnsafeBytes(of: ssrc.bigEndian) { Data($0) }
            socket.send(srtp.protect(rtcp: packet))
        }
    }
}

/// A UDP socket on a port of its own, sending to the iPhone's video port; what comes back (RTCP) only tells it's
/// still there.
final class UDPSocket: @unchecked Sendable {
    private let descriptor: Int32
    private var destination = sockaddr_storage()
    private var destinationLength: socklen_t = 0
    private var source: DispatchSourceRead?
    let port: UInt16
    var onReceive: (() -> Void)?

    init?(host: String, port: UInt16, isIPv6: Bool) {
        let family = isIPv6 ? AF_INET6 : AF_INET
        var target = sockaddr_storage()
        var targetLength: socklen_t = 0
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        if isIPv6 {
            var local = sockaddr_in6()
            local.sin6_family = sa_family_t(AF_INET6)
            local.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            local.sin6_addr = in6addr_any
            var remote = sockaddr_in6()
            remote.sin6_family = sa_family_t(AF_INET6)
            remote.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            remote.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, host, &remote.sin6_addr) == 1,
                  withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }) == 0 else {
                Darwin.close(fd)
                return nil
            }
            withUnsafeBytes(of: remote) { raw in
                withUnsafeMutableBytes(of: &target) { $0.copyMemory(from: raw) }
            }
            targetLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var local = sockaddr_in()
            local.sin_family = sa_family_t(AF_INET)
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            var remote = sockaddr_in()
            remote.sin_family = sa_family_t(AF_INET)
            remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            remote.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &remote.sin_addr) == 1,
                  withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
                Darwin.close(fd)
                return nil
            }
            withUnsafeBytes(of: remote) { raw in
                withUnsafeMutableBytes(of: &target) { $0.copyMemory(from: raw) }
            }
            targetLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        var bound = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length) } }
        // sin_port and sin6_port are both at offset 2.
        self.port = withUnsafeBytes(of: bound) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
        descriptor = fd
        destination = target
        destinationLength = targetLength
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            if recv(self.descriptor, &buffer, buffer.count, 0) > 0 { self.onReceive?() }
        }
        source.resume()
        self.source = source
    }

    func send(_ data: Data) {
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, data.count, 0, $0, destinationLength)
                }
            }
        }
    }

    func close() {
        source?.cancel()
        source = nil
        Darwin.close(descriptor)
    }
}

/// Still pictures for the Home app's tiles: a frame of the live video, kept for a while so the tiles don't open a
/// stream every few seconds.
@MainActor
final class HAPSnapshots {
    private var cache: [String: (image: CGImage, at: Date)] = [:]
    private var loading: Set<String> = []
    private let context = CIContext()

    /// A JPEG at about `width`; the cached frame when fresh, otherwise a new one (up to ~10 s).
    func jpeg(for id: String, width: Int, live: CVPixelBuffer?, url: @escaping () async throws -> URL) async -> Data? {
        if let live, let image = context.createCGImage(CIImage(cvPixelBuffer: live), from: CIImage(cvPixelBuffer: live).extent) {
            cache[id] = (image, Date())
        }
        if let cached = cache[id] {
            if Date().timeIntervalSince(cached.at) > 60 { Task { await refresh(id, url: url) } }
            return encode(cached.image, width: width)
        }
        await refresh(id, url: url)
        return cache[id].flatMap { encode($0.image, width: width) }
    }

    private func refresh(_ id: String, url: () async throws -> URL) async {
        guard !loading.contains(id), let link = try? await url() else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        let item = AVPlayerItem(url: link)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time), let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                let image = CIImage(cvPixelBuffer: frame)
                if let cg = context.createCGImage(image, from: image.extent) { cache[id] = (cg, Date()) }
                return
            }
        }
    }

    private func encode(_ image: CGImage, width: Int) -> Data? {
        let source = CIImage(cgImage: image)
        let scale = min(1, Double(max(160, width)) / source.extent.width)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }
}
#endif
