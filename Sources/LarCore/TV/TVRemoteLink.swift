import CryptoKit
import Foundation
import Network
import Security

/// One TLS connection to a TV's remote service, with this device's certificate: sends and receives whole messages.
/// The TV's certificate is self-signed, so no authority vouches for it: the first one seen after pairing is pinned
/// (`pin`, its SHA-256) and any other is refused. Its public key is kept for the pairing secret.
actor TVRemoteLink {
    static let connectTimeout: Duration = .seconds(4)

    let host: String
    let port: UInt16
    private let identity: TVRemoteIdentity
    private var connection: NWConnection?
    private var buffer = Data()
    private let serverCertificate = Locked<SecCertificate?>(nil)
    private let pin: String?

    init(host: String, port: UInt16, identity: TVRemoteIdentity, pin: String? = nil) {
        self.host = host
        self.port = port
        self.identity = identity
        self.pin = pin
    }

    /// The TV certificate's SHA-256, once connected.
    var serverFingerprint: String? { serverCertificate.value.map(Self.fingerprint) }

    static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    var isOpen: Bool { connection != nil }

    func open() async throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw TVRemoteError.connection(tr("porta inválida")) }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let local = sec_identity_create(identity.identity) { sec_protocol_options_set_local_identity(options, local) }
        let certificate = serverCertificate, pin = pin
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            certificate.update { $0 = leaf }
            guard let pin else { return complete(true) }
            complete(leaf.map(Self.fingerprint) == pin)
        }, .global(qos: .userInitiated))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: tls))
        self.connection = connection
        buffer = Data()
        do {
            try await Self.waitUntilReady(connection)
        } catch {
            close()
            throw error
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
        buffer = Data()
    }

    /// The TV's public key, once connected.
    func serverPublicNumbers() throws -> RSAPublicNumbers {
        guard let certificate = serverCertificate.value, let key = SecCertificateCopyKey(certificate),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data?, let numbers = RSAPublicNumbers(pkcs1: der)
        else { throw TVRemoteError.protocolError(tr("certificado da TV ilegível")) }
        return numbers
    }

    func send(_ message: Data) async throws {
        guard let connection else { throw TVRemoteError.connection(tr("sem conexão")) }
        let bytes = TVRemoteProtocol.frame(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TVRemoteError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// The next whole message; nil timeout waits as long as the connection lives.
    func receive(timeout: Duration? = nil) async throws -> Data {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while true {
            if let (message, consumed) = try TVRemoteProtocol.unframe(buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                return message
            }
            let left = deadline.map { $0 - ContinuousClock.now }
            if let left, left <= .zero { throw TVRemoteError.connection(tr("A TV parou de responder")) }
            buffer.append(try await receiveChunk(timeout: left))
        }
    }

    private func receiveChunk(timeout: Duration?) async throws -> Data {
        guard let connection else { throw TVRemoteError.connection(tr("sem conexão")) }
        let read: @Sendable () async throws -> Data = {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: Self.describe(error))
                    } else if isComplete {
                        continuation.resume(throwing: TVRemoteError.connection(tr("a TV fechou a conexão")))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        }
        guard let timeout else { return try await read() }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await read() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TVRemoteError.connection(tr("A TV parou de responder"))
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw TVRemoteError.connection(tr("sem dados")) }
            return data
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
                            once.run { continuation.resume(throwing: describe(error)) }
                        case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(for: connectTimeout)
                throw TVRemoteError.connection(tr("A TV não respondeu (está ligada e na mesma rede?)"))
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// A TLS refusal means the TV doesn't know this certificate.
    static func describe(_ error: NWError) -> TVRemoteError {
        if case .tls = error { return .notPaired }
        return .connection("TV não responde (\(error.localizedDescription))")
    }
}
