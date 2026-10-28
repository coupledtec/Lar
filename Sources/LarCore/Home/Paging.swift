import Foundation

/// A page of a long list (the scenes, with many imported Alexa routines; the routines on an Echo's screen).
public struct Paged<Item> {
    public let items: [Item]
    /// 0-based, already clamped to the pages there are.
    public let page: Int
    public let pages: Int

    public var hasPrevious: Bool { page > 0 }
    public var hasNext: Bool { page < pages - 1 }
    /// "2 de 5".
    public var label: String { tr("\(page + 1) de \(pages)") }

    public init(_ all: [Item], page: Int, size: Int) {
        let size = max(1, size)
        pages = max(1, (all.count + size - 1) / size)
        self.page = min(max(page, 0), pages - 1)
        items = Array(all.dropFirst(self.page * size).prefix(size))
    }
}
