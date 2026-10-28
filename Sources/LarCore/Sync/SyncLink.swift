import CryptoKit
import Foundation
import Network

/// The Mac–iPhone connection: TLS with a pre-shared key, so only devices that know the key can talk (and nobody on the
/// network can read them). The key is the Mac's long-term sync key, or, while pairing, the code it shows.
///
/// The key exchange is ECDHE on top of the key: someone who recorded a pairing can't try the million codes against
/// the recording afterwards (with plain PSK they could, and then read the long-term key sent inside it).
enum SyncLink {
    static let serviceType = "_lar-sync._tcp"
    static let pairingServiceType = "_lar-pair._tcp"
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905).
    static let cipherSuite: UInt16 = 0xCCAC

    /// TLS-PSK parameters from a secret: the key is HMAC-SHA256 of a fixed label with the secret.
    static func parameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = HMAC<SHA256>.authenticationCode(for: Data("Lar sync".utf8), using: SymmetricKey(data: secret))
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("Lar".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: cipherSuite)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// The pairing code as the secret.
    static func pairingSecret(_ code: String) -> Data { Data("pair:\(code)".utf8) }
}

/// One framed JSON message at a time over an NWConnection.
actor SyncConnection {
    private let connection: NWConnection
    private var buffer = Data()
    static let timeout: Duration = .seconds(8)

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let connection = connection
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = Once()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.run { continuation.resume() }
                        case .failed(let error), .waiting(let error):
                            once.run { continuation.resume(throwing: SyncError.connection(error.localizedDescription)) }
                        case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw SyncError.connection(tr("O Mac não respondeu"))
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// The cipher suite the two sides agreed on, once started (tests).
    var negotiatedCipherSuite: UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }

    func send(_ message: SyncMessage) async throws {
        let data = TVRemoteProtocol.frame(try JSONEncoder().encode(message))
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SyncError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> SyncMessage {
        let deadline = ContinuousClock.now + Self.timeout
        while true {
            if let (message, consumed) = try TVRemoteProtocol.unframe(buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                return try JSONDecoder().decode(SyncMessage.self, from: message)
            }
            guard ContinuousClock.now < deadline else { throw SyncError.connection(tr("O Mac parou de responder")) }
            let connection = connection
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: SyncError.connection(error.localizedDescription))
                    } else if isComplete {
                        continuation.resume(throwing: SyncError.connection(tr("conexão encerrada")))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            buffer.append(chunk)
        }
    }

    func close() { connection.cancel() }
}

public enum SyncError: Error, Equatable, Sendable {
    case connection(String)
    case notPaired
    case wrongCode
    case macNotFound

    public var message: String {
        switch self {
        case .connection(let message): message
        case .notPaired: tr("Pareie este iPhone com o Mac")
        case .wrongCode: tr("Código errado; confira o que o Mac mostra")
        case .macNotFound: tr("Nenhum Mac com o Lar aberto na rede")
        }
    }
}
