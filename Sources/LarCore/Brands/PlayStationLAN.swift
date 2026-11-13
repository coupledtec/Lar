import Foundation

extension PlayStationRemotePlay {
    /// Plain sockets on the home network (one UDP question and its answer, one TCP request read to its end), off the
    /// main thread with timeouts.
    enum LAN {
        static func address(_ host: String, port: UInt16) -> sockaddr_in? {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
            return address
        }

        private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
            }
        }

        private static func setTimeout(_ socket: Int32, _ seconds: Double) {
            var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        private static func sendTo(_ socket: Int32, _ message: Data, _ address: sockaddr_in) -> Bool {
            var address = address
            return message.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, bytes.baseAddress, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } == message.count
        }

        /// Sends one datagram and waits for the first answer.
        static func udp(host: String, port: UInt16, _ message: Data, timeout: Double) async -> Data? {
            guard let target = address(host, port: port) else { return nil }
            return await run {
                let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard socket >= 0 else { return nil }
                defer { close(socket) }
                setTimeout(socket, timeout)
                guard sendTo(socket, message, target) else { return nil }
                var buffer = [UInt8](repeating: 0, count: 2048)
                let count = recv(socket, &buffer, buffer.count, 0)
                return count > 0 ? Data(buffer[0..<count]) : nil
            }
        }

        /// Sends one datagram, no answer expected (the wake-up), a few times since UDP may drop it.
        static func send(host: String, port: UInt16, _ message: Data) async -> Bool {
            guard let target = address(host, port: port) else { return false }
            return await run {
                let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard socket >= 0 else { return false }
                defer { close(socket) }
                var sent = false
                for _ in 0..<3 {
                    sent = sendTo(socket, message, target) || sent
                    usleep(100_000)
                }
                return sent
            }
        }

        /// Connects, sends the request and reads until the console closes the connection.
        static func tcp(host: String, port: UInt16, _ request: Data, timeout: Double) async throws -> Data {
            guard let address = address(host, port: port) else { throw ProviderError.api(tr("Endereço inválido: \(host)")) }
            let result: Data? = await run {
                let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard socket >= 0 else { return nil }
                defer { close(socket) }
                setTimeout(socket, timeout)
                var target = address
                let connected = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connected == 0 else { return nil }
                let written = request.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, request.count, 0) }
                guard written == request.count else { return nil }
                var out = Data()
                var buffer = [UInt8](repeating: 0, count: 2048)
                while true {
                    let count = recv(socket, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    out.append(contentsOf: buffer[0..<count])
                }
                return out
            }
            guard let result, !result.isEmpty else { throw ProviderError.network(tr("O PS5 não respondeu ao pareamento")) }
            return result
        }

        /// The control channel: connects, sends the request and reads its answer's header; when accepted, stays for
        /// `stay` seconds answering the console's messages with `reply` (its heartbeat, the login code) and sends
        /// `commands` once it has started talking. Returns the answer's header and the types of what the console sent.
        static func control(host: String, port: UInt16, _ request: Data, timeout: Double, stay: Double, commands: [Data],
                            reply: @escaping @Sendable (UInt16, Data) -> Data?) async throws -> (head: Data, received: [UInt16]) {
            guard let address = address(host, port: port) else { throw ProviderError.api(tr("Endereço inválido: \(host)")) }
            let result: (Data, [UInt16])? = await run {
                let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard socket >= 0 else { return nil }
                defer { close(socket) }
                setTimeout(socket, timeout)
                var target = address
                let connected = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connected == 0 else { return nil }
                func write(_ data: Data) { _ = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, data.count, 0) } }
                write(request)
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while pending.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let count = recv(socket, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    pending.append(contentsOf: buffer[0..<count])
                }
                guard let end = pending.range(of: Data("\r\n\r\n".utf8)) else { return (pending, []) }
                let head = Data(pending[..<end.upperBound])
                guard head.starts(with: Data("HTTP/1.1 200".utf8)) else { return (head, []) }
                pending = Data(pending[end.upperBound...])
                setTimeout(socket, 0.25)
                var received: [UInt16] = []
                var commands = commands
                let start = Date()
                while Date().timeIntervalSince(start) < stay {
                    // Each message: its payload's size (4 bytes), its type (2) and 2 more.
                    while pending.count >= 8 {
                        let size = Int(pending[pending.startIndex]) << 24 | Int(pending[pending.startIndex + 1]) << 16
                            | Int(pending[pending.startIndex + 2]) << 8 | Int(pending[pending.startIndex + 3])
                        guard pending.count >= 8 + size else { break }
                        let type = UInt16(pending[pending.startIndex + 4]) << 8 | UInt16(pending[pending.startIndex + 5])
                        let payload = Data(pending[(pending.startIndex + 8)..<(pending.startIndex + 8 + size)])
                        pending = Data(pending[(pending.startIndex + 8 + size)...])
                        received.append(type)
                        if let answer = reply(type, payload) { write(answer) }
                    }
                    if !commands.isEmpty, Date().timeIntervalSince(start) > 0.5 {
                        commands.forEach(write)
                        commands = []
                    }
                    let count = recv(socket, &buffer, buffer.count, 0)
                    if count == 0 { break }
                    if count > 0 { pending.append(contentsOf: buffer[0..<count]) }
                }
                commands.forEach(write)
                return (head, received)
            }
            guard let result, !result.0.isEmpty else { throw ProviderError.network(tr("O PS5 não respondeu")) }
            return result
        }

        #if os(macOS)
        /// Asks the whole network and gathers the answers for a while, by address.
        static func broadcast(port: UInt16, _ message: Data, seconds: Double) async -> [String: Data] {
            await run {
                let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard socket >= 0 else { return [:] }
                defer { close(socket) }
                var yes: Int32 = 1
                setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
                setTimeout(socket, 0.3)
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = port.bigEndian
                target.sin_addr.s_addr = INADDR_BROADCAST
                guard sendTo(socket, message, target) else { return [:] }
                var found: [String: Data] = [:]
                let end = Date().addingTimeInterval(seconds)
                var buffer = [UInt8](repeating: 0, count: 2048)
                while Date() < end {
                    var from = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = withUnsafeMutablePointer(to: &from) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
                    }
                    guard count > 0 else { continue }
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
                    found[String(cString: text)] = Data(buffer[0..<count])
                }
                return found
            }
        }
        #endif
    }
}
