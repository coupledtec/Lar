import Foundation
import Network

/// Finds Android TVs / Google TVs on the local network: they advertise the Google TV Remote service
/// (`_androidtvremote2._tcp`) under their own name ("TV do Quarto"). Each one is then resolved to its current IPv4
/// address, so a TV whose address the router changed is found again.
public enum TVDiscovery {
    public struct Found: Sendable, Equatable {
        public var name: String
        public var host: String

        public init(name: String, host: String) {
            self.name = name
            self.host = host
        }
    }

    public static let serviceType = "_androidtvremote2._tcp"
    static let browseTime: Duration = .seconds(2)
    static let resolveTimeout: Duration = .seconds(3)

    public static func scan() async -> [Found] {
        let services = await browse()
        return await withTaskGroup(of: Found?.self) { group in
            for (name, endpoint) in services {
                group.addTask {
                    guard let host = await resolve(endpoint) else { return nil }
                    return Found(name: name, host: host)
                }
            }
            var out: [Found] = []
            for await found in group { if let found { out.append(found) } }
            return out.sorted { $0.name < $1.name }
        }
    }

    /// The services seen during a short browse.
    private static func browse() async -> [(String, NWEndpoint)] {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        let seen = Locked<[String: NWEndpoint]>([:])
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint { seen.update { $0[name] = result.endpoint } }
            }
        }
        browser.start(queue: .global(qos: .utility))
        try? await Task.sleep(for: browseTime)
        browser.cancel()
        return seen.value.map { ($0.key, $0.value) }
    }

    /// Connects to the service just long enough to learn the TV's IPv4 address.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = Once()
        let host: String? = await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var address: String?
                    if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint {
                        address = Self.text(host)
                    }
                    once.run { continuation.resume(returning: address) }
                case .failed, .cancelled:
                    once.run { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
                once.run { continuation.resume(returning: nil) }
            }
        }
        connection.cancel()
        return host
    }

    static func text(_ host: NWEndpoint.Host) -> String? {
        switch host {
        // Without the interface ("192.168.1.50%en0" → "192.168.1.50").
        case .ipv4(let address): "\(address)".split(separator: "%").first.map(String.init)
        case .name(let name, _): name
        default: nil
        }
    }
}

/// A value shared with callbacks on other queues.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
