import Foundation
import Network

/// Setting up a device with no comfortable keyboard (the Apple TV) from the iPhone: the TV advertises itself on the
/// home network and shows a 4-digit code; the iPhone finds it, the owner types the code, and the iPhone sends its
/// accounts over the same TLS-PSK link as the Mac sync (ECDHE on top of the code, so a recording can't be tried
/// against the codes afterwards). The TV takes a few wrong tries at most, then changes the code.
public enum AccountsHandoff {
    static let serviceType = "_lar-setup._tcp"
    static let maxFailures = 5

    // MARK: The accounts

    /// What this device can hand over: every account but SmartThings' (a refresh token copied to another device
    /// logs both out; the TV sets its own up) and the intercom (only the iPhone and the Mac use it).
    public static func accounts(of settings: LarSettings) -> AccountsImport {
        AccountsImport(lgToken: settings.token,
                       tuya: settings.tuya.map { .init(clientID: $0.clientID, secret: $0.secret, region: $0.region) },
                       smartThings: nil, temperatureLimits: settings.temperatureLimits, alexa: settings.alexa,
                       xbox: settings.xbox, brands: settings.brands.isEmpty ? nil : settings.brands, intercom: nil)
    }

    /// What was received, in words ("LG ThinQ, Smart Life, Xbox").
    public static func summary(_ accounts: AccountsImport) -> String {
        var names: [String] = []
        if accounts.lgToken != nil { names.append(Provider.lg.name) }
        if accounts.tuya != nil { names.append(Provider.tuya.name) }
        if accounts.alexa != nil { names.append(Provider.alexa.name) }
        if accounts.xbox != nil { names.append(Provider.xbox.name) }
        for key in (accounts.brands ?? [:]).keys.sorted() { names.append(Provider(rawValue: key)?.name ?? key) }
        return ListFormatter.localizedString(byJoining: names)
    }

    // MARK: The TV's side

    /// Advertises the device and waits for the iPhone. Each accepted handoff calls `onAccounts`.
    public final class Receiver: @unchecked Sendable {
        public private(set) var code: String
        private let name: String
        private let advertise: Bool
        private let onAccounts: @Sendable (AccountsImport) -> Void
        private let onCodeChange: @Sendable (String) -> Void
        private var listener: NWListener?
        private var failures = 0
        private let queue = DispatchQueue(label: "lar.handoff")

        public init(name: String, advertise: Bool = true, onCodeChange: @escaping @Sendable (String) -> Void = { _ in },
                    onAccounts: @escaping @Sendable (AccountsImport) -> Void) {
            self.name = name
            self.advertise = advertise
            self.code = Self.newCode()
            self.onCodeChange = onCodeChange
            self.onAccounts = onAccounts
        }

        static func newCode() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

        public func start() throws {
            let listener = try NWListener(using: SyncLink.parameters(secret: SyncLink.pairingSecret(code)))
            if advertise { listener.service = NWListener.Service(name: name, type: AccountsHandoff.serviceType) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        }

        /// The port it listens on, once started (tests).
        var port: NWEndpoint.Port? { listener?.port }

        public func stop() {
            listener?.cancel()
            listener = nil
        }

        private func accept(_ connection: NWConnection) {
            Task {
                let link = HandoffConnection(connection)
                do {
                    try await link.start()
                    let data = try await link.receive()
                    let accounts = try JSONDecoder().decode(AccountsImport.self, from: data)
                    try await link.send(Data("ok".utf8))
                    // The answer must reach the iPhone before the connection goes.
                    try? await Task.sleep(for: .milliseconds(500))
                    link.close()
                    onAccounts(accounts)
                } catch {
                    link.close()
                    failed()
                }
            }
        }

        /// A wrong code fails the TLS handshake: after a few, a new code (and a new listener with it).
        private func failed() {
            queue.async { [self] in
                failures += 1
                guard failures >= AccountsHandoff.maxFailures else { return }
                failures = 0
                stop()
                code = Self.newCode()
                try? start()
                onCodeChange(code)
            }
        }
    }

    // MARK: The iPhone's side

    public struct Device: Identifiable, Hashable, Sendable {
        public var name: String
        public var endpoint: NWEndpoint
        public var id: String { name }
    }

    /// Looks for devices waiting to be set up; `onChange` gets the current list.
    public static func browse(onChange: @escaping @Sendable ([Device]) -> Void) -> NWBrowser {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            onChange(results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Device(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name })
        }
        browser.start(queue: .global(qos: .userInitiated))
        return browser
    }

    /// Sends the accounts to the device with the code it shows.
    public static func send(_ accounts: AccountsImport, to device: Device, code: String) async throws {
        let digits = code.filter(\.isNumber)
        guard digits.count == 4 else { throw ProviderError.api(tr("O código tem 4 números.")) }
        let connection = NWConnection(to: device.endpoint, using: SyncLink.parameters(secret: SyncLink.pairingSecret(digits)))
        let link = HandoffConnection(connection)
        defer { link.close() }
        do {
            try await link.start()
            try await link.send(try JSONEncoder().encode(accounts))
            guard try await link.receive() == Data("ok".utf8) else { throw ProviderError.api(tr("\(device.name) não confirmou.")) }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.api(tr("Não deu para falar com \(device.name). Confira o código na tela e se os dois estão na mesma rede."))
        }
    }
}

/// One framed message each way over an NWConnection.
final class HandoffConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()

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
                try await Task.sleep(for: .seconds(8))
                throw SyncError.connection("timeout")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ message: Data) async throws {
        let connection = connection
        let data = TVRemoteProtocol.frame(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            if let (message, consumed) = try TVRemoteProtocol.unframe(buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                return message
            }
            guard ContinuousClock.now < deadline else { throw SyncError.connection("timeout") }
            let connection = connection
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(throwing: SyncError.connection("closed"))
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
