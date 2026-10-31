import Foundation
import Network

/// The iPhone's side: finds the Mac on the home network, pairs with the code it shows, and syncs.
public enum SyncClient {
    nonisolated(unsafe) static var keyAccount = "sync-key-mac"
    static let browseTime: Duration = .seconds(3)

    public static var isPaired: Bool { key() != nil }

    static func key() -> Data? { Keychain.read(keyAccount).flatMap { Data(base64Encoded: $0) } }

    public static func forget() { Keychain.delete(keyAccount) }

    /// Pairs with the Mac showing `code` (Ajustes → Sincronizar com o iPhone).
    public static func pair(code: String, endpoint: NWEndpoint? = nil) async throws {
        let code = code.filter(\.isNumber)
        guard code.count == 6 else { throw SyncError.wrongCode }
        var target = endpoint
        if target == nil { target = try await find(SyncLink.pairingServiceType) }
        guard let target else { throw SyncError.macNotFound }
        let link = SyncConnection(NWConnection(to: target, using: SyncLink.parameters(secret: SyncLink.pairingSecret(code))))
        defer { Task { await link.close() } }
        do {
            try await link.start()
            guard case .key(let key) = try await link.receive(), key.count == 32 else { throw SyncError.wrongCode }
            Keychain.write(key.base64EncodedString(), account: keyAccount, label: "Lar – sincronização com o Mac")
            try? await link.send(.ok)
        } catch let error as SyncError {
            // A wrong code fails the TLS handshake, which looks like a dropped connection.
            throw error == .macNotFound ? error : .wrongCode
        }
    }

    /// Brings both sides to the newer state. Returns which way it went (nil: already the same).
    @MainActor
    @discardableResult
    public static func sync(_ settings: AccountSettings, endpoint: NWEndpoint? = nil) async throws -> SyncState.Direction? {
        guard let key = key() else { throw SyncError.notPaired }
        var target = endpoint
        if target == nil { target = try await find(SyncLink.serviceType) }
        guard let target else { throw SyncError.macNotFound }
        let link = SyncConnection(NWConnection(to: target, using: SyncLink.parameters(secret: key)))
        defer { Task { await link.close() } }
        do {
            try await link.start()
        } catch {
            // The Mac's key changed ("forget paired devices"): this iPhone has to pair again.
            throw SyncError.notPaired
        }
        try await link.send(.get)
        guard case .state(let remote) = try await link.receive() else { throw SyncError.connection(tr("resposta inválida")) }
        let local = SyncState.capture(settings)
        switch SyncState.direction(local: local, remote: remote) {
        case .pull?:
            remote.apply(to: settings)
            return .pull
        case .push?:
            try await link.send(.put(local))
            _ = try await link.receive()
            return .push
        case nil:
            return nil
        }
    }

    /// Tells the Mac which SmartThings integration this device uses and learns the Mac's, so neither signs in with
    /// the other's. Quietly does nothing when the Mac can't be reached (or is an older version).
    /// - Parameter install: whose claim it is (this device by default; the iPhone also tells about its watch).
    public static func exchangeClaims(_ mine: SmartThingsClaims.Claim?, install: String = SmartThingsClaims.installID,
                                      endpoint: NWEndpoint? = nil) async {
        guard let key = key() else { return }
        var target = endpoint
        if target == nil { target = try? await find(SyncLink.serviceType) }
        guard let target else { return }
        let link = SyncConnection(NWConnection(to: target, using: SyncLink.parameters(secret: key)))
        defer { Task { await link.close() } }
        do {
            try await link.start()
            try await link.send(.claim(install: install, claim: mine))
            if case .claim(let install, let theirs) = try await link.receive() {
                SmartThingsClaims.record(theirs, install: install)
            }
        } catch {}
    }

    /// Asks the Mac to turn the device off later (it stays on; the iPhone may be locked). False when it can't.
    public static func handOffTimer(deviceID: String, seconds: Double?, endpoint: NWEndpoint? = nil) async -> Bool {
        guard let key = key() else { return false }
        var target = endpoint
        if target == nil { target = try? await find(SyncLink.serviceType) }
        guard let target else { return false }
        let link = SyncConnection(NWConnection(to: target, using: SyncLink.parameters(secret: key)))
        defer { Task { await link.close() } }
        do {
            try await link.start()
            try await link.send(.offTimer(deviceID: deviceID, seconds: seconds))
            return try await link.receive() == .ok
        } catch {
            return false
        }
    }

    /// The first Mac advertising the service, after a short browse.
    static func find(_ type: String) async throws -> NWEndpoint? {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        let found = Locked<NWEndpoint?>(nil)
        browser.browseResultsChangedHandler = { results, _ in
            if let first = results.first { found.update { $0 = $0 ?? first.endpoint } }
        }
        browser.start(queue: .global(qos: .userInitiated))
        let deadline = ContinuousClock.now + browseTime
        while found.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        browser.cancel()
        return found.value
    }
}
