import Foundation
import Testing
@testable import LarCore

/// Drives the real TV; runs only with LAR_LIVE_TV=1. Uses the app's key file (already approved on the TV).
@Suite(.serialized) struct LiveTVTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["LAR_LIVE_TV"] == "1"

    @Test(.enabled(if: enabled))
    func remoteRoundTrip() async throws {
        let provider = AndroidTVProvider()
        func state() async throws -> HomeDevice {
            let tvs = try await provider.devices().filter(\.isOnline)
            return try #require(tvs.first)
        }
        func step(_ title: String, _ wait: Double = 1.5) async throws -> HomeDevice {
            try await Task.sleep(for: .seconds(wait))
            let tv = try await state()
            print("STEP \(title): on=\(tv.isOn ?? false) app=\(tv.detail) host=\(tv.controls["host"] ?? "")")
            return tv
        }
        var tv = try await step("start", 0)
        try await provider.press(.home, on: tv); tv = try await step("home")
        try await provider.press(.right, on: tv); try await provider.press(.left, on: tv); tv = try await step("right+left", 0.5)
        try await provider.press(.volumeUp, on: tv); try await provider.press(.volumeDown, on: tv); tv = try await step("volume", 0.5)
        let apps = try await provider.apps(on: tv)
        print("APPS: \(apps.map(\.name).joined(separator: ", "))")
        try await provider.openApp("com.google.android.youtube.tv", on: tv); tv = try await step("youtube", 5)
        #expect(tv.detail == "YouTube")
        try await provider.press(.home, on: tv); tv = try await step("home again", 2)
        // Power isn't driven here: in standby this TV drops off the network and only the remote turns it back on.
    }
}
