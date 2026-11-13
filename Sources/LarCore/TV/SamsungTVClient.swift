import Foundation

/// A Samsung TV (Tizen, 2016 on) on the home network, as Samsung's SmartThings remote talks to it and the open
/// samsung-tv-ws-api library documents: a WebSocket on 8002 (TLS) that the TV allows once with a prompt on screen,
/// handing back a token; then the remote's keys ("KEY_UP"…), text, and the apps (listed and opened). The TV's own
/// REST answer says whether it's on. Unofficial: Samsung may change it.
public actor SamsungTVClient {
    let host: String
    private(set) var token: String?
    private var socket: LocalWebSocket?
    static let clientName = "Lar"

    public init(host: String, token: String?) {
        self.host = host
        self.token = token
    }

    /// Connects; the first time the TV asks on screen and the token comes back (saved by the caller).
    @discardableResult
    public func connect() async throws -> String? {
        if socket != nil { return token }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = 8002
        components.path = "/api/v2/channels/samsung.remote.control"
        var query = [URLQueryItem(name: "name", value: Data(Self.clientName.utf8).base64EncodedString())]
        if let token { query.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = query
        guard let url = components.url else { throw ProviderError.api("URL") }
        let socket = LocalWebSocket(url: url)
        do {
            // The answer waits for the owner to allow it on the TV the first time.
            for _ in 0..<5 {
                let answer = try await socket.receiveJSON(timeout: 45)
                let event = answer["event"]?.string
                if event == "ms.channel.unauthorized" {
                    throw ProviderError.api(tr("A TV Samsung recusou o Lar. Permita o acesso no aviso que aparece na tela."))
                }
                if event == "ms.channel.connect" {
                    if let token = answer["data"]?["token"]?.string { self.token = token }
                    self.socket = socket
                    return self.token
                }
            }
            throw ProviderError.network(tr("A TV Samsung não respondeu"))
        } catch {
            socket.close()
            throw error
        }
    }

    private func send(_ message: [String: Any]) async throws {
        try await connect()
        do {
            try await socket?.send(json: message)
        } catch {
            close()
            throw error
        }
    }

    /// A remote key ("KEY_UP", "KEY_ENTER", "KEY_RETURN"…).
    public func key(_ name: String) async throws {
        try await send(["method": "ms.remote.control",
                        "params": ["Cmd": "Click", "DataOfCmd": name, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    public func type(_ text: String) async throws {
        try await send(["method": "ms.remote.control",
                        "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"]])
    }

    public struct App: Sendable, Equatable {
        public var id: String
        public var name: String
    }

    public func apps() async throws -> [App] {
        try await send(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
        for _ in 0..<10 {
            guard let answer = try await socket?.receiveJSON(), answer["event"]?.string == "ed.installedApp.get" else { continue }
            let list = answer["data"]?["data"]?.array ?? []
            return list.compactMap { app in
                guard let id = app["appId"]?.string, let name = app["name"]?.string else { return nil }
                return App(id: id, name: name)
            }
        }
        return []
    }

    public func open(_ id: String) async throws {
        try await send(["method": "ms.channel.emit",
                        "params": ["event": "ed.apps.launch", "to": "host",
                                   "data": ["action_type": "DEEP_LINK", "appId": id, "metaTag": ""] as [String: Any]] as [String: Any]])
    }

    public func close() {
        socket?.close()
        socket = nil
    }

    /// Whether the TV is on (its REST answer, no pairing needed): "on", "standby", or nil when it doesn't answer.
    public static func powerState(host: String) async -> String? {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let device = object["device"] as? [String: Any]
        return (device?["PowerState"] as? String) ?? "on"
    }

    /// The TV's name and Wi-Fi MAC (for waking it), from the same answer.
    public static func info(host: String) async -> (name: String?, mac: String?) {
        guard let url = URL(string: "http://\(host):8001/api/v2/"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let device = object["device"] as? [String: Any]
        return (device?["name"] as? String ?? object["name"] as? String, device?["wifiMac"] as? String)
    }

    /// The remote's key for one of the Lar's keys.
    static func keyName(_ key: AndroidTVProvider.Key) -> String {
        switch key {
        case .up: "KEY_UP"
        case .down: "KEY_DOWN"
        case .left: "KEY_LEFT"
        case .right: "KEY_RIGHT"
        case .select, .enter: "KEY_ENTER"
        case .back: "KEY_RETURN"
        case .home: "KEY_HOME"
        case .playPause: "KEY_PLAY"
        case .volumeUp: "KEY_VOLUP"
        case .volumeDown: "KEY_VOLDOWN"
        case .mute: "KEY_MUTE"
        case .inputs: "KEY_SOURCE"
        case .channelUp: "KEY_CHUP"
        case .channelDown: "KEY_CHDOWN"
        }
    }
}
