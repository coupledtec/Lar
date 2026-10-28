import Foundation
import Network
import os

/// A SIP account: the server (a PBX or VoIP provider), the extension's user and password.
public struct SIPAccount: Sendable, Equatable {
    public var server: String
    public var port: UInt16
    public var user: String
    public var password: String
    /// The SIP domain, when it isn't the server's address.
    public var domain: String?

    public init(server: String, port: UInt16 = 5060, user: String, password: String, domain: String? = nil) {
        self.server = server
        self.port = port
        self.user = user
        self.password = password
        self.domain = domain
    }

    var realmHost: String { domain.flatMap { $0.isEmpty ? nil : $0 } ?? server }
    var aor: String { "sip:\(user)@\(realmHost)" }
}

public enum SIPRegistration: Sendable, Equatable {
    case off, registering, registered
    case failed(String)
}

public enum SIPEvent: Sendable, Equatable {
    case registration(SIPRegistration)
    /// Someone's calling: the call's id and who it is.
    case incoming(callID: String, from: String)
    /// Our call is ringing on the other side.
    case ringing(callID: String)
    case answered(callID: String, media: SDPAudio)
    case ended(callID: String, reason: String)
}

/// How SIP datagrams go to the server and come back (UDP; a fake one in tests).
public protocol SIPTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async
    /// The address the server sees this side at, once started (for Via and Contact).
    func localAddress() async -> (host: String, port: UInt16)
    var incoming: AsyncStream<Data> { get }
    func stop() async
}

/// The SIP side of a phone (RFC 3261, over UDP): registers, places and takes calls, hangs up. Every request goes to
/// the server (as an outbound proxy), which suits a cloud PBX behind the home router. Media is someone else's job:
/// this hands over and takes the SDP.
public actor SIPClient {
    static let log = Logger(subsystem: "com.coupled.lar", category: "sip")
    public let account: SIPAccount
    private let transport: any SIPTransport
    private let events: @Sendable (SIPEvent) -> Void
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// Where the server sees us, learned from its responses (rport/received), for Contact.
    private var publicAddress: (host: String, port: UInt16)?
    private var registerCallID = SIPMessage.random(16) + "@lar"
    private var registerCSeq = 0
    private var registration: SIPRegistration = .off
    /// False when only placing calls: "registered" then means connected, with no binding to take back.
    private var registers = true
    private var waiting: [String: CheckedContinuation<SIPMessage, Error>] = [:]
    private var provisional: [String: @Sendable (SIPMessage) -> Void] = [:]
    private var dialogs: [String: Dialog] = [:]

    /// Short, so that if another phone on the same extension took the binding (servers often keep one), this one
    /// is back within a couple of minutes.
    static let expires = 120
    static let keepAlive: Duration = .seconds(25)
    /// RFC 3261's T1: the first retransmission over UDP.
    static let t1: Duration = .milliseconds(500)

    struct Dialog {
        var callID: String
        var localTag: String
        var remoteTag: String?
        /// Where requests in the dialog go (the other side's Contact), and the From/To as this side writes them.
        var remoteTarget: String
        var localURI: String
        var remoteURI: String
        var remoteDisplay: String
        var routes: [String] = []
        var cseq = 1
        var outgoing: Bool
        /// The incoming INVITE (its Via, From, CSeq are echoed in the answers), or our outgoing one.
        var invite: SIPMessage
        var answered = false
        var lastResponse: SIPMessage?
    }

    public init(account: SIPAccount, transport: (any SIPTransport)? = nil, events: @escaping @Sendable (SIPEvent) -> Void) {
        self.account = account
        self.transport = transport ?? UDPTransport(host: account.server, port: account.port)
        self.events = events
    }

    // MARK: Registration

    /// Connects and registers. Without `registering`, only connects, for calls placed from here: the watch can't
    /// stay on the network between calls, so it doesn't take a binding (that would ring a phone that isn't there).
    public func start(registering: Bool = true) async {
        receiveTask?.cancel()
        registers = registering
        report(.registering)
        do {
            try await transport.start()
        } catch {
            Self.log.error("no route to \(self.account.server, privacy: .private): \(error.localizedDescription, privacy: .public)")
            report(.failed(tr("Servidor não responde")))
            guard registering else { return }
            // The network may not be up yet (the app starting with the Mac): try again in a while.
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.start()
            }
            return
        }
        let stream = transport.incoming
        receiveTask = Task { [weak self] in
            for await data in stream { await self?.received(data) }
        }
        guard registering else {
            report(.registered)
            return
        }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAlive)
                await self?.transport.send(Data("\r\n\r\n".utf8))
            }
        }
        await register()
    }

    public func stop() async {
        refreshTask?.cancel()
        if registers, registration == .registered { _ = try? await sendRegister(expires: 0) }
        keepAliveTask?.cancel()
        receiveTask?.cancel()
        await transport.stop()
        for (_, continuation) in waiting { continuation.resume(throwing: CancellationError()) }
        waiting = [:]
        report(.off)
    }

    private func register() async {
        do {
            let response = try await sendRegister(expires: Self.expires)
            guard response.statusCode == 200 else {
                report(.failed(Self.reason(response)))
                scheduleRefresh(after: 60)
                return
            }
            // Behind a router the server sees another address: say that one from now on.
            if let via = response.header("Via"), let host = SIPMessage.parameter("received", in: via),
               let port = SIPMessage.parameter("rport", in: via).flatMap(UInt16.init) {
                let local = await transport.localAddress()
                if publicAddress == nil, host != local.host || port != local.port {
                    publicAddress = (host, port)
                    _ = try? await sendRegister(expires: Self.expires)
                }
            }
            Self.log.notice("bindings: \(response.headers("Contact").joined(separator: " | "), privacy: .private)")
            report(.registered)
            let granted = response.header("Expires").flatMap(Int.init) ?? Self.expires
            scheduleRefresh(after: max(30, Double(granted) * 0.8))
        } catch {
            report(.failed(tr("Servidor não responde")))
            scheduleRefresh(after: 60)
        }
    }

    private func scheduleRefresh(after seconds: Double) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.register()
        }
    }

    private func sendRegister(expires: Int) async throws -> SIPMessage {
        registerCSeq += 1
        let tag = SIPMessage.random()
        var request = await baseRequest("REGISTER", uri: "sip:\(account.realmHost)", callID: registerCallID, cseq: registerCSeq,
                                        from: "<\(account.aor)>;tag=\(tag)", to: "<\(account.aor)>")
        request.set("Expires", String(expires))
        var response = try await transact(request)
        if let challenged = try await authenticate(request, after: response, cseq: { self.nextRegisterCSeq() }) {
            response = challenged
        }
        return response
    }

    private func nextRegisterCSeq() -> Int {
        registerCSeq += 1
        return registerCSeq
    }

    private func report(_ state: SIPRegistration) {
        Self.log.notice("registration: \(String(describing: state), privacy: .public)")
        registration = state
        events(.registration(state))
    }

    // MARK: Calls

    /// Calls a number or extension with our SDP offer; returns the call's id. Answer, ringing and end come as events.
    public func dial(_ number: String, offer: Data) async -> String {
        let callID = SIPMessage.random(16) + "@lar"
        let tag = SIPMessage.random()
        let target = number.hasPrefix("sip:") ? number : "sip:\(number)@\(account.realmHost)"
        var invite = await baseRequest("INVITE", uri: target, callID: callID, cseq: 1, from: "<\(account.aor)>;tag=\(tag)",
                                       to: "<\(target)>")
        invite.set("Content-Type", "application/sdp")
        invite.body = offer
        dialogs[callID] = Dialog(callID: callID, localTag: tag, remoteTarget: target, localURI: account.aor, remoteURI: target,
                                 remoteDisplay: number, outgoing: true, invite: invite)
        Task { await self.runOutgoing(invite, callID: callID) }
        return callID
    }

    private func runOutgoing(_ firstInvite: SIPMessage, callID: String) async {
        var invite = firstInvite
        do {
            provisional[branch(of: invite)] = { [weak self] response in
                guard (180...183).contains(response.statusCode ?? 0) else { return }
                Task { await self?.ringing(callID) }
            }
            var response = try await transact(invite, finalTimeout: .seconds(120))
            if [401, 407].contains(response.statusCode ?? 0) {
                await ack(failed: invite, response: response)
                guard var dialog = dialogs[callID] else { return }
                dialog.cseq += 1
                dialogs[callID] = dialog
                guard let retried = await authorized(invite, challenge: response, cseq: dialog.cseq) else {
                    return end(callID, tr("Senha recusada"))
                }
                invite = retried
                dialogs[callID]?.invite = invite
                provisional[branch(of: invite)] = { [weak self] response in
                    guard (180...183).contains(response.statusCode ?? 0) else { return }
                    Task { await self?.ringing(callID) }
                }
                response = try await transact(invite, finalTimeout: .seconds(120))
            }
            guard dialogs[callID] != nil else { return }
            guard response.statusCode == 200 else {
                await ack(failed: invite, response: response)
                return end(callID, Self.reason(response))
            }
            dialogs[callID]?.remoteTag = response.header("To").flatMap { SIPMessage.parameter("tag", in: $0) }
            if let contact = response.header("Contact") { dialogs[callID]?.remoteTarget = SIPMessage.uri(in: contact) }
            dialogs[callID]?.routes = response.headers("Record-Route").flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }.reversed()
            dialogs[callID]?.answered = true
            await sendInDialog("ACK", callID: callID, cseq: dialogs[callID]?.cseq)
            guard let media = SDPAudio.parse(response.body) else {
                await hangup(callID)
                return end(callID, tr("Sem áudio compatível"))
            }
            events(.answered(callID: callID, media: media))
        } catch {
            if dialogs[callID] != nil { end(callID, tr("Sem resposta")) }
        }
    }

    private func ringing(_ callID: String) {
        guard dialogs[callID] != nil else { return }
        events(.ringing(callID: callID))
    }

    /// Answers an incoming call with our SDP; returns the caller's media.
    public func answer(_ callID: String, sdp: Data) async -> SDPAudio? {
        guard var dialog = dialogs[callID], !dialog.outgoing else { return nil }
        let media = SDPAudio.parse(dialog.invite.body)
        var ok = await response(to: dialog.invite, 200, "OK", toTag: dialog.localTag)
        ok.set("Content-Type", "application/sdp")
        ok.body = sdp
        dialog.answered = true
        dialog.lastResponse = ok
        dialogs[callID] = dialog
        await transport.send(ok.serialized())
        return media
    }

    public func decline(_ callID: String) async {
        guard let dialog = dialogs[callID], !dialog.outgoing, !dialog.answered else { return }
        let busy = await response(to: dialog.invite, 486, "Busy Here", toTag: dialog.localTag)
        await transport.send(busy.serialized())
        end(callID, tr("Recusada"))
    }

    /// Ends the call: BYE once answered, CANCEL while ours rings.
    public func hangup(_ callID: String) async {
        guard let dialog = dialogs[callID] else { return }
        if dialog.answered {
            dialogs[callID]?.cseq += 1
            await sendInDialog("BYE", callID: callID, cseq: dialogs[callID]?.cseq, waitForAnswer: false)
        } else if dialog.outgoing {
            var cancel = dialog.invite
            cancel.startLine = "CANCEL \(dialog.remoteTarget) SIP/2.0"
            cancel.set("CSeq", "\(dialog.invite.cseq ?? 1) CANCEL")
            cancel.headers.removeAll { ["Content-Type", "Authorization", "Proxy-Authorization"].contains($0.name) }
            cancel.body = Data()
            await transport.send(cancel.serialized())
        } else {
            await decline(callID)
            return
        }
        end(callID, tr("Encerrada"))
    }

    /// A key during the call, as SIP INFO (for servers without RFC 4733 events in the media).
    public func sendInfoDTMF(_ callID: String, digit: Character) async {
        guard dialogs[callID]?.answered == true else { return }
        dialogs[callID]?.cseq += 1
        await sendInDialog("INFO", callID: callID, cseq: dialogs[callID]?.cseq, waitForAnswer: false,
                           contentType: "application/dtmf-relay", body: Data("Signal=\(digit)\r\nDuration=160\r\n".utf8))
    }

    private func end(_ callID: String, _ reason: String) {
        guard dialogs.removeValue(forKey: callID) != nil else { return }
        events(.ended(callID: callID, reason: reason))
    }

    // MARK: Incoming

    private func received(_ data: Data) async {
        guard let message = SIPMessage.parse(data) else { return }
        Self.log.info("<- \(message.startLine, privacy: .private) [\(message.callID ?? "", privacy: .private)]")
        if message.isRequest {
            await handleRequest(message)
        } else {
            let key = branch(of: message)
            if let code = message.statusCode, code < 200 {
                provisionalSeen.insert(key)
                provisional[key]?(message)
                return
            }
            provisional[key] = nil
            waiting.removeValue(forKey: key)?.resume(returning: message)
        }
    }

    private func handleRequest(_ request: SIPMessage) async {
        let callID = request.callID ?? ""
        switch request.method {
        case "INVITE":
            if var dialog = dialogs[callID] {
                // A retransmission, or a re-INVITE (hold, codec change): answer with what we said.
                if let last = dialog.lastResponse, dialog.invite.cseq == request.cseq {
                    await transport.send(last.serialized())
                } else if dialog.answered, var ok = dialog.lastResponse {
                    ok.set("CSeq", "\(request.cseq ?? 1) INVITE")
                    ok.set("Via", request.header("Via") ?? "")
                    dialog.invite = request
                    dialogs[callID] = dialog
                    await transport.send(ok.serialized())
                }
                return
            }
            let from = request.header("From") ?? ""
            let tag = SIPMessage.random()
            let dialog = Dialog(
                callID: callID, localTag: tag, remoteTag: SIPMessage.parameter("tag", in: from),
                remoteTarget: request.header("Contact").map(SIPMessage.uri(in:)) ?? SIPMessage.uri(in: from),
                localURI: SIPMessage.uri(in: request.header("To") ?? account.aor), remoteURI: SIPMessage.uri(in: from),
                remoteDisplay: SIPMessage.displayName(in: from), routes: request.headers("Record-Route"),
                outgoing: false, invite: request
            )
            dialogs[callID] = dialog
            await transport.send(await response(to: request, 100, "Trying").serialized())
            var ringing = await response(to: request, 180, "Ringing", toTag: tag)
            dialogs[callID]?.lastResponse = ringing
            ringing.set("Contact", await contact())
            await transport.send(ringing.serialized())
            events(.incoming(callID: callID, from: dialog.remoteDisplay))
        case "ACK":
            break
        case "BYE":
            await transport.send(await response(to: request, 200, "OK").serialized())
            end(callID, tr("O outro lado desligou"))
        case "CANCEL":
            await transport.send(await response(to: request, 200, "OK").serialized())
            if let dialog = dialogs[callID], !dialog.answered {
                let terminated = await response(to: dialog.invite, 487, "Request Terminated", toTag: dialog.localTag)
                await transport.send(terminated.serialized())
                end(callID, tr("Chamada perdida"))
            }
        default:
            // OPTIONS (keep-alive checks), NOTIFY, INFO…
            await transport.send(await response(to: request, 200, "OK").serialized())
        }
    }

    // MARK: Messages

    /// Where the other side should send our audio, when the server is reached over IPv6 (a mobile network with only
    /// IPv6): the address the server sees us at (an IPv4 server through the carrier's NAT64), else our IPv6. Nil on
    /// IPv4 (Wi-Fi, cable), where the device's own IPv4 stays the answer.
    func mediaAddress() async -> String? {
        let local = await transport.localAddress()
        guard SIPMessage.bareHost(local.host).contains(":") else { return nil }
        return publicAddress.map { SIPMessage.bareHost($0.host) } ?? SIPMessage.bareHost(local.host)
    }

    private func via(branch: String) async -> String {
        let local = await transport.localAddress()
        return "SIP/2.0/UDP \(SIPMessage.hostPort(local.host, local.port));branch=\(branch);rport"
    }

    private func contact() async -> String {
        let address: (host: String, port: UInt16)
        if let publicAddress {
            address = publicAddress
        } else {
            address = await transport.localAddress()
        }
        return "<sip:\(account.user)@\(SIPMessage.hostPort(address.host, address.port));transport=udp>"
    }

    private func baseRequest(_ method: String, uri: String, callID: String, cseq: Int, from: String, to: String) async -> SIPMessage {
        SIPMessage.request(method, uri: uri, headers: [
            ("Via", await via(branch: "z9hG4bK" + SIPMessage.random(12))), ("Max-Forwards", "70"), ("From", from), ("To", to),
            ("Call-ID", callID), ("CSeq", "\(cseq) \(method)"), ("Contact", await contact()), ("User-Agent", "Lar"),
            ("Allow", "INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, NOTIFY"),
        ])
    }

    private func response(to request: SIPMessage, _ code: Int, _ reason: String, toTag: String? = nil) async -> SIPMessage {
        var to = request.header("To") ?? ""
        if let toTag, SIPMessage.parameter("tag", in: to) == nil { to += ";tag=\(toTag)" }
        var headers: [(name: String, value: String)] = request.headers("Via").map { (name: "Via", value: $0) }
        headers += request.headers("Record-Route").map { (name: "Record-Route", value: $0) }
        headers += [("From", request.header("From") ?? ""), ("To", to), ("Call-ID", request.callID ?? ""),
                    ("CSeq", request.header("CSeq") ?? "")].map { (name: $0.0, value: $0.1) }
        if code >= 200, code < 300 { headers.append((name: "Contact", value: await contact())) }
        headers.append((name: "User-Agent", value: "Lar"))
        return SIPMessage(startLine: "SIP/2.0 \(code) \(reason)", headers: headers)
    }

    /// A request inside a call (ACK for a 2xx, BYE, INFO), to the other side's Contact through the routes.
    private func sendInDialog(_ method: String, callID: String, cseq: Int?, waitForAnswer: Bool = false,
                              contentType: String? = nil, body: Data = Data()) async {
        guard let dialog = dialogs[callID] else { return }
        let localTag = ";tag=\(dialog.localTag)", remoteTag = dialog.remoteTag.map { ";tag=\($0)" } ?? ""
        var request = await baseRequest(method, uri: dialog.remoteTarget, callID: callID, cseq: cseq ?? dialog.cseq,
                                        from: "<\(dialog.localURI)>\(localTag)", to: "<\(dialog.remoteURI)>\(remoteTag)")
        for route in dialog.routes { request.headers.insert((name: "Route", value: route), at: 1) }
        if let contentType {
            request.set("Content-Type", contentType)
            request.body = body
        }
        if waitForAnswer {
            _ = try? await transact(request)
        } else {
            await transport.send(request.serialized())
        }
    }

    /// The ACK for a non-2xx answer to our INVITE: same branch, the response's To.
    private func ack(failed invite: SIPMessage, response: SIPMessage) async {
        var ack = invite
        ack.startLine = "ACK \(invite.startLine.split(separator: " ")[1]) SIP/2.0"
        ack.set("To", response.header("To") ?? invite.header("To") ?? "")
        ack.set("CSeq", "\(invite.cseq ?? 1) ACK")
        ack.headers.removeAll { $0.name == "Content-Type" }
        ack.body = Data()
        await transport.send(ack.serialized())
    }

    /// Retries the request with the server's challenge answered, when it asked for one.
    private func authenticate(_ request: SIPMessage, after response: SIPMessage,
                              cseq: () -> Int) async throws -> SIPMessage? {
        guard [401, 407].contains(response.statusCode ?? 0) else { return nil }
        guard let retried = await authorized(request, challenge: response, cseq: cseq()) else { return nil }
        return try await transact(retried)
    }

    private func authorized(_ request: SIPMessage, challenge response: SIPMessage, cseq: Int) async -> SIPMessage? {
        let proxy = response.statusCode == 407
        guard let header = response.header(proxy ? "Proxy-Authenticate" : "WWW-Authenticate"),
              let digest = SIPDigest(challenge: header) else { return nil }
        var retried = request
        let uri = String(request.startLine.split(separator: " ")[1])
        retried.set(proxy ? "Proxy-Authorization" : "Authorization",
                    digest.authorization(method: request.method, uri: uri, user: account.user, password: account.password))
        retried.set("CSeq", "\(cseq) \(request.method)")
        retried.set("Via", await via(branch: "z9hG4bK" + SIPMessage.random(12)))
        return retried
    }

    /// Sends a request and waits for its final response, retransmitting over UDP until something answers.
    private func transact(_ request: SIPMessage, finalTimeout: Duration = .seconds(32)) async throws -> SIPMessage {
        let key = branch(of: request)
        let data = request.serialized()
        let retransmit = Task { [weak self] in
            var delay = Self.t1
            for _ in 0..<6 {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, await self.isWaiting(key), await !self.hasProvisional(key) else { return }
                await self.transport.send(data)
                delay = min(delay * 2, .seconds(4))
            }
        }
        defer { retransmit.cancel() }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: finalTimeout)
            await self?.fail(key)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[key] = continuation
            Task { await self.transport.send(data) }
        }
    }

    private var provisionalSeen: Set<String> = []

    private func isWaiting(_ key: String) -> Bool { waiting[key] != nil }
    private func hasProvisional(_ key: String) -> Bool { provisionalSeen.contains(key) }

    private func fail(_ key: String) {
        waiting.removeValue(forKey: key)?.resume(throwing: URLError(.timedOut))
    }

    private func branch(of message: SIPMessage) -> String {
        message.header("Via").flatMap { SIPMessage.parameter("branch", in: $0) } ?? ""
    }

    static func reason(_ response: SIPMessage) -> String {
        switch response.statusCode ?? 0 {
        case 401, 403, 407: tr("Usuário ou senha recusados")
        case 404: tr("Número não existe")
        case 408, 480: tr("Não atende")
        case 486, 600: tr("Ocupado")
        case 487: tr("Cancelada")
        case 603: tr("Recusada")
        default: response.startLine.split(separator: " ").dropFirst(2).joined(separator: " ")
        }
    }
}

/// SIP over UDP with NWConnection, to the server's address: the same local port for everything, so the home
/// router keeps one mapping (refreshed by the keep-alives).
final class UDPTransport: SIPTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let continuation: AsyncStream<Data>.Continuation
    let incoming: AsyncStream<Data>

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        (incoming, continuation) = AsyncStream<Data>.makeStream()
    }

    func start() async throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { ready.resume() }
                case .failed(let error), .waiting(let error): once.run { ready.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { once.run { ready.resume(throwing: URLError(.timedOut)) } }
        }
        receive()
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(data) }
            if error == nil { self.receive() }
        }
    }

    func send(_ data: Data) async {
        if data.count > 4, let line = String(decoding: data.prefix(120), as: UTF8.self).split(separator: "\r\n").first {
            SIPClient.log.info("-> \(line, privacy: .private)")
        }
        connection?.send(content: data, completion: .idempotent)
    }

    func localAddress() async -> (host: String, port: UInt16) {
        if case .hostPort(let host, let port)? = connection?.currentPath?.localEndpoint {
            return (TVDiscovery.text(host) ?? "0.0.0.0", port.rawValue)
        }
        return ("0.0.0.0", 5060)
    }

    func stop() async {
        connection?.cancel()
        connection = nil
    }
}
