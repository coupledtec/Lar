import Foundation

/// A release newer than the running app.
public struct AppUpdate: Equatable, Sendable {
    public let version: String
    /// The release page, where the zip can be downloaded.
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Asks GitHub for the latest published release and compares it with the running version.
public struct UpdateChecker: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/coupledtec/Lar/releases/latest")!

    let currentVersion: String
    let transport: Transport

    public init(currentVersion: String, transport: Transport? = nil) {
        self.currentVersion = currentVersion
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    /// The latest release if it is newer than the running version, otherwise nil.
    public func availableUpdate() async throws -> AppUpdate? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await transport(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ThinQError.invalidResponse }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.drop { $0 == "v" || $0 == "V" }
        guard Self.isNewer(String(version), than: currentVersion) else { return nil }
        return AppUpdate(version: String(version), url: release.html_url)
    }

    /// Compares dotted numeric versions, ignoring a leading "v" and treating missing parts as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        let parts = version.drop { $0 == "v" || $0 == "V" }.split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : []
    }
}
