import Foundation

/// A paired TV's remote over the Google TV protocol: keeps one connection open (the TV pings it every few seconds
/// and drops a phone that doesn't answer), learns from the TV whether the screen is on, which app is in front and the
/// volume, and sends keys and app links. No debugging mode needed on the TV.
public actor TVRemoteClient {
    public struct State: Sendable, Equatable {
        public var isOn: Bool?
        public var app: String?
        public var volume: Int?
        public var maxVolume: Int?
        public var isMuted = false
    }

    /// How long a fresh connection waits for the TV to say whether it's on.
    static let stateTimeout: Duration = .seconds(3)

    public let host: String
    private let identity: TVRemoteIdentity
    private let model: String
    private var link: TVRemoteLink?
    private var reader: Task<Void, Never>?
    private var state = State()
    private var isActive = false
    private var lastError: TVRemoteError?
    private var pin: String?
    private var imeCounter: UInt64 = 0
    private var fieldCounter: UInt64 = 0
    private let rememberPin: @Sendable (String) -> Void

    /// - Parameters:
    ///   - pin: the TV certificate's SHA-256 seen before; nil pins the first one seen (`rememberPin` saves it).
    public init(host: String, identity: TVRemoteIdentity, model: String = "Lar", pin: String? = nil,
                rememberPin: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host
        self.identity = identity
        self.model = model
        self.pin = pin
        self.rememberPin = rememberPin
    }

    /// What the TV last said, connecting first when needed.
    public func currentState() async throws -> State {
        try await connectIfNeeded()
        return state
    }

    public func press(keyCode: Int) async throws {
        try await sendRetrying(TVRemoteProtocol.key(keyCode))
    }

    /// Types into the field the TV has focused (a search box with its keyboard open).
    public func type(_ text: String) async throws {
        try await connectIfNeeded()
        try await sendRetrying(TVRemoteProtocol.text(text, imeCounter: imeCounter, fieldCounter: fieldCounter))
    }

    /// Opens an app by link: a web address the app claims ("https://www.netflix.com/title") or
    /// "market://launch?id=<package>", which opens any installed app.
    public func open(link: String) async throws {
        try await sendRetrying(TVRemoteProtocol.openLink(link))
    }

    public func close() {
        reader?.cancel()
        reader = nil
        let link = link
        self.link = nil
        isActive = false
        Task { await link?.close() }
    }

    // MARK: Connection

    private func sendRetrying(_ message: Data) async throws {
        do {
            try await connectIfNeeded()
            try await link?.send(message)
        } catch TVRemoteError.notPaired {
            throw TVRemoteError.notPaired
        } catch {
            // An idle connection the TV dropped (or it slept): once more on a fresh one.
            close()
            try await connectIfNeeded()
            try await link?.send(message)
        }
    }

    private func connectIfNeeded() async throws {
        if link != nil, isActive { return }
        close()
        let link = TVRemoteLink(host: host, port: TVRemoteProtocol.remotePort, identity: identity, pin: pin)
        try await link.open()
        self.link = link
        lastError = nil
        reader = Task { [weak self] in await self?.readLoop(link) }
        // The TV opens with RemoteConfigure, then RemoteSetActive, then its state; wait for the power state.
        let deadline = ContinuousClock.now + Self.stateTimeout
        while ContinuousClock.now < deadline, self.link === link, state.isOn == nil || !isActive {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let lastError { throw lastError }
        guard self.link === link, isActive else {
            // Connected but the TV never let the phone in: it doesn't know this certificate.
            close()
            throw TVRemoteError.notPaired
        }
        // Trust on first use: the TV that just accepted this device's paired certificate is the one to keep.
        if pin == nil, let seen = await link.serverFingerprint {
            pin = seen
            rememberPin(seen)
        }
    }

    private func readLoop(_ link: TVRemoteLink) async {
        while !Task.isCancelled {
            do {
                let message = try await link.receive()
                try await handle(TVRemoteProtocol.incoming(message), on: link)
            } catch {
                if self.link === link {
                    lastError = error as? TVRemoteError ?? .connection(error.localizedDescription)
                    self.link = nil
                    isActive = false
                }
                await link.close()
                return
            }
        }
    }

    private func handle(_ message: TVRemoteProtocol.Incoming, on link: TVRemoteLink) async throws {
        switch message {
        case .configure: try await link.send(TVRemoteProtocol.configure(model: model))
        case .setActive:
            try await link.send(TVRemoteProtocol.setActive())
            isActive = true
        case .ping(let value): try await link.send(TVRemoteProtocol.pingResponse(value))
        case .power(let on): state.isOn = on
        case .volume(let level, let max, let muted):
            state.volume = level
            state.maxVolume = max
            state.isMuted = muted
        case .app(let package): state.app = package
        case .keyboard(let ime, let field):
            imeCounter = ime
            fieldCounter = field
        case .error: throw TVRemoteError.protocolError("a TV recusou um comando")
        case .other: break
        }
    }
}

/// Pairing with a TV: it shows a 6-symbol code, typed on this device. Two steps, because a person reads the code
/// in between: `start()` makes the TV show it, `finish(code:)` sends the proof.
public actor TVRemotePairing {
    public let host: String
    private let identity: TVRemoteIdentity
    private let clientName: String
    private var link: TVRemoteLink?

    static let replyTimeout: Duration = .seconds(10)

    public init(host: String, identity: TVRemoteIdentity, clientName: String) {
        self.host = host
        self.identity = identity
        self.clientName = clientName
    }

    /// Until the TV shows the code.
    public func start() async throws {
        let link = TVRemoteLink(host: host, port: TVRemoteProtocol.pairingPort, identity: identity)
        try await link.open()
        self.link = link
        do {
            try await exchange(TVRemoteProtocol.pairingRequest(clientName: clientName), expecting: 11, on: link)
            try await exchange(TVRemoteProtocol.pairingOptions(), expecting: 20, on: link)
            try await exchange(TVRemoteProtocol.pairingConfiguration(), expecting: 31, on: link)
        } catch {
            await cancel()
            throw error
        }
    }

    /// Sends the code's proof; when this returns, the TV knows this device for good.
    public func finish(code: String) async throws {
        guard let link else { throw TVRemoteError.connection("comece o pareamento de novo") }
        guard let secret = TVRemoteProtocol.pairingSecret(
            code: code, client: identity.publicNumbers, server: try await link.serverPublicNumbers()
        ) else { throw TVRemoteError.wrongCode }
        try await exchange(TVRemoteProtocol.pairingSecret(secret), expecting: 41, on: link)
        await cancel()
    }

    public func cancel() async {
        await link?.close()
        link = nil
    }

    private func exchange(_ message: Data, expecting field: Int, on link: TVRemoteLink) async throws {
        try await link.send(message)
        let reply = try ProtoReader(try await link.receive(timeout: Self.replyTimeout))
        let status = reply.int(2) ?? 0
        if status == TVRemoteProtocol.statusBadSecret { throw TVRemoteError.wrongCode }
        guard status == TVRemoteProtocol.statusOK, reply.has(field) else {
            throw TVRemoteError.protocolError("a TV recusou o pareamento (\(status))")
        }
    }
}
