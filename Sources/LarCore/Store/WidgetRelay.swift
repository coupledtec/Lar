#if os(macOS)
import Foundation

/// The Mac App Store version's widgets, which live in their own sandboxed process with no accounts: the app (always
/// in the menu bar) leaves them the list in a folder they share (an app group), and they leave the app what was
/// tapped, with a ping. The app sends it, saves the new list and asks them to redraw. Nothing secret goes there.
public enum WidgetRelay {
    /// What the widgets show.
    public struct Feed: Codable, Sendable, Equatable {
        public var date: Date
        /// The visible devices, with the owner's names, favorites first.
        public var devices: [HomeDevice]
        public var favorites: [String]
        /// Each device's room.
        public var rooms: [String: String]
        public var scenes: [HomeScene]

        public init(date: Date, devices: [HomeDevice], favorites: [String], rooms: [String: String], scenes: [HomeScene]) {
            self.date = date
            self.devices = devices
            self.favorites = favorites
            self.rooms = rooms
            self.scenes = scenes
        }

        /// The same list, whenever it was saved.
        public func sameContent(as other: Feed?) -> Bool {
            guard let other else { return false }
            return devices == other.devices && favorites == other.favorites && rooms == other.rooms && scenes == other.scenes
        }
    }

    /// What a widget asks the app to do.
    public enum Request: Codable, Sendable, Equatable {
        case command(deviceID: String, HomeCommand)
        /// A remote's key (`AndroidTVProvider.Key.rawValue`).
        case key(deviceID: String, Int)
    }

    /// The app group both sides name in their Info.plist (`LarAppGroup`); nil outside the App Store version.
    public static var groupID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "LarAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static var isAvailable: Bool { folder != nil }

    static var folder: URL? {
        guard let groupID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static var feedURL: URL? { folder?.appending(path: "widgets.json") }
    private static var requestsFolder: URL? { folder?.appending(path: "requests", directoryHint: .isDirectory) }
    private static var pingName: String? { groupID.map { $0 + ".request" } }

    // MARK: The list

    public static func write(_ feed: Feed) {
        guard let url = feedURL, let data = try? JSONEncoder().encode(feed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readFeed() -> Feed? {
        guard let url = feedURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Feed.self, from: data)
    }

    // MARK: Requests

    /// Leaves a request for the app and pings it.
    public static func send(_ request: Request) throws {
        guard let folder = requestsFolder, let name = pingName else { throw RelayError.unavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Named by time, so the app sends them in the order they were tapped.
        let file = folder.appending(path: String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString))
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString),
                                             nil, nil, true)
    }

    /// The requests waiting, oldest first, removed as they're read. Ones older than a minute are dropped: a tap
    /// while the app was closed shouldn't switch a light on much later.
    public static func takeRequests(now: Date = Date()) -> [Request] {
        guard let folder = requestsFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            let stamp = Double(file.lastPathComponent.split(separator: "-").first ?? "") ?? 0
            guard now.timeIntervalSince1970 - stamp < 60, let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Request.self, from: data)
        }
    }

    /// Calls `handler` (on the main thread) each time a widget leaves a request.
    public static func observeRequests(_ handler: @escaping @MainActor () -> Void) {
        guard let name = pingName else { return }
        observer = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { WidgetRelay.observer?() } }
        }, name as CFString, nil, .deliverImmediately)
    }

    nonisolated(unsafe) private static var observer: (@MainActor () -> Void)?

    public enum RelayError: Error {
        case unavailable
    }
}

/// The widgets' side: the devices as the app left them, and each command passed on to the app. One per account
/// kind, like the accounts themselves, so the list's store sends each device's commands here.
public struct WidgetRelayProvider: TVRemoteProvider {
    public let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    public func devices() async throws -> [HomeDevice] {
        (WidgetRelay.readFeed()?.devices ?? []).filter { $0.provider == provider }
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        try WidgetRelay.send(.command(deviceID: device.id, command))
    }

    public func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {
        try WidgetRelay.send(.key(deviceID: device.id, key.rawValue))
    }

    public func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] { [] }
    public func openApp(_ package: String, on device: HomeDevice) async throws {}
    public func type(_ text: String, on device: HomeDevice) async throws {}
}
#endif
