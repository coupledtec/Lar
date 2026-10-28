import Foundation
import Testing
@testable import LarCore

@Suite(.serialized) struct WatchHandoffTests {
    @Test func handoffIsTakenOnceAndKeepsTheWatchsOwn() {
        let settings = InMemorySettings()
        let handoff = WatchSmartThingsHandoff(credentials: .init(clientID: "w", secret: "s", refreshToken: "r1"))
        #expect(handoff.apply(to: settings))
        #expect(settings.smartThings == .oauth(clientID: "w", secret: "s", refreshToken: "r1"))
        #expect(WatchSmartThingsHandoff.ownOnWatch)

        // The watch renews (new refresh token); the same handoff delivered again must not bring the old one back.
        settings.smartThings = .oauth(clientID: "w", secret: "s", refreshToken: "r2")
        #expect(!handoff.apply(to: settings))
        #expect(settings.smartThings == .oauth(clientID: "w", secret: "s", refreshToken: "r2"))

        // The iPhone's 24 h token doesn't replace the watch's own integration.
        WatchPayload(lgToken: nil, tuya: nil, smartThingsAccessToken: "phone", smartThingsExpires: nil,
                     temperatureLimits: .standard).apply(to: settings)
        #expect(settings.smartThings == .oauth(clientID: "w", secret: "s", refreshToken: "r2"))

        // Handed back to the iPhone: its token is taken again.
        #expect(WatchSmartThingsHandoff(credentials: nil).apply(to: settings))
        #expect(!WatchSmartThingsHandoff.ownOnWatch)
        WatchPayload(lgToken: nil, tuya: nil, smartThingsAccessToken: "phone", smartThingsExpires: nil,
                     temperatureLimits: .standard).apply(to: settings)
        #expect(settings.smartThings == .personalToken("phone"))
    }
}
