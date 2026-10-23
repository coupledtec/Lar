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
        let server = SyncServer(advertise: false, state: { SyncState.capture(mac) }, apply: { $0.apply(to: mac) })
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

        // A new key on the Mac: the iPhone must pair again.
        try server.forgetPairedDevices()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: SyncError.notPaired) { try await SyncClient.sync(phone, endpoint: try Self.endpoint(server.listeningPort)) }
    }
}
