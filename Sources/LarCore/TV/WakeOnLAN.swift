import Foundation

/// The "magic packet" that wakes a sleeping network card: six 0xFF bytes and its MAC sixteen times, by UDP
/// broadcast. Works on many TVs on a cable; over Wi-Fi only on those that keep it on in standby.
public enum WakeOnLAN {
    static func packet(mac: String) -> [UInt8]? {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return [UInt8](repeating: 0xff, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
    }

    /// Sends it a few times, to the network's broadcast and to the TV's last address.
    public static func send(mac: String, host: String) {
        guard let packet = packet(mac: mac) else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var targets = ["255.255.255.255", host]
        let parts = host.split(separator: ".")
        if parts.count == 4 { targets.append(parts.prefix(3).joined(separator: ".") + ".255") }
        for _ in 0..<3 {
            for target in targets {
                for port: UInt16 in [9, 7] {
                    var address = sockaddr_in()
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = port.bigEndian
                    guard inet_pton(AF_INET, target, &address.sin_addr) == 1 else { continue }
                    packet.withUnsafeBytes { buffer in
                        withUnsafePointer(to: &address) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                _ = sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
        }
    }
}
