import Foundation

extension Array where Element: Sendable {
    /// `transform` on every element, a few at a time, keeping the order. The first error stops the rest.
    /// Reading each device's state this way makes a refresh take about as long as the slowest device, not their sum.
    func concurrentMap<T: Sendable>(limit: Int = 6, _ transform: @escaping @Sendable (Element) async throws -> T) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0
            func addNext() {
                guard next < count else { return }
                let index = next, element = self[index]
                group.addTask { (index, try await transform(element)) }
                next += 1
            }
            for _ in 0..<Swift.min(limit, count) { addNext() }
            while let (index, value) = try await group.next() {
                results[index] = value
                addNext()
            }
            return results.map { $0! }
        }
    }
}
