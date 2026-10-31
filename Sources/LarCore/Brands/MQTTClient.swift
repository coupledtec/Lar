import Foundation
import Network
import Security

/// Just enough MQTT 3.1.1 for the robots' clouds (Roborock, Ecovacs, Eufy) and the Roomba on the home network: one
/// connection over TLS, subscribe, publish (QoS 0 or 1) and the messages that arrive, kept alive with pings.
/// A request and its answer travel as two messages: `request(_:)` publishes and waits for the first one that matches.
public actor MQTTClient {
    public struct Message: Sendable, Equatable {
        public var topic: String
        public var payload: Data
    }

    public struct Options: @unchecked Sendable {
        public var host: String
        public var port: UInt16
        public var tls = true
        public var clientID: String
        public var username: String?
        public var password: String?
        public var keepAlive: UInt16 = 60
        /// The Roomba's broker has a self-signed certificate (on the home network only).
        public var acceptAnyCertificate = false
        /// A client certificate, for the brokers that sign in with one (Eufy's).
        public var identity: SecIdentity?

        public init(host: String, port: UInt16, tls: Bool = true, clientID: String, username: String? = nil,
                    password: String? = nil, keepAlive: UInt16 = 60, acceptAnyCertificate: Bool = false,
                    identity: SecIdentity? = nil) {
            self.host = host
            self.port = port
            self.tls = tls
            self.clientID = clientID
            self.username = username
            self.password = password
            self.keepAlive = keepAlive
            self.acceptAnyCertificate = acceptAnyCertificate
            self.identity = identity
        }
    }

    static let connectTimeout: Duration = .seconds(8)

    public let options: Options
    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var buffer = Data()
    private var packetID: UInt16 = 0
    /// Acknowledgments (CONNACK, SUBACK, PUBACK) waited for, by packet type and id.
    private var acks: [String: CheckedContinuation<Data, Error>] = [:]
    private var waiters: [UUID: (match: @Sendable (Message) -> Bool, continuation: CheckedContinuation<Message, Error>)] = [:]
    /// The last messages and acknowledgments, for a waiter that registers just after its answer arrived.
    private var recent: [(at: ContinuousClock.Instant, message: Message)] = []
    private var earlyAcks: [String: Data] = [:]
    private var subscribed: Set<String> = []
    /// Every message that arrives, also the ones nobody waits for (a robot's own status updates).
    private let onMessage: @Sendable (Message) -> Void

    public init(_ options: Options, onMessage: @escaping @Sendable (Message) -> Void = { _ in }) {
        self.options = options
        self.onMessage = onMessage
    }

    public var isConnected: Bool { connection != nil }

    // MARK: Connecting

    public func connectIfNeeded() async throws {
        if connection != nil { return }
        guard let port = NWEndpoint.Port(rawValue: options.port) else { throw ProviderError.network(tr("porta inválida")) }
        let parameters: NWParameters
        if options.tls {
            let tls = NWProtocolTLS.Options()
            if let identity = options.identity, let local = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            }
            if options.acceptAnyCertificate {
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) },
                                                      .global(qos: .userInitiated))
            }
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(host: NWEndpoint.Host(options.host), port: port, using: parameters)
        self.connection = connection
        buffer = Data()
        subscribed = []
        do {
            try await Self.waitUntilReady(connection, host: options.host)
            reader = Task { [weak self] in await self?.readLoop() }
            let ack = try await send(MQTTPacket.connect(options), waitingFor: "connack")
            let code = ack.count >= 2 ? ack[ack.startIndex + 1] : 0xff
            guard code == 0 else {
                throw code == 4 || code == 5 ? ProviderError.unauthorized
                    : ProviderError.network(tr("O servidor recusou a conexão (\(code))"))
            }
            let keepAlive = options.keepAlive
            pinger = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double(max(keepAlive, 10)) * 0.8))
                    guard !Task.isCancelled else { return }
                    try? await self?.write(MQTTPacket.pingRequest)
                }
            }
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        reader?.cancel()
        pinger?.cancel()
        reader = nil
        pinger = nil
        if let connection {
            connection.send(content: MQTTPacket.disconnect, completion: .idempotent)
            connection.cancel()
        }
        connection = nil
        buffer = Data()
        subscribed = []
        recent = []
        earlyAcks = [:]
        let failure = ProviderError.network(tr("Conexão encerrada"))
        acks.values.forEach { $0.resume(throwing: failure) }
        acks = [:]
        waiters.values.forEach { $0.continuation.resume(throwing: failure) }
        waiters = [:]
    }

    // MARK: Subscribing and publishing

    public func subscribe(_ topics: [String]) async throws {
        try await connectIfNeeded()
        let new = topics.filter { !subscribed.contains($0) }
        guard !new.isEmpty else { return }
        let id = nextPacketID()
        _ = try await send(MQTTPacket.subscribe(new, id: id), waitingFor: "suback\(id)")
        subscribed.formUnion(new)
    }

    public func publish(_ topic: String, _ payload: Data, qos: UInt8 = 0) async throws {
        try await connectIfNeeded()
        if qos > 0 {
            let id = nextPacketID()
            _ = try await send(MQTTPacket.publish(topic, payload, qos: 1, id: id), waitingFor: "puback\(id)")
        } else {
            try await write(MQTTPacket.publish(topic, payload, qos: 0, id: 0))
        }
    }

    /// Publishes and returns the first message that `match` takes, within `timeout`.
    public func request(_ topic: String, _ payload: Data, qos: UInt8 = 0, timeout: Duration = .seconds(8),
                        match: @escaping @Sendable (Message) -> Bool) async throws -> Message {
        try await connectIfNeeded()
        let id = UUID(), since = ContinuousClock.now
        return try await withThrowingTaskGroup(of: Message.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.addWaiter(id, since: since, match: match, continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProviderError.network(tr("O aparelho não respondeu"))
            }
            try await publish(topic, payload, qos: qos)
            defer {
                group.cancelAll()
                Task { await self.dropWaiter(id) }
            }
            guard let message = try await group.next() else { throw ProviderError.network(tr("sem resposta")) }
            return message
        }
    }

    /// Waits for a message without sending anything (a robot that reports on its own).
    public func next(timeout: Duration, match: @escaping @Sendable (Message) -> Bool) async throws -> Message {
        try await connectIfNeeded()
        let id = UUID(), since = ContinuousClock.now
        return try await withThrowingTaskGroup(of: Message.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.addWaiter(id, since: since, match: match, continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProviderError.network(tr("O aparelho não respondeu"))
            }
            defer {
                group.cancelAll()
                Task { await self.dropWaiter(id) }
            }
            guard let message = try await group.next() else { throw ProviderError.network(tr("sem resposta")) }
            return message
        }
    }

    private func addWaiter(_ id: UUID, since: ContinuousClock.Instant, match: @escaping @Sendable (Message) -> Bool,
                           continuation: CheckedContinuation<Message, Error>) {
        if let early = recent.first(where: { $0.at >= since && match($0.message) }) {
            return continuation.resume(returning: early.message)
        }
        waiters[id] = (match, continuation)
    }

    private func dropWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func nextPacketID() -> UInt16 {
        packetID = packetID == .max ? 1 : packetID + 1
        return packetID
    }

    // MARK: Wire

    private func send(_ packet: Data, waitingFor key: String) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.addAck(key, continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.connectTimeout)
                throw ProviderError.network(tr("O servidor não respondeu"))
            }
            try await write(packet)
            defer {
                group.cancelAll()
                Task { await self.dropAck(key) }
            }
            guard let data = try await group.next() else { throw ProviderError.network(tr("sem resposta")) }
            return data
        }
    }

    private func addAck(_ key: String, _ continuation: CheckedContinuation<Data, Error>) {
        if let early = earlyAcks.removeValue(forKey: key) { return continuation.resume(returning: early) }
        acks[key] = continuation
    }

    private func acknowledge(_ key: String, _ body: Data) {
        if let waiting = acks.removeValue(forKey: key) {
            waiting.resume(returning: body)
        } else {
            earlyAcks[key] = body
        }
    }

    private func dropAck(_ key: String) {
        acks.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }

    private func write(_ data: Data) async throws {
        guard let connection else { throw ProviderError.network(tr("sem conexão")) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ProviderError.network(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readLoop() async {
        while !Task.isCancelled, let connection {
            do {
                let chunk = try await Self.receive(connection)
                buffer.append(chunk)
                while let (packet, consumed) = try MQTTPacket.unframe(buffer) {
                    buffer = Data(buffer.dropFirst(consumed))
                    try await handle(packet)
                }
            } catch {
                close()
                return
            }
        }
    }

    private func handle(_ packet: MQTTPacket.Incoming) async throws {
        switch packet.type {
        case 2: acknowledge("connack", packet.body)
        case 3:
            guard let message = MQTTPacket.parsePublish(packet) else { return }
            if message.qos == 1, let id = message.id { try await write(MQTTPacket.publishAck(id)) }
            let incoming = Message(topic: message.topic, payload: message.payload)
            onMessage(incoming)
            let now = ContinuousClock.now
            recent.removeAll { now - $0.at > .seconds(10) }
            recent.append((now, incoming))
            if recent.count > 50 { recent.removeFirst(recent.count - 50) }
            for (id, waiter) in waiters where waiter.match(incoming) {
                waiters[id] = nil
                waiter.continuation.resume(returning: incoming)
            }
        case 4, 9:
            guard packet.body.count >= 2 else { return }
            let id = UInt16(packet.body[packet.body.startIndex]) << 8 | UInt16(packet.body[packet.body.startIndex + 1])
            acknowledge((packet.type == 4 ? "puback" : "suback") + "\(id)", packet.body)
        default: break
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: ProviderError.network(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(throwing: ProviderError.network(tr("O servidor fechou a conexão")))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func waitUntilReady(_ connection: NWConnection, host: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = Once()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.run { continuation.resume() }
                        case .failed(let error), .waiting(let error):
                            once.run { continuation.resume(throwing: ProviderError.network(error.localizedDescription)) }
                        case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(for: connectTimeout)
                throw ProviderError.network(tr("Sem resposta de \(host)"))
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

/// MQTT 3.1.1 packets: a fixed header (type and flags, then the remaining length as a varint) and the body.
enum MQTTPacket {
    struct Incoming: Equatable {
        var type: UInt8
        var flags: UInt8
        var body: Data
    }

    struct Publish: Equatable {
        var topic: String
        var payload: Data
        var qos: UInt8
        var id: UInt16?
    }

    static func packet(_ type: UInt8, flags: UInt8 = 0, _ body: Data) -> Data {
        var out = Data([type << 4 | flags])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            out.append(byte)
        } while length > 0
        out.append(body)
        return out
    }

    static func string(_ value: String) -> Data { bytes(Data(value.utf8)) }

    static func bytes(_ value: Data) -> Data {
        var out = Data([UInt8(value.count >> 8), UInt8(value.count & 0xff)])
        out.append(value)
        return out
    }

    static func connect(_ options: MQTTClient.Options) -> Data {
        var body = string("MQTT")
        body.append(4) // protocol level 3.1.1
        var flags: UInt8 = 0x02 // clean session
        if options.username != nil { flags |= 0x80 }
        if options.password != nil { flags |= 0x40 }
        body.append(flags)
        body.append(contentsOf: [UInt8(options.keepAlive >> 8), UInt8(options.keepAlive & 0xff)])
        body.append(string(options.clientID))
        if let username = options.username { body.append(string(username)) }
        if let password = options.password { body.append(string(password)) }
        return packet(1, body)
    }

    static func subscribe(_ topics: [String], id: UInt16) -> Data {
        var body = Data([UInt8(id >> 8), UInt8(id & 0xff)])
        for topic in topics {
            body.append(string(topic))
            body.append(1) // QoS 1
        }
        return packet(8, flags: 0x02, body)
    }

    static func publish(_ topic: String, _ payload: Data, qos: UInt8, id: UInt16) -> Data {
        var body = string(topic)
        if qos > 0 { body.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xff)]) }
        body.append(payload)
        return packet(3, flags: qos << 1, body)
    }

    static func publishAck(_ id: UInt16) -> Data { packet(4, Data([UInt8(id >> 8), UInt8(id & 0xff)])) }

    static let pingRequest = packet(12, Data())
    static let disconnect = packet(14, Data())

    /// The first whole packet in `buffer` and how many bytes it took, or nil while it's still arriving.
    static func unframe(_ buffer: Data) throws -> (Incoming, Int)? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        var length = 0, multiplier = 1, index = start + 1
        while true {
            guard index < buffer.endIndex else { return nil }
            let byte = buffer[index]
            length += Int(byte & 0x7f) * multiplier
            index += 1
            if byte & 0x80 == 0 { break }
            multiplier *= 128
            guard multiplier <= 128 * 128 * 128 else { throw ProviderError.network(tr("mensagem inválida")) }
        }
        guard index + length <= buffer.endIndex else { return nil }
        let header = buffer[start]
        return (Incoming(type: header >> 4, flags: header & 0x0f, body: Data(buffer[index..<index + length])),
                index + length - start)
    }

    static func parsePublish(_ packet: Incoming) -> Publish? {
        let body = packet.body
        guard body.count >= 2 else { return nil }
        let start = body.startIndex
        let topicLength = Int(body[start]) << 8 | Int(body[start + 1])
        var index = start + 2 + topicLength
        guard index <= body.endIndex else { return nil }
        let topic = String(decoding: body[(start + 2)..<index], as: UTF8.self)
        let qos = (packet.flags >> 1) & 0x03
        var id: UInt16?
        if qos > 0 {
            guard index + 2 <= body.endIndex else { return nil }
            id = UInt16(body[index]) << 8 | UInt16(body[index + 1])
            index += 2
        }
        return Publish(topic: topic, payload: Data(body[index...]), qos: qos, id: id)
    }
}
