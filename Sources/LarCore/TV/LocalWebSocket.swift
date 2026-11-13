import Foundation

/// A WebSocket to a TV on the home network: text messages in and out, the TV's self-signed certificate accepted
/// (they all have one; the pairing key is what proves who's who).
final class LocalWebSocket: NSObject, URLSessionDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var socketTask: URLSessionWebSocketTask!

    init(url: URL) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        socketTask = session.webSocketTask(with: url)
        socketTask.maximumMessageSize = 4 << 20
        socketTask.resume()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    nonisolated(nonsending) func send(_ text: String) async throws {
        try await socketTask.send(.string(text))
    }

    nonisolated(nonsending) func send(json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await send(String(decoding: data, as: UTF8.self))
    }

    /// The next message as JSON (text or data), within `timeout` seconds.
    func receiveJSON(timeout: Double = 8) async throws -> JSONValue {
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [socketTask] in
                switch try await socketTask!.receive() {
                case .string(let text): return Data(text.utf8)
                case .data(let raw): return raw
                @unknown default: return Data()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProviderError.network(tr("A TV não respondeu"))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    func close() {
        socketTask.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
