import Foundation

/// The watch's TVs go through the iPhone: watchOS doesn't let apps open connections to devices on the local network,
/// so the watch sends a request (WatchConnectivity) and the iPhone talks to the TV and answers.
public enum TVRelay {
    /// The key the request and the reply travel under in a WatchConnectivity message.
    public static let messageKey = "tv"

    public enum Request: Codable, Sendable, Equatable {
        case devices
        case power(id: String, on: Bool)
        case key(id: String, code: Int)
        case apps(id: String)
        case openApp(id: String, package: String)
        case text(id: String, text: String)
    }

    public struct Reply: Codable, Sendable, Equatable {
        public var devices: [HomeDevice]?
        public var apps: [AndroidTVProvider.App]?
        public var error: String?

        public init(devices: [HomeDevice]? = nil, apps: [AndroidTVProvider.App]? = nil, error: String? = nil) {
            self.devices = devices
            self.apps = apps
            self.error = error
        }
    }

    /// The iPhone's side: runs a request on its TVs. `known` is the iPhone's current list, used to find a TV
    /// without reading them all again (the TVs are read when it's empty, e.g. the iPhone app woken in the background).
    public static func handle(_ request: Request, tv: (any TVRemoteProvider)?, known: [HomeDevice]) async -> Reply {
        guard let tv else { return Reply(error: tr("Sem TVs no iPhone")) }
        func find(_ id: String) async throws -> HomeDevice {
            if let device = known.first(where: { $0.id == id }) { return device }
            if let device = try await tv.devices().first(where: { $0.id == id }) { return device }
            throw ProviderError.api(tr("A TV não foi encontrada pelo iPhone"))
        }
        do {
            switch request {
            case .devices:
                return Reply(devices: try await tv.devices())
            case .power(let id, let on):
                try await tv.send(.power(on), to: try await find(id))
            case .key(let id, let code):
                guard let key = AndroidTVProvider.Key(rawValue: code) else { throw ProviderError.unsupported }
                try await tv.press(key, on: try await find(id))
            case .apps(let id):
                return Reply(apps: try await tv.apps(on: try await find(id)))
            case .openApp(let id, let package):
                try await tv.openApp(package, on: try await find(id))
            case .text(let id, let text):
                try await tv.type(text, on: try await find(id))
            }
            return Reply()
        } catch {
            return Reply(error: (error as? ProviderError)?.message ?? error.localizedDescription)
        }
    }
}

/// The watch's side: the iPhone's TVs as an account of the watch's own, every call a request to the iPhone.
/// A pairable TV (not paired on the iPhone yet) has nothing to control from the wrist and is left out.
public actor RelayedTVProvider: TVRemoteProvider {
    public nonisolated let provider = Provider.androidTV
    private let send: @Sendable (Data) async throws -> Data

    /// - Parameter send: delivers an encoded request to the iPhone and returns its encoded reply.
    public init(send: @escaping @Sendable (Data) async throws -> Data) {
        self.send = send
    }

    public func devices() async throws -> [HomeDevice] {
        (try await ask(.devices).devices ?? []).filter { $0.controls["pairable"] == nil || $0.controls["link"] == "remote" }
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command else { throw ProviderError.unsupported }
        _ = try await ask(.power(id: device.id, on: on))
    }

    public func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {
        _ = try await ask(.key(id: device.id, code: key.rawValue))
    }

    public func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] {
        try await ask(.apps(id: device.id)).apps ?? []
    }

    public func openApp(_ package: String, on device: HomeDevice) async throws {
        _ = try await ask(.openApp(id: device.id, package: package))
    }

    public func type(_ text: String, on device: HomeDevice) async throws {
        _ = try await ask(.text(id: device.id, text: text))
    }

    private func ask(_ request: TVRelay.Request) async throws -> TVRelay.Reply {
        let data: Data
        do {
            data = try await send(try JSONEncoder().encode(request))
        } catch {
            throw ProviderError.network(tr("iPhone fora de alcance"))
        }
        let reply = try JSONDecoder().decode(TVRelay.Reply.self, from: data)
        if let error = reply.error { throw ProviderError.api(error) }
        return reply
    }
}
