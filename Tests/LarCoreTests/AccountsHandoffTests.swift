import Foundation
import Network
import Testing
@testable import LarCore

/// The Apple TV set up from the iPhone: the accounts go through with the right code, never with a wrong one.
@Suite struct AccountsHandoffTests {
    final class Box: @unchecked Sendable { var accounts: AccountsImport? }

    @Test func accountsGoThroughWithTheCode() async throws {
        let box = Box()
        let receiver = AccountsHandoff.Receiver(name: "Teste", advertise: false) { box.accounts = $0 }
        try receiver.start()
        defer { receiver.stop() }
        var port: NWEndpoint.Port?
        for _ in 0..<50 where port == nil || port?.rawValue == 0 {
            port = receiver.port
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200))
        let device = AccountsHandoff.Device(name: "Teste", endpoint: .hostPort(host: "127.0.0.1", port: try #require(port)))
        let wrong = receiver.code == "0000" ? "1111" : "0000"
        await #expect(throws: ProviderError.self) {
            try await AccountsHandoff.send(AccountsImport(lgToken: "x"), to: device, code: wrong)
        }
        #expect(box.accounts == nil)
        try await AccountsHandoff.send(AccountsImport(lgToken: "thinqpat_teste", xbox: nil), to: device, code: receiver.code)
        for _ in 0..<50 where box.accounts == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.accounts?.lgToken == "thinqpat_teste")
        #expect(AccountsHandoff.summary(box.accounts!) == "LG ThinQ")
    }
}
