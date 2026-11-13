import Foundation

/// An LG TV (webOS) on the home network, as LG's own remote app talks to it and the open aiowebostv library
/// documents: a WebSocket (wss on 3001, plain on 3000 for older ones) that the TV accepts once with a prompt on screen,
/// handing back a client key; then requests ("ssap://…") for volume, channels, apps, inputs, text and power, and a
/// second socket for the remote's buttons. Unofficial: LG may change it.
public actor LGWebOSClient {
    let host: String
    private(set) var clientKey: String?
    private var socket: LocalWebSocket?
    private var input: LocalWebSocket?
    private var counter = 0

    public init(host: String, clientKey: String?) {
        self.host = host
        self.clientKey = clientKey
    }

    /// The manifest LG's remote app registers with, unsigned (newer firmware refuses the old signature).
    static func registration(clientKey: String?) -> [String: Any] {
        let permissions = [
            "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_PLAYBACK",
            "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT", "CONTROL_INPUT_TV", "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER",
            "CONTROL_TV_SCREEN", "LAUNCH", "LAUNCH_WEBAPP", "READ_APP_STATUS", "READ_COUNTRY_INFO", "READ_CURRENT_CHANNEL",
            "READ_INPUT_DEVICE_LIST", "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_LGE_TV_INPUT_EVENTS", "READ_NETWORK_STATE",
            "READ_NOTIFICATIONS", "READ_POWER_STATE", "READ_RUNNING_APPS", "READ_SETTINGS", "READ_TV_CHANNEL_LIST",
            "READ_TV_CURRENT_TIME", "READ_UPDATE_INFO", "SEARCH", "TEST_OPEN", "TEST_PROTECTED", "TEST_SECURE",
            "UPDATE_FROM_REMOTE_APP", "WRITE_NOTIFICATION_ALERT", "WRITE_NOTIFICATION_TOAST", "WRITE_SETTINGS",
        ]
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": ["appVersion": "1.1", "manifestVersion": 1, "permissions": permissions] as [String: Any],
        ]
        if let clientKey { payload["client-key"] = clientKey }
        return ["type": "register", "id": "register_0", "payload": payload]
    }

    /// Connects and registers; the first time the TV asks on screen and the key comes back (saved by the caller).
    @discardableResult
    public func connect() async throws -> String {
        if socket != nil, let clientKey { return clientKey }
        var lastError: Error = ProviderError.network(tr("A TV LG não respondeu"))
        for address in ["wss://\(host):3001", "ws://\(host):3000"] {
            guard let url = URL(string: address) else { continue }
            let socket = LocalWebSocket(url: url)
            do {
                try await socket.send(json: Self.registration(clientKey: clientKey))
                var answer = try await socket.receiveJSON()
                // A first pairing: the TV shows its prompt, and the answer comes once the owner accepts.
                if answer["type"]?.string == "response",
                   answer["payload"]?["pairingType"]?.string == "PROMPT" {
                    answer = try await socket.receiveJSON(timeout: 60)
                }
                guard answer["type"]?.string == "registered" else {
                    throw ProviderError.api(answer["error"]?.string ?? tr("A TV LG recusou o Lar. Aceite o pedido que aparece na tela."))
                }
                if let key = answer["payload"]?["client-key"]?.string { clientKey = key }
                guard let clientKey else { throw ProviderError.api(tr("A TV LG não devolveu a chave")) }
                self.socket = socket
                return clientKey
            } catch {
                socket.close()
                lastError = error
            }
        }
        throw lastError
    }

    /// One request; its answer's payload.
    @discardableResult
    public func request(_ uri: String, _ payload: [String: Any] = [:]) async throws -> JSONValue {
        try await connect()
        guard let socket else { throw ProviderError.network(tr("A TV LG não respondeu")) }
        counter += 1
        let id = "lar_\(counter)"
        do {
            try await socket.send(json: ["id": id, "type": "request", "uri": "ssap://" + uri, "payload": payload])
            for _ in 0..<20 {
                let answer = try await socket.receiveJSON()
                guard answer["id"]?.string == id else { continue }
                if answer["type"]?.string == "error" {
                    throw ProviderError.api(answer["error"]?.string ?? tr("A TV LG recusou o comando"))
                }
                return answer["payload"] ?? .object([:])
            }
            throw ProviderError.network(tr("A TV LG não respondeu"))
        } catch {
            close()
            throw error
        }
    }

    /// A remote button ("UP", "ENTER", "BACK", "HOME"…), on the pointer socket the TV hands out.
    public func button(_ name: String) async throws {
        if input == nil {
            let answer = try await request("com.webos.service.networkinput/getPointerInputSocket")
            guard let path = answer["socketPath"]?.string, let url = URL(string: path) else {
                throw ProviderError.api(tr("A TV LG não abriu o controle"))
            }
            input = LocalWebSocket(url: url)
        }
        do {
            try await input?.send("type:button\nname:\(name)\n\n")
        } catch {
            input?.close()
            input = nil
            throw error
        }
    }

    public func close() {
        socket?.close()
        input?.close()
        socket = nil
        input = nil
    }

    // MARK: What the TV offers

    public struct App: Sendable, Equatable {
        public var id: String
        public var title: String
    }

    public func apps() async throws -> [App] {
        let answer = try await request("com.webos.applicationManager/listLaunchPoints")
        return (answer["launchPoints"]?.array ?? []).compactMap { point in
            guard let id = point["id"]?.string ?? point["launchPointId"]?.string, let title = point["title"]?.string else { return nil }
            return App(id: id, title: title)
        }
    }

    /// The HDMI and other inputs, as "inputs" the remote can open like apps.
    public func inputs() async throws -> [App] {
        let answer = try await request("tv/getExternalInputList")
        return (answer["devices"]?.array ?? []).compactMap { device in
            guard let id = device["id"]?.string else { return nil }
            return App(id: "input:" + id, title: device["label"]?.string ?? id)
        }
    }

    public func open(_ id: String) async throws {
        if id.hasPrefix("input:") {
            try await request("tv/switchInput", ["inputId": String(id.dropFirst(6))])
        } else {
            try await request("system.launcher/launch", ["id": id])
        }
    }

    public func foregroundApp() async throws -> String? {
        try await request("com.webos.applicationManager/getForegroundAppInfo")["appId"]?.string
    }

    public func type(_ text: String) async throws {
        try await request("com.webos.service.ime/insertText", ["text": text, "replace": 0])
    }

    public func enter() async throws {
        try await request("com.webos.service.ime/sendEnterKey")
    }

    public func turnOff() async throws {
        try await request("system/turnOff")
    }

    public func setVolume(_ level: Int) async throws {
        try await request("audio/setVolume", ["volume": max(0, min(100, level))])
    }

    public func toast(_ message: String) async throws {
        try await request("system.notifications/createToast", ["message": message])
    }

    /// The remote's button for one of the Lar's keys.
    static func buttonName(_ key: AndroidTVProvider.Key) -> String {
        switch key {
        case .up: "UP"
        case .down: "DOWN"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .select, .enter: "ENTER"
        case .back: "BACK"
        case .home: "HOME"
        case .playPause: "PLAY"
        case .volumeUp: "VOLUMEUP"
        case .volumeDown: "VOLUMEDOWN"
        case .mute: "MUTE"
        case .inputs: "INPUT_HUB"
        case .channelUp: "CHANNELUP"
        case .channelDown: "CHANNELDOWN"
        }
    }
}
