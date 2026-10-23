#if !os(watchOS)
import AVFoundation
import Foundation
import Observation

/// The intercom's settings: the SIP account (password in the keychain), who the intercom is, and the keys that
/// open the gate during a call.
public struct PhoneSettings: Equatable, Sendable {
    public var server: String
    public var port: UInt16
    public var user: String
    public var domain: String
    /// The intercom's number or extension, for "Ligar para o porteiro".
    public var doorNumber: String
    /// Keys that open the gate during the call ("*1", "#"…).
    public var doorCode: String
    public var isEnabled: Bool

    public static func load() -> PhoneSettings {
        PhoneSettings(
            server: Preferences.string(forKey: "sipServer") ?? "",
            port: UInt16(Preferences.object(forKey: "sipPort") as? Int ?? 5060),
            user: Preferences.string(forKey: "sipUser") ?? "",
            domain: Preferences.string(forKey: "sipDomain") ?? "",
            doorNumber: Preferences.string(forKey: "sipDoorNumber") ?? "",
            doorCode: Preferences.string(forKey: "sipDoorCode") ?? "",
            isEnabled: Preferences.bool(forKey: "sipEnabled") ?? false
        )
    }

    public func save() {
        Preferences.set(server, forKey: "sipServer")
        Preferences.set(Int(port), forKey: "sipPort")
        Preferences.set(user, forKey: "sipUser")
        Preferences.set(domain, forKey: "sipDomain")
        Preferences.set(doorNumber, forKey: "sipDoorNumber")
        Preferences.set(doorCode, forKey: "sipDoorCode")
        Preferences.set(isEnabled, forKey: "sipEnabled")
    }

    public static var password: String? {
        get { Keychain.read("sip-password").flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: "sip-password", label: "Lar – senha do porteiro (SIP)")
            } else {
                Keychain.delete("sip-password")
            }
        }
    }

    public var isComplete: Bool { !server.isEmpty && !user.isEmpty && Self.password != nil }
}

/// A call as the screens show it.
public struct PhoneCall: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case incoming, dialing, ringing
        case active(since: Date)
        case ended(String)
    }

    public var id: String
    public var name: String
    public var isOutgoing: Bool
    public var state: State
}

/// The intercom phone of an app: registers with the PBX while enabled, rings for incoming calls (the app shows
/// them), places calls, opens the gate with its keys. One call at a time.
@MainActor
@Observable
public final class PhoneStore {
    public private(set) var registration: SIPRegistration = .off
    public private(set) var call: PhoneCall?
    public var isMuted = false {
        didSet { media?.isMuted = isMuted }
    }
    public private(set) var settings = PhoneSettings.load()

    /// An incoming call (the app rings and shows it); and when a call ends.
    @ObservationIgnored public var onIncoming: ((PhoneCall) -> Void)?
    @ObservationIgnored public var onEnded: ((PhoneCall) -> Void)?

    @ObservationIgnored private var client: SIPClient?
    @ObservationIgnored private var media: RTPSession?
    @ObservationIgnored private var remoteMedia: SDPAudio?
    @ObservationIgnored private var localAddress = "0.0.0.0"

    public init() {}

    public var isConfigured: Bool { settings.isEnabled && settings.isComplete }

    /// Registers when enabled and complete; call again after the settings change.
    public func start() async {
        await stop()
        settings = PhoneSettings.load()
        guard isConfigured, let password = PhoneSettings.password else { return }
        let account = SIPAccount(server: settings.server, port: settings.port, user: settings.user, password: password,
                                 domain: settings.domain.isEmpty ? nil : settings.domain)
        let client = SIPClient(account: account) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.client = client
        await client.start()
    }

    public func stop() async {
        if let call { await hangup(call.id) }
        await client?.stop()
        client = nil
        registration = .off
    }

    public func save(_ new: PhoneSettings, password: String?) async {
        new.save()
        if let password { PhoneSettings.password = password }
        await start()
    }

    // MARK: Calls

    /// Calls the intercom (or another number).
    public func dial(_ number: String? = nil) async {
        let target = (number ?? settings.doorNumber).trimmingCharacters(in: .whitespaces)
        guard let client, call == nil, !target.isEmpty else { return }
        guard await Self.microphoneAllowed() else {
            call = PhoneCall(id: "denied", name: target, isOutgoing: true, state: .ended("Permita o microfone para o Lar"))
            return
        }
        let media = RTPSession()
        self.media = media
        let offer = SDPAudio.make(address: await mediaAddress(), port: media.localPort)
        let id = await client.dial(target, offer: offer)
        call = PhoneCall(id: id, name: target == settings.doorNumber ? "Porteiro" : target, isOutgoing: true, state: .dialing)
    }

    public func answer() async {
        guard let client, let call, call.state == .incoming else { return }
        guard await Self.microphoneAllowed() else {
            await decline()
            return
        }
        let media = RTPSession()
        self.media = media
        let answer = SDPAudio.make(address: await mediaAddress(), port: media.localPort, payloads: [0, 8])
        guard let remote = await client.answer(call.id, sdp: answer) else {
            await hangup(call.id)
            return
        }
        startMedia(remote)
        self.call?.state = .active(since: Date())
    }

    public func decline() async {
        guard let client, let call else { return }
        await client.decline(call.id)
    }

    public func hangup(_ id: String? = nil) async {
        guard let call, id == nil || id == call.id else { return }
        await client?.hangup(call.id)
        finish("Encerrada")
    }

    /// Sends the gate's keys during the call.
    public func openDoor() async {
        await sendKeys(settings.doorCode)
    }

    public func sendKeys(_ keys: String) async {
        guard let call, case .active = call.state, !keys.isEmpty else { return }
        if remoteMedia?.dtmfPayload != nil {
            await media?.sendDTMF(keys)
        } else {
            for key in keys { await client?.sendInfoDTMF(call.id, digit: key) }
        }
    }

    // MARK: Events

    private func handle(_ event: SIPEvent) {
        switch event {
        case .registration(let state):
            registration = state
        case .incoming(let id, let from):
            guard call == nil else {
                // Already on a call: busy.
                Task { await client?.decline(id) }
                return
            }
            let incoming = PhoneCall(id: id, name: from, isOutgoing: false, state: .incoming)
            call = incoming
            onIncoming?(incoming)
        case .ringing(let id):
            if call?.id == id { call?.state = .ringing }
        case .answered(let id, let remote):
            guard call?.id == id else { return }
            startMedia(remote)
            call?.state = .active(since: Date())
        case .ended(let id, let reason):
            guard call?.id == id else { return }
            finish(reason)
        }
    }

    private func startMedia(_ remote: SDPAudio) {
        remoteMedia = remote
        do {
            try media?.start(remote: remote)
            media?.isMuted = isMuted
        } catch {
            call?.state = .ended("Sem acesso ao microfone ou ao alto-falante")
        }
    }

    private func finish(_ reason: String) {
        media?.stop()
        media = nil
        remoteMedia = nil
        isMuted = false
        guard var ended = call else { return }
        ended.state = .ended(reason)
        call = nil
        onEnded?(ended)
    }

    /// The address for our media: this device's on the network the PBX is reached by.
    private func mediaAddress() async -> String {
        Self.localIPv4() ?? localAddress
    }

    /// The first IPv4 address of an active interface (Wi-Fi or cable), as the PBX should send audio to.
    static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var candidate: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET), interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: interface.ifa_name), address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("en") { return address }
            candidate = candidate ?? address
        }
        return candidate
    }

    static func microphoneAllowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
#endif
