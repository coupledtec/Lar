import Foundation
import Network

/// A client for the TV's own ADB over the network (port 5555, open while debugging is on), the same channel the
/// Android `adb` tool uses. One connection is kept open and reused; commands run one at a time on it.
/// Protocol: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/protocol.txt
public actor ADBClient {
    static let cnxn: UInt32 = 0x4e58_4e43, auth: UInt32 = 0x4854_5541, open: UInt32 = 0x4e45_504f
    static let okay: UInt32 = 0x5941_4b4f, clse: UInt32 = 0x4553_4c43, wrte: UInt32 = 0x4554_5257, stls: UInt32 = 0x534c_5453
    static let version: UInt32 = 0x0100_0001, maxData: UInt32 = 256 * 1024
    static let authToken: UInt32 = 1, authSignature: UInt32 = 2, authPublicKey: UInt32 = 3

    public static let connectTimeout: Duration = .seconds(3)
    public static let commandTimeout: Duration = .seconds(15)
    /// How long the TV's "Allow USB debugging?" prompt is waited on.
    public static let approvalTimeout: Duration = .seconds(60)

    public let host: String
    let port: UInt16
    let key: ADBKey
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextLocalID: UInt32 = 1
    private var tail: Task<Void, Never>?

    public init(host: String, port: UInt16 = 5555, key: ADBKey) {
        self.host = host
        self.port = port
        self.key = key
    }

    /// Runs a command in the TV's shell and returns what it printed. A dropped connection is reopened once.
    public func shell(_ command: String) async throws -> String {
        let previous = tail
        let task = Task { () throws -> String in
            await previous?.value
            return try await self.runRetrying(command)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    public func close() {
        connection?.cancel()
        connection = nil
        buffer = Data()
    }

    private func runRetrying(_ command: String) async throws -> String {
        do {
            return try await run(command)
        } catch let error as ADBError where error == .waitingForApproval || error == .rejected {
            throw error
        } catch {
            // The TV dropped an idle connection (or slept): once more on a fresh one.
            close()
            return try await run(command)
        }
    }

    private func run(_ command: String) async throws -> String {
        if connection == nil { try await connect() }
        let local = nextLocalID
        nextLocalID &+= 1
        try await send(Self.open, local, 0, Data("shell:\(command)\0".utf8))
        var remote: UInt32 = 0
        var output = Data()
        while true {
            let message = try await read(timeout: Self.commandTimeout)
            guard message.arg1 == local else { continue }
            switch message.command {
            case Self.okay:
                remote = message.arg0
            case Self.wrte:
                output.append(message.data)
                try await send(Self.okay, local, message.arg0, nil)
            case Self.clse:
                if remote == 0, message.arg0 == 0 { throw ADBError.protocolError("a TV recusou o comando") }
                try await send(Self.clse, local, message.arg0, nil)
                return String(decoding: output, as: UTF8.self)
            default:
                continue
            }
        }
    }

    // MARK: Connecting

    private func connect() async throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw ADBError.connection("porta inválida") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        buffer = Data()
        do {
            try await Self.waitUntilReady(connection)
            try await handshake()
        } catch {
            close()
            throw error
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = Once()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.run { continuation.resume() }
                        case .failed(let error), .waiting(let error):
                            once.run { continuation.resume(throwing: ADBError.connection("TV não responde (\(error.localizedDescription))")) }
                        case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(for: connectTimeout)
                throw ADBError.connection("A TV não respondeu (está ligada e na mesma rede?)")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func handshake() async throws {
        try await send(Self.cnxn, Self.version, Self.maxData, Data("host::\0".utf8))
        var signed = false, offeredKey = false
        while true {
            let message: Message
            do {
                message = try await read(timeout: offeredKey ? Self.approvalTimeout : Self.commandTimeout)
            } catch ADBError.connection where offeredKey {
                throw ADBError.waitingForApproval
            }
            switch message.command {
            case Self.cnxn:
                return
            case Self.stls:
                throw ADBError.protocolError("a TV pediu TLS (depuração sem fio); use a depuração USB pela rede")
            case Self.auth where message.arg0 == Self.authToken:
                if !signed {
                    try await send(Self.auth, Self.authSignature, 0, try key.sign(message.data))
                    signed = true
                } else if !offeredKey {
                    // Unknown key: send the public one; the TV shows "Allow USB debugging?".
                    try await send(Self.auth, Self.authPublicKey, 0, try key.publicKeyBlob(name: "lar@mac"))
                    offeredKey = true
                } else {
                    throw ADBError.rejected
                }
            default:
                throw ADBError.protocolError("resposta inesperada")
            }
        }
    }

    // MARK: Messages

    struct Message {
        var command: UInt32
        var arg0: UInt32
        var arg1: UInt32
        var data: Data
    }

    static func encode(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ data: Data?) -> Data {
        let payload = data ?? Data()
        var out = Data(capacity: 24 + payload.count)
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for value in [command, arg0, arg1, UInt32(payload.count), checksum, command ^ 0xffff_ffff] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }

    /// The header of a message, or nil while fewer than 24 bytes are in.
    static func decodeHeader(_ data: Data) throws -> (command: UInt32, arg0: UInt32, arg1: UInt32, length: Int)? {
        guard data.count >= 24 else { return nil }
        func word(_ index: Int) -> UInt32 {
            let start = data.startIndex + index * 4
            return data[start..<start + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        let command = word(0), length = Int(word(3))
        guard word(5) == command ^ 0xffff_ffff else { throw ADBError.protocolError("mensagem inválida") }
        guard length <= 1024 * 1024 else { throw ADBError.protocolError("mensagem grande demais") }
        return (command, word(1), word(2), length)
    }

    private func send(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ data: Data?) async throws {
        guard let connection else { throw ADBError.connection("sem conexão") }
        let bytes = Self.encode(command, arg0, arg1, data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ADBError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func read(timeout: Duration) async throws -> Message {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let header = try Self.decodeHeader(buffer), buffer.count >= 24 + header.length {
                let start = buffer.startIndex
                let data = buffer[(start + 24)..<(start + 24 + header.length)]
                buffer = Data(buffer[(start + 24 + header.length)...])
                return Message(command: header.command, arg0: header.arg0, arg1: header.arg1, data: Data(data))
            }
            let left = deadline - ContinuousClock.now
            guard left > .zero else { throw ADBError.connection("A TV parou de responder") }
            buffer.append(try await receive(timeout: left))
        }
    }

    private func receive(timeout: Duration) async throws -> Data {
        guard let connection else { throw ADBError.connection("sem conexão") }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if let error {
                            continuation.resume(throwing: ADBError.connection(error.localizedDescription))
                        } else if isComplete {
                            continuation.resume(throwing: ADBError.connection("a TV fechou a conexão"))
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ADBError.connection("A TV parou de responder")
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw ADBError.connection("sem dados") }
            return data
        }
    }
}

/// Runs a closure only the first time (NWConnection reports several states; the continuation resumes once).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
