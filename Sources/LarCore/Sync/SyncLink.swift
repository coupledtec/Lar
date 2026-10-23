import CryptoKit
import Foundation
import Network

/// The Mac–iPhone connection: TLS with a pre-shared key, so only devices that know the key can talk (and nobody on the
/// network can read them). The key is the Mac's long-term sync key, or, while pairing, the code it shows.
enum SyncLink {
    static let serviceType = "_lar-sync._tcp"
    static let pairingServiceType = "_lar-pair._tcp"

    /// TLS-PSK parameters from a secret: the key is HMAC-SHA256 of a fixed label with the secret.
    static func parameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = HMAC<SHA256>.authenticationCode(for: Data("Lar sync".utf8), using: SymmetricKey(data: secret))
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("Lar".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
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
                throw SyncError.connection("O Mac não respondeu")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
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
            guard ContinuousClock.now < deadline else { throw SyncError.connection("O Mac parou de responder") }
            let connection = connection
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: SyncError.connection(error.localizedDescription))
                    } else if isComplete {
                        continuation.resume(throwing: SyncError.connection("conexão encerrada"))
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
        case .notPaired: "Pareie este iPhone com o Mac"
        case .wrongCode: "Código errado; confira o que o Mac mostra"
        case .macNotFound: "Nenhum Mac com o Lar aberto na rede"
        }
    }
}
