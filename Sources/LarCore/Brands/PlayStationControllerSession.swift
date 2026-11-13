import Foundation

/// The Lar as a DualSense for the PS5: a Remote Play session with its control channel (TCP) and its stream (Takion,
/// UDP), the keys exchanged with ECDH, and then the buttons and sticks sent as the stream's feedback packets. The
/// video and audio the console sends are dropped unread. One session at a time; it ends with `close()`, when the
/// console ends it, or when another Remote Play takes over.
public final class PlayStationControllerSession: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case connecting, ready, closed(String?)
    }

    static let streamPort: UInt16 = 9296

    let pairing: PlayStationRemotePlay.Pairing
    private let lock = NSLock()
    private var status = Status.connecting
    /// Called on a background thread when the status changes.
    public var onStatus: (@Sendable (Status) -> Void)?
    /// The console opened (with its current text) or closed a text field: nil when closed.
    public var onKeyboard: (@Sendable (String?) -> Void)?
    private var keyboardCounter: UInt32 = 0

    // Control channel.
    private var controlSocket: Int32 = -1
    private var crypt: PlayStationRemotePlay.Crypt?
    private var localCounter: UInt64 = 5
    private var remoteCounter: UInt64 = 0
    private var sessionID: String?

    // Stream.
    private var streamSocket: Int32 = -1
    private var tagLocal: UInt32 = 0
    private var tagRemote: UInt32 = 0
    private var sequence: UInt32 = 0
    private var keyPosition: UInt64 = 0
    private var gkLocal: PlayStationRemotePlay.GKCrypt?
    private var handshakeKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private var keys = Secp256k1.keyPair()
    private var bigSent = false

    // Controller.
    private var stateSequence: UInt16 = 0
    private var historySequence: UInt16 = 0
    private var history: [Data] = []
    private var sticks: (Int16, Int16, Int16, Int16) = (0, 0, 0, 0)
    private var pressed: Set<PlayStationRemotePlay.Button> = []

    /// Development traces (LAR_PS5_DEBUG=1), on standard error.
    static let debug = ProcessInfo.processInfo.environment["LAR_PS5_DEBUG"] != nil
    static func trace(_ text: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(Data(("ps5: " + text() + "\n").utf8)) }
    }

    init(pairing: PlayStationRemotePlay.Pairing) {
        self.pairing = pairing
    }

    var currentStatus: Status { lock.withLock { status } }

    private func set(_ new: Status) {
        let changed: Bool = lock.withLock {
            if case .closed = status { return false }
            status = new
            return true
        }
        if changed { onStatus?(new) }
    }

    // MARK: Opening

    /// Opens the session; returns once the console takes the controller (or throws).
    public static func open(_ pairing: PlayStationRemotePlay.Pairing,
                            onStatus: (@Sendable (Status) -> Void)? = nil) async throws -> PlayStationControllerSession {
        guard let registHex = pairing.registKey, let registKey = Data(hex: registHex),
              let rpHex = pairing.rpKey, let morning = Data(hex: rpHex), morning.count == 16 else {
            throw ProviderError.api(tr("Pareie o PS5 de novo (Ajustes → Jogos) para usar o controle."))
        }
        let nonce = try PlayStationRemotePlay.nonce(try await PlayStationRemotePlay.LAN.tcp(
            host: pairing.host, port: PlayStationRemotePlay.registPort,
            PlayStationRemotePlay.sessionRequest(host: pairing.host, registKey: registHex), timeout: 5))
        let session = PlayStationControllerSession(pairing: pairing)
        session.onStatus = onStatus
        let crypt = PlayStationRemotePlay.Crypt(nonce: nonce, morning: morning)
        session.crypt = crypt
        let request = PlayStationRemotePlay.controlRequest(host: pairing.host, registKey: registKey, crypt: crypt,
                                                           deviceID: PlayStationRemotePlay.deviceID())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                do {
                    try session.start(request)
                    continuation.resume()
                } catch {
                    session.close(reason: (error as? ProviderError)?.message)
                    continuation.resume(throwing: error)
                }
            }
        }
        return session
    }

    /// Runs on its own thread until the stream is ready; then the two readers keep going.
    private func start(_ request: Data) throws {
        controlSocket = try Self.connectTCP(host: pairing.host, port: PlayStationRemotePlay.registPort)
        try Self.write(controlSocket, request)
        var pending = try Self.readHead(controlSocket)
        guard let end = pending.range(of: Data("\r\n\r\n".utf8)) else { throw ProviderError.network(tr("O PS5 não respondeu")) }
        let head = String(decoding: pending[..<end.lowerBound], as: UTF8.self)
        Self.trace("ctrl head: \(head.replacingOccurrences(of: "\r\n", with: " | "))")
        guard head.hasPrefix("HTTP/1.1 200") else {
            let reason = PlayStationRemotePlay.headers(head)["RP-Application-Reason"].map { " (\($0))" } ?? ""
            throw ProviderError.api(tr("O PS5 recusou o controle\(reason). Feche o Remote Play em outro aparelho e tente de novo."))
        }
        // The server type, if sent, took the console's first counter.
        if PlayStationRemotePlay.headers(head)["RP-Server-Type"] != nil { remoteCounter = 1 }
        pending = Data(pending[end.upperBound...])

        // The console sends the session id first: the stream needs it.
        let deadline = Date().addingTimeInterval(10)
        while sessionID == nil, Date() < deadline {
            pending = try readControl(pending, timeout: 0.5)
        }
        guard sessionID != nil else { throw ProviderError.network(tr("O PS5 não abriu a sessão")) }
        let leftover = pending
        Thread.detachNewThread { [self] in controlLoop(leftover) }

        try openStream()
        try sendBig()
        let ready = Date().addingTimeInterval(10)
        while currentStatus == .connecting, Date() < ready { try readStream(timeout: 0.5) }
        guard currentStatus == .ready else { throw ProviderError.network(tr("O PS5 não aceitou o controle")) }
        Thread.detachNewThread { [self] in streamLoop() }
        Thread.detachNewThread { [self] in timerLoop() }
    }

    // MARK: Control channel

    private func controlLoop(_ pending: Data) {
        var pending = pending
        while true {
            if case .closed = currentStatus { return }
            do {
                pending = try readControl(pending, timeout: 1)
            } catch {
                Self.trace("ctrl closed: \(error)")
                close(reason: tr("O PS5 encerrou a sessão"))
                return
            }
        }
    }

    /// Reads what's there (up to `timeout`) and handles every whole message.
    private func readControl(_ pending: Data, timeout: Double) throws -> Data {
        var pending = pending
        Self.setTimeout(controlSocket, timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(controlSocket, &buffer, buffer.count, 0)
        if count == 0 { throw ProviderError.network("closed") }
        if count > 0 { pending.append(contentsOf: buffer[0..<count]) }
        while pending.count >= 8 {
            let base = pending.startIndex
            let size = Int(pending[base]) << 24 | Int(pending[base + 1]) << 16 | Int(pending[base + 2]) << 8 | Int(pending[base + 3])
            guard pending.count >= 8 + size else { break }
            let type = UInt16(pending[base + 4]) << 8 | UInt16(pending[base + 5])
            var payload = Data(pending[(base + 8)..<(base + 8 + size)])
            pending = Data(pending[(base + 8 + size)...])
            if !payload.isEmpty, let crypt {
                payload = crypt.crypt(payload, encrypt: false, counter: remoteCounter)
                remoteCounter += 1
            }
            handleControl(type, payload)
        }
        return pending
    }

    private func handleControl(_ type: UInt16, _ payload: Data) {
        Self.trace("ctrl msg 0x\(String(type, radix: 16)) \(payload.count)b \(BrandCrypto.hex(payload.prefix(40)))")
        switch type {
        case 0x33 where sessionID == nil:
            // "J" and the id's ASCII letters and digits.
            let id = String(decoding: payload.dropFirst(), as: UTF8.self)
            sessionID = id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && id.count >= 24 ? id : "sessionId4321"
            // The console's keyboard comes to the Lar (the signature is the one PS Remote Play sends).
            lock.withLock {
                sendControl(0xd, Data([0, 0, 0, 1, 0, 0, 5, 0xae, 0, 0, 0, 0, 0, 0, 0, 0]))
                sendControl(0x20, Data([1]))
            }
        case 0x21:
            // A text field opened: 28 bytes, the text's length, the text.
            let text = payload.count > 32 ? String(decoding: payload.dropFirst(32), as: UTF8.self) : ""
            onKeyboard?(text)
        case 0x22:
            onKeyboard?(nil)
        case 0xfe:
            lock.withLock { sendControl(0x1fe, Data()) }
        case 0x4:
            if let pin = pairing.loginPIN, !pin.isEmpty { lock.withLock { sendControl(0x8004, Data(pin.utf8)) } }
        default:
            break
        }
    }

    private func sendControl(_ type: UInt16, _ payload: Data) {
        guard let crypt else { return }
        let body: Data
        if payload.isEmpty {
            body = Data()
        } else {
            body = crypt.crypt(payload, encrypt: true, counter: localCounter)
            localCounter += 1
        }
        let size = UInt32(payload.count)
        let header = Data([UInt8(size >> 24), UInt8((size >> 16) & 0xff), UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
                           UInt8(type >> 8), UInt8(type & 0xff), 0, 0])
        try? Self.write(controlSocket, header + body)
    }

    /// Commands on the control channel during the session (rest mode, home).
    public func send(_ command: PlayStationRemotePlay.Command) {
        lock.withLock { sendControl(command.rawValue, Data()) }
    }

    /// The text field's new content, then Enter (accept) or cancel.
    public func type(_ text: String, submit: Bool = true) {
        let bytes = Data(text.utf8)
        lock.withLock {
            keyboardCounter += 1
            let length = Self.be32(UInt32(bytes.count))
            sendControl(0x23, Self.be32(keyboardCounter) + length + Data(count: 0x18) + length + bytes)
            if submit { sendControl(0x25, Data([0, 0, 0, 0])) }
        }
    }

    public func cancelKeyboard() {
        lock.withLock { sendControl(0x25, Data([0, 0, 0, 1])) }
    }

    // MARK: Stream (Takion)

    private func openStream() throws {
        guard let address = PlayStationRemotePlay.LAN.address(pairing.host, port: Self.streamPort) else {
            throw ProviderError.api(tr("Endereço inválido: \(pairing.host)"))
        }
        streamSocket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard streamSocket >= 0 else { throw ProviderError.network("socket") }
        var bufferSize: Int32 = 0x19000
        setsockopt(streamSocket, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        var target = address
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(streamSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw ProviderError.network(tr("O PS5 não respondeu")) }

        tagLocal = UInt32.random(in: 1...UInt32.max)
        sequence = tagLocal
        // INIT → INIT_ACK (with the console's tag and a cookie) → COOKIE → COOKIE_ACK.
        var initAck: Data?
        for _ in 0..<3 where initAck == nil {
            let payload = Self.be32(tagLocal) + Self.be32(0x19000) + Self.be16(0x64) + Self.be16(0x64) + Self.be32(tagLocal)
            try Self.write(streamSocket, Data([0]) + Self.messageHeader(tag: 0, keyPosition: 0, chunk: 1, flags: 0, size: payload.count) + payload)
            initAck = receiveChunk(2, timeout: 2)
        }
        guard let initAck, initAck.count >= 0x30 else { throw ProviderError.network(tr("O PS5 não abriu o canal do controle")) }
        tagRemote = Self.readBE32(initAck, 0)
        Self.trace("init ack tag \(tagRemote)")
        let cookie = initAck.subdata(in: (initAck.startIndex + 0x10)..<(initAck.startIndex + 0x30))
        var cookieAck: Data?
        for _ in 0..<3 where cookieAck == nil {
            try Self.write(streamSocket, Data([0]) + Self.messageHeader(tag: tagRemote, keyPosition: 0, chunk: 0xa, flags: 0, size: cookie.count) + cookie)
            cookieAck = receiveChunk(0xb, timeout: 2)
        }
        Self.trace("cookie ack \(cookieAck != nil)")
        guard cookieAck != nil else { throw ProviderError.network(tr("O PS5 não abriu o canal do controle")) }
    }

    /// Waits for a control chunk of `type`, returning its payload.
    private func receiveChunk(_ type: UInt8, timeout: Double) -> Data? {
        Self.setTimeout(streamSocket, timeout)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let count = recv(streamSocket, &buffer, buffer.count, 0)
            guard count >= 17, buffer[0] & 0xf == 0, buffer[13] == type else { continue }
            return Data(buffer[17..<count])
        }
        return nil
    }

    private func sendBig() throws {
        guard let crypt, let sessionID else { return }
        let big = PlayStationRemotePlay.big(sessionID: sessionID, handshakeKey: handshakeKey, publicKey: keys.publicKey, crypt: crypt)
        // Split as the console reads it: the first part with its header, the rest as continuations, the last flagged.
        let mtu = 1454 - 50
        var offset = 0
        var first = true
        var remaining = big.count
        while mtu < remaining + 26 || (mtu < remaining + 25 && !first) {
            let size = first ? mtu - 26 : mtu - 25
            sendData(big.subdata(in: offset..<offset + size), channel: 1, flags: 0, continuation: !first)
            first = false
            offset += size
            remaining -= size
        }
        if remaining > 0 { sendData(big.subdata(in: offset..<big.count), channel: 1, flags: 1, continuation: !first) }
        Self.trace("big sent \(big.count)b")
        bigSent = true
    }

    private func streamLoop() {
        while true {
            if case .closed = currentStatus { return }
            do { try readStream(timeout: 1) } catch { return }
        }
    }

    private var lastReceived = Date()

    private func readStream(timeout: Double) throws {
        Self.setTimeout(streamSocket, timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(streamSocket, &buffer, buffer.count, 0)
        if count < 0 {
            if Date().timeIntervalSince(lastReceived) > 15 { close(reason: tr("O PS5 parou de responder")) }
            return
        }
        lastReceived = Date()
        // Only control packets matter: video and audio are dropped.
        guard count >= 17, buffer[0] & 0xf == 0, Self.readBE32(Data(buffer[1..<5]), 0) == tagLocal else { return }
        let chunk = buffer[13]
        Self.trace("stream chunk \(buffer[13]) flags \(buffer[14]) \(count)b")
        let flags = buffer[14]
        guard chunk == 0, count >= 17 + 9 else { return }
        let payload = Data(buffer[17..<count])
        let seq = Self.readBE32(payload, 0)
        _ = flags
        // Handled first, then acknowledged (BANG's acknowledgement already goes signed with the new keys).
        if payload[payload.startIndex + 8] == 0 { handleMessage(payload.dropFirst(9)) }
        lock.withLock { sendDataAck(seq) }
    }

    private func handleMessage(_ message: Data) {
        Self.trace("stream message \(String(describing: PlayStationRemotePlay.messageType(message))) \(BrandCrypto.hex(message.prefix(60)))")
        switch PlayStationRemotePlay.messageType(message) {
        case .bang:
            guard let (publicKey, signature) = PlayStationRemotePlay.bang(message),
                  BrandCrypto.hmacSHA256(key: handshakeKey, publicKey) == signature,
                  let secret = Secp256k1.sharedSecret(keys.privateKey, publicKey: publicKey) else {
                close(reason: tr("O PS5 recusou a troca de chaves"))
                return
            }
            lock.withLock { gkLocal = PlayStationRemotePlay.GKCrypt(index: 2, handshakeKey: handshakeKey, secret: secret) }
        case .streamInfo:
            guard currentStatus == .connecting else { return }
            lock.withLock {
                sendData(PlayStationRemotePlay.simpleMessage(.streamInfoAck), channel: 9, flags: 1)
                sendData(PlayStationRemotePlay.controllerConnection(), channel: 1, flags: 1)
            }
            set(.ready)
        case .disconnect:
            close(reason: tr("O PS5 encerrou a sessão"))
        default:
            break
        }
    }

    /// Advances the key position for `size` bytes (rounded as the console does), once the stream is encrypted.
    private func advance(_ size: Int) -> UInt64 {
        guard gkLocal != nil else { return 0 }
        let current = keyPosition
        keyPosition += UInt64(size + size % 16)
        return current
    }

    /// A data chunk on a channel, tagged with the stream's GMAC once encrypted.
    private func sendData(_ data: Data, channel: UInt16, flags: UInt8, continuation: Bool = false) {
        let position = advance(data.count)
        let seq = sequence
        sequence &+= 1
        var body = Self.be32(seq) + Self.be16(channel) + Self.be16(0)
        if !continuation { body.append(0) }
        body.append(data)
        var packet = Data([0]) + Self.messageHeader(tag: tagRemote, keyPosition: position, chunk: 0, flags: flags, size: body.count) + body
        sign(&packet, position)
        try? Self.write(streamSocket, packet)
    }

    private func sendDataAck(_ seq: UInt32) {
        let position = advance(29)
        let body = Self.be32(seq) + Self.be32(0x19000) + Self.be16(0) + Self.be16(0)
        var packet = Data([0]) + Self.messageHeader(tag: tagRemote, keyPosition: position, chunk: 3, flags: 0, size: body.count) + body
        sign(&packet, position)
        try? Self.write(streamSocket, packet)
    }

    /// The control packet's GMAC, computed with its GMAC and key position zeroed.
    private func sign(_ packet: inout Data, _ position: UInt64) {
        guard let gkLocal else { return }
        let keyField = packet.subdata(in: 9..<13)
        packet.replaceSubrange(5..<13, with: Data(count: 8))
        let tag = gkLocal.gmac(packet, at: position)
        packet.replaceSubrange(5..<9, with: tag)
        packet.replaceSubrange(9..<13, with: keyField)
    }

    /// A feedback packet (state or history): its payload encrypted, its key position and GMAC in the header.
    private func sendFeedback(_ header: Data, _ payload: Data) {
        guard let gkLocal else { return }
        let position = advance(payload.count + 16)
        var packet = header + Data(count: 8) + gkLocal.crypt(payload, at: position + 16)
        packet.replaceSubrange(4..<8, with: Self.be32(UInt32(truncatingIfNeeded: position)))
        let tag = gkLocal.gmac(packet, at: position)
        packet.replaceSubrange(8..<12, with: tag)
        try? Self.write(streamSocket, packet)
    }

    // MARK: Controller

    private func sendState() {
        let state = PlayStationRemotePlay.feedbackState(leftX: sticks.0, leftY: sticks.1, rightX: sticks.2, rightY: sticks.3)
        let seq = stateSequence
        stateSequence &+= 1
        sendFeedback(Data([6]) + Self.be16(seq) + Data([0]), state)
    }

    private func sendHistory() {
        guard !history.isEmpty else { return }
        let events = history.prefix(8)
        sendFeedback(Data([1]) + Self.be16(historySequence &- 1) + Data([UInt8(events.count - 1)]), events.reduce(Data(), +))
    }

    /// Presses or releases a button.
    public func set(_ button: PlayStationRemotePlay.Button, pressed down: Bool) {
        lock.withLock {
            guard currentStatusUnlocked == .ready, pressed.contains(button) != down else { return }
            if down { pressed.insert(button) } else { pressed.remove(button) }
            // Newest first; each event takes the next number.
            history.insert(button.event(down), at: 0)
            if history.count > 16 { history.removeLast(history.count - 16) }
            historySequence &+= 1
            sendHistory()
        }
        resendHistoryTail()
    }

    /// A tap: pressed, then released a moment later.
    public func tap(_ button: PlayStationRemotePlay.Button) {
        set(button, pressed: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { self.set(button, pressed: false) }
    }

    /// The sticks, −1…1 each (up is −1 on Y).
    public func setSticks(left: (Double, Double), right: (Double, Double)) {
        func value(_ v: Double) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        lock.withLock {
            sticks = (value(left.0), value(left.1), value(right.0), value(right.1))
            sendState()
        }
    }

    private var currentStatusUnlocked: Status { status }

    /// UDP drops packets: the last history goes again a few times so a release isn't lost.
    private func resendHistoryTail() {
        for delay in [0.02, 0.05, 0.1, 0.2] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.lock.withLock { self?.sendHistory() }
            }
        }
    }

    /// The state every 200 ms and the stream's heartbeat every second, so the console keeps the controller.
    private func timerLoop() {
        var tick = 0
        while true {
            if case .closed = currentStatus { return }
            usleep(200_000)
            tick += 1
            lock.withLock {
                sendState()
                if tick % 5 == 0 { sendData(PlayStationRemotePlay.simpleMessage(.heartbeat), channel: 1, flags: 1) }
            }
        }
    }

    // MARK: Closing

    public func close(reason: String? = nil) {
        let wasOpen: Bool = lock.withLock {
            if case .closed = status { return false }
            if bigSent, gkLocal != nil { sendData(PlayStationRemotePlay.disconnectMessage(), channel: 1, flags: 1) }
            status = .closed(reason)
            return true
        }
        guard wasOpen else { return }
        onStatus?(.closed(reason))
        if controlSocket >= 0 { Darwin.close(controlSocket) }
        if streamSocket >= 0 { Darwin.close(streamSocket) }
    }

    // MARK: Bytes and sockets

    static func be32(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]) }
    static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xff)]) }
    static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    /// Tag, GMAC (zero until signed), key position, chunk type and flags, and the size (+4).
    static func messageHeader(tag: UInt32, keyPosition: UInt64, chunk: UInt8, flags: UInt8, size: Int) -> Data {
        be32(tag) + Data(count: 4) + be32(UInt32(truncatingIfNeeded: keyPosition)) + Data([chunk, flags]) + be16(UInt16(size + 4))
    }

    static func setTimeout(_ socket: Int32, _ seconds: Double) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func write(_ socket: Int32, _ data: Data) throws {
        let sent = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, data.count, 0) }
        if sent != data.count { throw ProviderError.network(tr("O PS5 não respondeu")) }
    }

    static func connectTCP(host: String, port: UInt16) throws -> Int32 {
        guard var address = PlayStationRemotePlay.LAN.address(host, port: port) else { throw ProviderError.api(tr("Endereço inválido: \(host)")) }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw ProviderError.network("socket") }
        setTimeout(socket, 5)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            throw ProviderError.network(tr("O PS5 não respondeu"))
        }
        return socket
    }

    static func readHead(_ socket: Int32) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while out.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { throw ProviderError.network(tr("O PS5 não respondeu")) }
            out.append(contentsOf: buffer[0..<count])
        }
        return out
    }
}
