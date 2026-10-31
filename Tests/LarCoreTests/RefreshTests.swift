import Foundation
import Testing
@testable import LarCore

/// An account that answers only when told to, and counts its reads.
actor GatedProvider: DeviceProvider {
    nonisolated let provider: Provider
    private let list: [HomeDevice]
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    init(_ provider: Provider, _ list: [HomeDevice]) {
        self.provider = provider
        self.list = list
    }

    func devices() async throws -> [HomeDevice] {
        reads += 1
        await withCheckedContinuation { waiting.append($0) }
        return list
    }

    func send(_ command: HomeCommand, to device: HomeDevice) async throws {}

    /// Lets the reads waiting so far answer.
    func answer() {
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func isWaiting() -> Bool { !waiting.isEmpty }
}

@MainActor
@Suite struct RefreshTests {
    let lamp = HomeDevice(provider: .tuya, rawID: "l1", name: "Lâmpada", kind: .light, isOn: false)
    let ac = HomeDevice(provider: .lg, rawID: "a1", name: "Ar", kind: .airConditioner, isOn: true)

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }

    /// A slow account doesn't hold back the devices of the ones that already answered.
    @Test func eachAccountShowsAsItAnswers() async throws {
        let slow = GatedProvider(.lg, [ac])
        let store = HomeStore(makeProviders: { [FakeProvider(.tuya, [self.lamp]), slow] })
        let reading = Task { await store.refresh() }
        try await waitUntil { store.device(id: "tuya:l1") != nil }
        #expect(store.device(id: "lg:a1") == nil)
        await slow.answer()
        await reading.value
        #expect(store.devices.map(\.name) == ["Ar", "Lâmpada"])
    }

    /// A read asked for while one is going (a command's confirmation) runs once that one ends, not never.
    @Test func readAskedDuringAReadRunsAfterIt() async throws {
        let tuya = GatedProvider(.tuya, [lamp])
        let store = HomeStore(makeProviders: { [tuya] })
        let first = Task { await store.refresh() }
        try await waitUntil { await tuya.isWaiting() }
        await store.refresh()
        await tuya.answer()
        try await waitUntil { await tuya.reads == 2 }
        await tuya.answer()
        await first.value
        #expect(await tuya.reads == 2)
        #expect(!store.isRefreshing)
    }

    /// The list is built once and kept; a name, an optimistic change or its end show at once.
    @Test func builtListFollowsEveryChange() async throws {
        let clock = TestClock()
        let stubborn = StubbornProvider(.tuya, [lamp])
        let store = HomeStore(makeProviders: { [stubborn] }, now: { clock.now }, sleep: { _ in })
        await store.refresh()
        #expect(store.device(id: "tuya:l1")?.isOn == false)
        store.customizations["tuya:l1"] = DeviceCustomization(name: "Abajur")
        #expect(store.device(id: "tuya:l1")?.name == "Abajur")
        store.perform(.power(true), on: "tuya:l1")
        #expect(store.device(id: "tuya:l1")?.isOn == true)
        try await waitUntil { !store.isSending }
        // The device never takes it: once the change expires the list shows what the account says, with no new read.
        clock.now += HomeStore.overrideLifetime * 3
        #expect(store.device(id: "tuya:l1")?.isOn == false)
        #expect(store.devices.map(\.name) == ["Abajur"])
    }
}

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// An account that takes commands without ever changing.
actor StubbornProvider: DeviceProvider {
    nonisolated let provider: Provider
    private let list: [HomeDevice]

    init(_ provider: Provider, _ list: [HomeDevice]) {
        self.provider = provider
        self.list = list
    }

    func devices() async throws -> [HomeDevice] { list }
    func send(_ command: HomeCommand, to device: HomeDevice) async throws {}
}
