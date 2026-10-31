import Foundation
import Testing
@testable import LarCore

@Suite struct DemoHomeTests {
    @Test func everyAccountKindHasDevicesThatAnswer() async throws {
        let providers = DemoHome.providers()
        #expect(Set(providers.map(\.provider)) == Set(Provider.allCases))
        let lights = try #require(providers.first { $0.provider == .tuya })
        let porch = try #require(try await lights.devices().first { $0.rawID == "porch" })
        #expect(porch.isOn == false)
        try await lights.send(.power(true), to: porch)
        #expect(try await lights.devices().first { $0.rawID == "porch" }?.isOn == true)
        try await lights.send(.brightness(0), to: porch)
        #expect(try await lights.devices().first { $0.rawID == "porch" }?.isOn == false)
    }
}
