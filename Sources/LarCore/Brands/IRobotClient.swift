import Foundation
import Network

/// iRobot's Roombas: the account's sign-in (iRobot's Gigya login, as the open Roomba980-Python documents it) gives
/// each robot's local password once; from then on the robot itself answers on the home network (MQTT over TLS with a
/// self-signed certificate), found by its name there. A Roomba takes one local connection at a time, so each read or
/// command opens one and closes it. Unofficial: iRobot may change it.
public actor IRobotClient {
    static let discovery = "https://disc-prod.iot.irobotapi.com/v1/discover/endpoints?country_code=US"
    static let appID = "ANDROID-C7FB240E-DF34-42D7-AE4E-A8C17079A294"

    struct Robot: Codable, Sendable, Equatable {
        var blid: String
        var name: String
        var password: String
        var sku: String?
    }

    struct Status: Sendable, Equatable {
        var phase: String?
        var battery: Int?
    }

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in }) {
        self.account = account
        self.save = save
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .irobot,
        hint: tr("Entre com a conta do app iRobot Home. Os Roombas aparecem na lista para limpar, voltar à base e ver o estado e a bateria, sempre que o aparelho estiver na mesma rede que eles."),
        needsPassword: true,
        appName: "iRobot Home"
    ) { email, password in
        let http = BrandHTTP(transport: defaultTransport)
        let endpoints = try await http.json("GET", discovery)
        let deployments = endpoints.dict("deployments") ?? [:]
        let current = endpoints.string("current_deployment").flatMap { deployments.dict($0) } ?? deployments.values.first as? [String: Any]
        guard let httpBase = current?.string("httpBase"), let gigya = endpoints.dict("gigya"),
              let apiKey = gigya.string("api_key"), let domain = gigya.string("datacenter_domain") else {
            throw ProviderError.api(tr("Resposta inesperada da iRobot"))
        }
        let login = try await http.json("POST", "https://accounts.\(domain)/accounts.login", form: [
            "apiKey": apiKey, "targetenv": "mobile", "targetEnv": "mobile", "loginID": email, "password": password, "format": "json",
        ])
        guard let uid = login.string("UID"), let signature = login.string("UIDSignature"),
              let timestamp = login.string("signatureTimestamp") else {
            throw ProviderError.api(login.string("errorDetails") ?? tr("E-mail ou senha errados"))
        }
        let session = try await http.json("POST", httpBase + "/v2/login", body: [
            "app_id": appID, "assume_robot_ownership": "0", "gigya": ["signature": signature, "timestamp": timestamp, "uid": uid],
        ])
        let robots = (session.dict("robots") ?? [:]).compactMap { blid, value -> Robot? in
            guard let info = value as? [String: Any], let password = info.string("password") else { return nil }
            return Robot(blid: blid, name: info.string("name") ?? "Roomba", password: password, sku: info.string("sku"))
        }
        guard !robots.isEmpty else { throw ProviderError.api(tr("Nenhum Roomba nessa conta")) }
        var account = BrandAccount(email: email)
        account.encode(robots.sorted { $0.name < $1.name }, "robots")
        return .done(account)
    }

    // MARK: Robots

    var robots: [Robot] { account.decoded([Robot].self, "robots") ?? [] }

    /// The robot's address on the home network: the one seen last, or its name there.
    private func host(of robot: Robot) async -> String? {
        var candidates = [account["host-\(robot.blid)"]].compactMap { $0 }
        candidates += ["iRobot-\(robot.blid).local", "Roomba-\(robot.blid).local"]
        #if os(macOS)
        if let found = await Self.broadcast()[robot.blid] { candidates.insert(found, at: 0) }
        #endif
        for candidate in candidates where await Self.reachable(candidate) {
            if account["host-\(robot.blid)"] != candidate {
                account["host-\(robot.blid)"] = candidate
                save(account)
            }
            return candidate
        }
        return nil
    }

    private func session(_ robot: Robot) async throws -> MQTTClient {
        guard let host = await host(of: robot) else {
            throw ProviderError.network(tr("O Roomba não foi encontrado na rede (este aparelho está em casa?)"))
        }
        return MQTTClient(.init(host: host, port: 8883, clientID: robot.blid, username: robot.blid,
                                password: robot.password, keepAlive: 30, acceptAnyCertificate: true))
    }

    func status(of robot: Robot) async throws -> Status {
        let client = try await session(robot)
        defer { Task { await client.close() } }
        try await client.subscribe(["#"])
        var status = Status()
        // The robot sends its state in pieces right after connecting.
        let deadline = ContinuousClock.now + .seconds(6)
        while (status.phase == nil || status.battery == nil), ContinuousClock.now < deadline {
            guard let message = try? await client.next(timeout: deadline - ContinuousClock.now, match: { _ in true }) else { break }
            Self.merge(message.payload, into: &status)
        }
        guard status.phase != nil || status.battery != nil else { throw ProviderError.network(tr("O Roomba não respondeu")) }
        return status
    }

    static func merge(_ payload: Data, into status: inout Status) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reported = object.dict("state")?.dict("reported") else { return }
        if let phase = reported.dict("cleanMissionStatus")?.string("phase") { status.phase = phase }
        if let battery = reported.int("batPct") { status.battery = battery }
    }

    /// start, stop, pause, resume or dock.
    func command(_ name: String, on robot: Robot) async throws {
        let client = try await session(robot)
        defer { Task { await client.close() } }
        let payload = try JSONSerialization.data(withJSONObject: [
            "command": name, "time": Int(Date().timeIntervalSince1970), "initiator": "localApp",
        ])
        try await client.publish("cmd", payload)
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func phaseText(_ phase: String?) -> String {
        switch phase {
        case "run": tr("Limpando")
        case "charge": tr("Carregando")
        case "hmUsrDock", "hmMidMsn", "hmPostMsn": tr("Voltando à base")
        case "stuck": tr("Com problema")
        case "evac": tr("Esvaziando o reservatório")
        case "pause": tr("Pausado")
        default: tr("Parado")
        }
    }

    // MARK: Finding it on the network

    private static func reachable(_ host: String) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 8883, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .waiting, .cancelled: once.run { connection.cancel(); continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.run { connection.cancel(); continuation.resume(returning: false) } }
        }
    }

    #if os(macOS)
    /// The Roombas' answers to iRobot's discovery broadcast ("irobotmcs" on UDP 5678), by BLID. On the Mac only: the
    /// iPhone needs a permission from Apple for broadcasts, and finds them by name instead.
    static func broadcast() async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard socket >= 0 else { return continuation.resume(returning: [:]) }
                defer { close(socket) }
                var yes: Int32 = 1
                setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(5678).bigEndian
                address.sin_addr.s_addr = INADDR_BROADCAST
                let message = Array("irobotmcs".utf8)
                _ = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                var found: [String: String] = [:]
                let end = Date().addingTimeInterval(2)
                var buffer = [UInt8](repeating: 0, count: 2048)
                while Date() < end {
                    let count = recv(socket, &buffer, buffer.count, 0)
                    guard count > 0, let object = try? JSONSerialization.jsonObject(with: Data(buffer[0..<count])) as? [String: Any],
                          let hostname = object.string("hostname"), let ip = object.string("ip") else { continue }
                    if let blid = hostname.split(separator: "-", maxSplits: 1).last { found[String(blid)] = ip }
                }
                continuation.resume(returning: found)
            }
        }
    }
    #endif
}

/// The Roombas in the list: on is cleaning, off is back to the dock.
public struct IRobotProvider: DeviceProvider {
    public let provider = Provider.irobot
    let client: IRobotClient

    public func devices() async throws -> [HomeDevice] {
        let robots = await client.robots
        return await withTaskGroup(of: HomeDevice.self) { group in
            for robot in robots {
                group.addTask {
                    let status = try? await client.status(of: robot)
                    return Self.device(robot, status: status)
                }
            }
            var out: [HomeDevice] = []
            for await device in group { out.append(device) }
            return out.sorted { $0.name < $1.name }
        }
    }

    static func device(_ robot: IRobotClient.Robot, status: IRobotClient.Status?) -> HomeDevice {
        guard let status else {
            return HomeDevice(provider: .irobot, rawID: robot.blid, name: robot.name, kind: .vacuum, isOnline: false,
                              detail: tr("Fora da rede deste aparelho"))
        }
        var parts = [IRobotClient.phaseText(status.phase)]
        if let battery = status.battery { parts.append(tr("bateria \(battery)%")) }
        return HomeDevice(provider: .irobot, rawID: robot.blid, name: robot.name, kind: .vacuum,
                          isOn: status.phase == "run", detail: parts.joined(separator: " · "))
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command, let robot = await client.robots.first(where: { $0.blid == device.rawID }) else {
            throw ProviderError.unsupported
        }
        if on {
            try await client.command("start", on: robot)
        } else {
            // A cleaning robot stops first, then goes home.
            try? await client.command("stop", on: robot)
            try await client.command("dock", on: robot)
        }
    }
}
