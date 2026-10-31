import Foundation
import Network

/// The Mac's side: answers the paired iPhones with the shared state and takes theirs when newer. Pairing runs only
/// while the Mac shows its code, on a separate service whose key is that code; it hands the iPhone the long-term key.
@MainActor
public final class SyncServer {
    public private(set) var pairingCode: String?
    private var listener: NWListener?
    private var pairingListener: NWListener?
    private let state: @MainActor () -> SyncState
    private let apply: @MainActor (SyncState) -> Void
    /// A timer handed over by an iPhone; false when the Mac doesn't know the device.
    private let offTimer: @MainActor (String, Double?) -> Bool
    /// The Mac's own SmartThings claim, told to the iPhones (whose claims it records).
    private let claim: @MainActor () -> SmartThingsClaims.Claim?
    private let port: NWEndpoint.Port
    private let advertise: Bool

    nonisolated(unsafe) static var keyAccount = "sync-key"

    /// - Parameters:
    ///   - state: the Mac's current shared state; `apply`: takes an iPhone's newer one.
    ///   - port, advertise: a fixed port without Bonjour, for tests.
    public init(port: NWEndpoint.Port = .any, advertise: Bool = true,
                state: @escaping @MainActor () -> SyncState, apply: @escaping @MainActor (SyncState) -> Void,
                offTimer: @escaping @MainActor (String, Double?) -> Bool = { _, _ in false },
                claim: @escaping @MainActor () -> SmartThingsClaims.Claim? = { nil }) {
        self.offTimer = offTimer
        self.claim = claim
        self.port = port
        self.advertise = advertise
        self.state = state
        self.apply = apply
    }

    /// The long-term key every paired iPhone has (made once).
    static func key() -> Data {
        if let saved = Keychain.read(keyAccount).flatMap({ Data(base64Encoded: $0) }) { return saved }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        Keychain.write(key.base64EncodedString(), account: keyAccount, label: "Lar – sincronização")
        return key
    }

    public func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: SyncLink.parameters(secret: Self.key()), on: port)
        if advertise { listener.service = NWListener.Service(type: SyncLink.serviceType) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in await self?.serve(SyncConnection(connection)) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stopPairing()
    }

    /// The port it listens on, once started (tests).
    public var listeningPort: UInt16? { listener?.port?.rawValue }

    private func serve(_ connection: SyncConnection) async {
        defer { Task { await connection.close() } }
        do {
            try await connection.start()
            while true {
                switch try await connection.receive() {
                case .get:
                    try await connection.send(.state(state()))
                case .put(let incoming):
                    apply(incoming)
                    try await connection.send(.ok)
                case .offTimer(let id, let seconds):
                    try await connection.send(offTimer(id, seconds) ? .ok : .error("aparelho desconhecido no Mac"))
                case .claim(let install, let theirs):
                    SmartThingsClaims.record(theirs, install: install)
                    try await connection.send(.claim(install: SmartThingsClaims.installID, claim: claim()))
                default:
                    try await connection.send(.error(tr("pedido inválido")))
                }
            }
        } catch {
            // The iPhone closes the connection when it's done.
        }
    }

    // MARK: Pairing

    /// Wrong codes before the code shown stops working (a million codes can't be tried one by one).
    static let pairingAttempts = 5
    private var failedPairings = 0
    /// Pairing stopped by itself (an iPhone paired, or too many wrong codes): the Mac hides the code.
    public var onPairingStopped: (() -> Void)?

    /// Shows a new code; the first iPhone that connects with it gets the key, then pairing stops.
    @discardableResult
    public func startPairing(port: NWEndpoint.Port = .any) throws -> String {
        stopPairing()
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let listener = try NWListener(using: SyncLink.parameters(secret: SyncLink.pairingSecret(code)), on: port)
        if advertise { listener.service = NWListener.Service(type: SyncLink.pairingServiceType) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                let link = SyncConnection(connection)
                do {
                    try await link.start()
                    try await link.send(.key(Self.key()))
                    _ = try? await link.receive()
                    self?.pairingEnded()
                } catch {
                    // A wrong code fails the handshake.
                    if let self, self.pairingCode == code {
                        self.failedPairings += 1
                        if self.failedPairings >= Self.pairingAttempts { self.pairingEnded() }
                    }
                }
                await link.close()
            }
        }
        listener.start(queue: .main)
        pairingListener = listener
        pairingCode = code
        return code
    }

    public var pairingPort: UInt16? { pairingListener?.port?.rawValue }

    public func stopPairing() {
        pairingListener?.cancel()
        pairingListener = nil
        pairingCode = nil
        failedPairings = 0
    }

    private func pairingEnded() {
        stopPairing()
        onPairingStopped?()
    }

    /// A new key: every paired iPhone has to pair again.
    public func forgetPairedDevices() throws {
        Keychain.delete(Self.keyAccount)
        listener?.cancel()
        listener = nil
        try start()
    }
}
