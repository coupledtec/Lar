import Foundation
import Testing
@testable import LarCore

@Suite struct ConcurrencyTests {
    actor Gauge {
        var running = 0, peak = 0
        func enter() { running += 1; peak = max(peak, running) }
        func leave() { running -= 1 }
    }

    @Test func keepsOrderAndLimit() async throws {
        let gauge = Gauge()
        let out = try await Array(0..<20).concurrentMap(limit: 4) { n in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(Int.random(in: 1...15)))
            await gauge.leave()
            return n * 2
        }
        #expect(out == Array(0..<20).map { $0 * 2 })
        #expect(await gauge.peak <= 4)
        #expect(await gauge.peak > 1)
    }

    @Test func firstErrorStops() async {
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await [1, 2, 3].concurrentMap { n -> Int in
                if n == 2 { throw ProviderError.unauthorized }
                return n
            }
        }
    }

    @Test func emptyIsEmpty() async throws {
        #expect(try await [Int]().concurrentMap { $0 }.isEmpty)
    }
}
