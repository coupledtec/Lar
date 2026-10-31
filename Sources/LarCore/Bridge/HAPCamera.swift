#if os(macOS)
import Foundation

/// The camera's TLVs (types 1, 2, ...; repeated items separated by an empty type-0 item).
struct CameraTLV {
    var items: [(UInt8, Data)] = []

    init(_ items: [(UInt8, Data)] = []) { self.items = items }

    init(decoding data: Data) {
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let type = data[index], length = Int(data[index + 1])
            let end = min(index + 2 + length, data.endIndex)
            items.append((type, Data(data[(index + 2)..<end])))
            index = end
        }
    }

    subscript(type: UInt8) -> Data? { items.first { $0.0 == type }?.1 }

    var encoded: Data {
        items.reduce(into: Data()) { out, item in
            out.append(contentsOf: [item.0, UInt8(item.1.count)])
            out.append(item.1)
        }
    }

    static func list(_ type: UInt8, _ values: [Data]) -> [(UInt8, Data)] {
        values.enumerated().flatMap { index, value -> [(UInt8, Data)] in
            index == 0 ? [(type, value)] : [(UInt8(0), Data()), (type, value)]
        }
    }

    static func byte(_ value: UInt8) -> Data { Data([value]) }
    static func uint16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
    static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    static func integer(_ data: Data?) -> Int? {
        guard let data, !data.isEmpty else { return nil }
        return data.reversed().reduce(0) { $0 << 8 | Int($1) }
    }
}

/// The Home app's side of a camera: what it can stream, the endpoints, and the streams themselves.
@MainActor
final class HAPCameras {
    /// The camera's characteristics (service 8): supported video, audio and RTP, the selected stream, the
    /// streaming status, the endpoints, and Active.
    nonisolated static let characteristics: [HAPCharacteristic] = [
        HAPCharacteristic(iid: 9, type: "114", format: "tlv8", perms: ["pr"]),
        HAPCharacteristic(iid: 10, type: "115", format: "tlv8", perms: ["pr"]),
        HAPCharacteristic(iid: 11, type: "116", format: "tlv8", perms: ["pr"]),
        HAPCharacteristic(iid: 12, type: "117", format: "tlv8", perms: ["pr", "pw"]),
        HAPCharacteristic(iid: 13, type: "120", format: "tlv8", perms: ["pr", "ev"]),
        HAPCharacteristic(iid: 14, type: "118", format: "tlv8", perms: ["pr", "pw"]),
        HAPCharacteristic(iid: 15, type: "B0", format: "uint8", perms: ["pr", "pw", "ev"], validValues: [0, 1]),
    ]

    nonisolated static let supportedVideo: String = {
        let parameters = CameraTLV(CameraTLV.list(1, [0, 1, 2].map { CameraTLV.byte($0) })
            + CameraTLV.list(2, [0, 1, 2].map { CameraTLV.byte($0) })
            + [(3, CameraTLV.byte(0))]).encoded
        let sizes = [(1920, 1080, 30), (1280, 720, 30), (640, 360, 30), (480, 270, 30), (320, 180, 30), (1280, 960, 30),
                     (1024, 768, 30), (640, 480, 30), (480, 360, 30), (320, 240, 15)]
        let attributes = CameraTLV.list(3, sizes.map {
            CameraTLV([(1, CameraTLV.uint16($0.0)), (2, CameraTLV.uint16($0.1)), (3, CameraTLV.byte(UInt8($0.2)))]).encoded
        })
        let configuration = CameraTLV([(1, CameraTLV.byte(0)), (2, parameters)] + attributes).encoded
        return CameraTLV([(1, configuration)]).encoded.base64EncodedString()
    }()

    /// AAC-ELD and Opus, mono, 16 and 24 kHz, no comfort noise. No audio is sent: the Home app shows the video alone.
    nonisolated static let supportedAudio: String = {
        func codec(_ type: UInt8, rate: UInt8) -> Data {
            let parameters = CameraTLV([(1, CameraTLV.byte(1)), (2, CameraTLV.byte(0)), (3, CameraTLV.byte(rate))]).encoded
            return CameraTLV([(1, CameraTLV.byte(type)), (2, parameters)]).encoded
        }
        return CameraTLV(CameraTLV.list(1, [codec(3, rate: 2), codec(3, rate: 1), codec(2, rate: 1)])
            + [(2, CameraTLV.byte(0))]).encoded.base64EncodedString()
    }()

    nonisolated static let supportedRTP = CameraTLV([(2, CameraTLV.byte(0))]).encoded.base64EncodedString()

    private struct Endpoint {
        var session: Data
        var request: HAPCameraStream.Request
        var socket: UDPSocket
        var response: String
    }

    private var endpoints: [Int: Endpoint] = [:]
    private var streams: [Int: (session: Data, stream: HAPCameraStream)] = [:]
    private var selected: [Int: String] = [:]
    private var active: [Int: Int] = [:]
    let snapshots = HAPSnapshots()
    /// Tells the subscribed controllers that a camera's status changed.
    var onStatusChange: ((Int) -> Void)?

    func value(_ iid: Int, aid: Int) -> Any? {
        switch iid {
        case 9: Self.supportedVideo
        case 10: Self.supportedAudio
        case 11: Self.supportedRTP
        case 12: selected[aid] ?? ""
        case 13: CameraTLV([(1, CameraTLV.byte(streams[aid] == nil ? 0 : 1))]).encoded.base64EncodedString()
        case 14: endpoints[aid]?.response ?? ""
        case 15: active[aid] ?? 1
        default: nil
        }
    }

    /// A write to a camera's characteristic; `local` is the Mac's address on the controller's connection.
    func write(_ iid: Int, aid: Int, value: Any, local: String?, url: @escaping () async throws -> URL) -> HAPStatus {
        switch iid {
        case 15:
            active[aid] = (value as? NSNumber)?.intValue ?? 1
            return .ok
        case 14:
            guard let text = value as? String, let data = Data(base64Encoded: text) else { return .invalidValue }
            return setupEndpoints(CameraTLV(decoding: data), aid: aid, local: local)
        case 12:
            guard let text = value as? String, let data = Data(base64Encoded: text) else { return .invalidValue }
            selected[aid] = text
            return select(CameraTLV(decoding: data), aid: aid, url: url)
        default:
            return .readOnly
        }
    }

    private func setupEndpoints(_ tlv: CameraTLV, aid: Int, local: String?) -> HAPStatus {
        guard let session = tlv[1], let address = tlv[3].map(CameraTLV.init(decoding:)),
              let video = tlv[4].map(CameraTLV.init(decoding:)),
              let host = address[2].map({ String(decoding: $0, as: UTF8.self) }),
              let port = CameraTLV.integer(address[3]), let key = video[2], let salt = video[3] else { return .invalidValue }
        let isIPv6 = CameraTLV.integer(address[1]) == 1
        let ssrc = UInt32.random(in: 1...UInt32.max)
        guard let socket = UDPSocket(host: host, port: UInt16(port), isIPv6: isIPv6) else { return .communicationFailure }
        endpoints[aid]?.socket.close()
        var mine = Self.address(local, ipv6: isIPv6)
        if mine.isEmpty { mine = isIPv6 ? "::" : "0.0.0.0" }
        let accessory = CameraTLV([(1, CameraTLV.byte(isIPv6 ? 1 : 0)), (2, Data(mine.utf8)),
                                   (3, CameraTLV.uint16(Int(socket.port))), (4, CameraTLV.uint16(Int(socket.port)))]).encoded
        let srtp = CameraTLV([(1, CameraTLV.byte(0)), (2, key), (3, salt)]).encoded
        let audio = tlv[5] ?? srtp
        let response = CameraTLV([(1, session), (2, CameraTLV.byte(0)), (3, accessory), (4, srtp), (5, audio),
                                  (6, CameraTLV.uint32(ssrc)), (7, CameraTLV.uint32(ssrc &+ 1))]).encoded
        let request = HAPCameraStream.Request(host: host, isIPv6: isIPv6, port: UInt16(port), key: key, salt: salt, ssrc: ssrc,
                                              payloadType: 99, width: 1280, height: 720, fps: 30, bitrate: 800, mtu: 1378,
                                              profile: 1)
        endpoints[aid] = Endpoint(session: session, request: request, socket: socket, response: response.base64EncodedString())
        return .ok
    }

    private func select(_ tlv: CameraTLV, aid: Int, url: @escaping () async throws -> URL) -> HAPStatus {
        guard let control = tlv[1].map(CameraTLV.init(decoding:)), let command = CameraTLV.integer(control[2]) else {
            return .invalidValue
        }
        switch command {
        case 0:
            stop(aid)
            return .ok
        case 1, 4:
            guard var endpoint = endpoints[aid] else { return .invalidValue }
            if let video = tlv[2].map(CameraTLV.init(decoding:)) {
                if let parameters = video[2].map(CameraTLV.init(decoding:)), let profile = CameraTLV.integer(parameters[1]) {
                    endpoint.request.profile = profile
                }
                if let attributes = video[3].map(CameraTLV.init(decoding:)) {
                    endpoint.request.width = CameraTLV.integer(attributes[1]) ?? endpoint.request.width
                    endpoint.request.height = CameraTLV.integer(attributes[2]) ?? endpoint.request.height
                    endpoint.request.fps = CameraTLV.integer(attributes[3]) ?? endpoint.request.fps
                }
                if let rtp = video[4].map(CameraTLV.init(decoding:)) {
                    endpoint.request.payloadType = UInt8(CameraTLV.integer(rtp[1]) ?? 99)
                    endpoint.request.bitrate = CameraTLV.integer(rtp[3]) ?? endpoint.request.bitrate
                    endpoint.request.mtu = CameraTLV.integer(rtp[5]) ?? endpoint.request.mtu
                }
            }
            stop(aid, keepEndpoint: true)
            endpoints[aid] = nil
            let request = endpoint.request, socket = endpoint.socket, session = endpoint.session
            Task {
                guard let link = try? await url(),
                      let stream = HAPCameraStream(url: link, request: request, socket: socket) else {
                    HAPBridge.log.error("camera \(aid): no stream")
                    socket.close()
                    return
                }
                stream.onEnd = { [weak self] in self?.stop(aid) }
                streams[aid] = (session, stream)
                stream.start()
                onStatusChange?(aid)
            }
            return .ok
        default:
            return .ok
        }
    }

    func stop(_ aid: Int, keepEndpoint: Bool = false) {
        if let running = streams.removeValue(forKey: aid) {
            running.stream.stop()
            onStatusChange?(aid)
        }
        if !keepEndpoint, let endpoint = endpoints.removeValue(forKey: aid) { endpoint.socket.close() }
    }

    func stopAll() {
        for aid in Array(streams.keys) + Array(endpoints.keys) { stop(aid) }
    }

    func snapshot(aid: Int, id: String, width: Int, url: @escaping () async throws -> URL) async -> Data? {
        await snapshots.jpeg(for: id, width: width, live: streams[aid]?.stream.lastFrame, url: url)
    }

    /// The address part of an endpoint ("192.168.0.5", or an IPv6 one without its interface); an IPv4 address seen
    /// as IPv6 ("::ffff:192.168.0.5") is turned back when the controller is on IPv4.
    static func address(_ local: String?, ipv6: Bool) -> String {
        guard var text = local else { return "" }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if !ipv6, text.lowercased().hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        return text
    }
}
#endif
