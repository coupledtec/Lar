import Foundation
import Testing
@testable import LarCore

/// Talks to the real accounts; runs only with LAR_LIVE_LG / LAR_LIVE_TUYA_ID / LAR_LIVE_TUYA_SECRET set.
@MainActor
@Suite struct LiveTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["LAR_LIVE_LG"] != nil))
    func repeatedRefreshesKeepEachDeviceOnce() async {
        var providers: [any DeviceProvider] = []
        if let lg = Self.env["LAR_LIVE_LG"] { providers.append(LGProvider(client: ThinQClient(token: lg, clientID: "lar-live-test"))) }
        if let id = Self.env["LAR_LIVE_TUYA_ID"], let secret = Self.env["LAR_LIVE_TUYA_SECRET"] {
            providers.append(TuyaClient(credentials: .init(clientID: id, secret: secret)))
        }
        let store = HomeStore(makeProviders: { providers })
        for round in 1...3 {
            await store.refresh()
            let ids = store.devices.map(\.id)
            print("round \(round): \(ids.count) devices, \(Set(ids).count) unique; accounts \(store.accounts)")
            #expect(ids.count == Set(ids).count)
        }
    }
}
