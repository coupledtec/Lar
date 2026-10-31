import Foundation
import Network
import Testing
@testable import LarCore

/// A real server and client on this Mac's loopback, with their own keychain entries (removed after).
@MainActor
@Suite(.serialized) struct SyncTests {
    init() {
        Vault.account = "test-vault"
        Vault.reset()
        SyncServer.keyAccount = "test-sync-key"
        SyncClient.keyAccount = "test-sync-key-mac"
        Keychain.delete(SyncServer.keyAccount)
        Keychain.delete(SyncClient.keyAccount)
    }

    func cleanUp() {
        Keychain.delete(SyncServer.keyAccount)
        Keychain.delete(SyncClient.keyAccount)
        Keychain.deleteItem("test-vault")
        Vault.reset()
    }

    static func endpoint(_ port: UInt16?) throws -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: try #require(port.flatMap(NWEndpoint.Port.init(rawValue:))))
    }

    @Test func pairThenSyncBothWays() async throws {
        defer { cleanUp() }
        let mac = InMemorySettings()
        let server = SyncServer(advertise: false, state: { SyncState.capture(mac) }, apply: { $0.apply(to: mac) },
                                claim: { .init(device: "Mac", fingerprint: SmartThingsClaims.fingerprint("mac-client")) })
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        // Not paired yet.
        let phone = InMemorySettings()
        await #expect(throws: SyncError.notPaired) { try await SyncClient.sync(phone, endpoint: try Self.endpoint(server.listeningPort)) }

        // A wrong code is refused; the right one hands over the key.
        let code = try server.startPairing()
        try await Task.sleep(for: .milliseconds(200))
        let wrong = code == "000000" ? "111111" : "000000"
        await #expect(throws: SyncError.wrongCode) { try await SyncClient.pair(code: wrong, endpoint: try Self.endpoint(server.pairingPort)) }
        try await SyncClient.pair(code: code, endpoint: try Self.endpoint(server.pairingPort))
        #expect(SyncClient.isPaired)

        // The iPhone's newer scene goes to the Mac.
        phone.scenes = [HomeScene(name: "Dormir", actions: [])]
        phone.markSyncChange(Date(timeIntervalSince1970: 2_000_000_000))
        #expect(try await SyncClient.sync(phone, endpoint: try Self.endpoint(server.listeningPort)) == .push)
        #expect(mac.scenes.map(\.name) == ["Dormir"])

        // Then the Mac's newer favorite comes back.
        mac.customizations = ["tuya:l1": DeviceCustomization(isFavorite: true)]
        mac.markSyncChange(Date(timeIntervalSince1970: 2_000_000_100))
        #expect(try await SyncClient.sync(phone, endpoint: try Self.endpoint(server.listeningPort)) == .pull)
        #expect(phone.customizations["tuya:l1"]?.isFavorite == true)
        #expect(try await SyncClient.sync(phone, endpoint: try Self.endpoint(server.listeningPort)) == nil)

        // The iPhone tells which SmartThings integration it uses; the Mac then refuses to sign in with it.
        defer { SmartThingsClaims.others = [:] }
        let iPhone = SmartThingsClaims.Claim(device: "iPhone", fingerprint: SmartThingsClaims.fingerprint("phone-client"))
        await SyncClient.exchangeClaims(iPhone, install: "phone-test", endpoint: try Self.endpoint(server.listeningPort))
        #expect(SmartThingsClaims.user(of: "phone-client") == "iPhone")
        #expect(SmartThingsClaims.problem(with: "phone-client") != nil)
        #expect(SmartThingsClaims.problem(with: "another-client") == nil)

        // A new key on the Mac: the iPhone must pair again.
        try server.forgetPairedDevices()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: SyncError.notPaired) { try await SyncClient.sync(phone, endpoint: try Self.endpoint(server.listeningPort)) }
    }

    /// Pairing uses an ECDHE key exchange, and the code stops working after a few wrong ones.
    @Test func pairingIsForwardSecretAndLimited() async throws {
        defer { cleanUp() }
        let server = SyncServer(advertise: false, state: { SyncState.capture(InMemorySettings()) }, apply: { _ in })
        var stopped = false
        server.onPairingStopped = { stopped = true }
        let code = try server.startPairing()
        try await Task.sleep(for: .milliseconds(200))
        let endpoint = try Self.endpoint(server.pairingPort)
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<SyncServer.pairingAttempts {
            #expect(server.pairingCode == code)
            await #expect(throws: SyncError.wrongCode) { try await SyncClient.pair(code: wrong, endpoint: endpoint) }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(stopped)
        #expect(server.pairingCode == nil)
        await #expect(throws: SyncError.self) { try await SyncClient.pair(code: code, endpoint: endpoint) }

        // A new code: the connection that takes the key agreed on ECDHE.
        let next = try server.startPairing()
        try await Task.sleep(for: .milliseconds(200))
        let link = SyncConnection(NWConnection(to: try Self.endpoint(server.pairingPort),
                                               using: SyncLink.parameters(secret: SyncLink.pairingSecret(next))))
        try await link.start()
        #expect(await link.negotiatedCipherSuite == SyncLink.cipherSuite)
        await link.close()
        server.stopPairing()
        #expect(!SyncClient.isPaired)
    }
}
