import Foundation

/// Dreame's own cloud (the Dreamehome app), as the open dreame-vacuum integration documents it: OAuth with the
/// password (hashed with the app's salt; only the refresh token is kept), the robots from the account, and their
/// MIoT properties and actions through the cloud's command relay, each call signed. Unofficial: Dreame may change it.
/// Robots in the Mi Home app come through the Xiaomi account instead.
public actor DreameClient {
    static let servers = ["us", "eu", "sg", "cn", "ru", "in"]
    static let host = ".iot.dreame.tech:13267"
    static let salt = "RAylYC%fmSKp7%Tq"
    static let clientKey = "EETjszu*XI5znHsI"
    static let basic = "ZHJlYW1lX2FwcHYxOkFQXmR2QHpAU1FZVnhOODg="
    static let agent = "Dart/3.9 (dart:io)"
    static let appVersion = "102060300"

    struct Robot: Sendable, Equatable {
        var did: String
        var name: String
        var model: String
        var online: Bool
        /// The relay that reaches the robot ("10000.mt.us.iot.dreame.tech:19974").
        var bindDomain: String
    }

    /// Dreame's robots all share these MIoT numbers (their own spec).
    static let map = MIoTMap(
        kind: .vacuum, status: .init(siid: 2, piid: 1),
        statusNames: [1: "Sweeping", 2: "Idle", 3: "Paused", 4: "Error", 5: "Go Charging", 6: "Charging", 7: "Mopping",
                      8: "Drying", 9: "Washing", 10: "Go Washing", 11: "Building", 12: "Sweeping And Mopping",
                      13: "Charging Completed", 14: "Upgrading"],
        battery: .init(siid: 3, piid: 1), start: .init(siid: 2, aiid: 1), dock: .init(siid: 3, aiid: 1))

    private var account: BrandAccount
    private let save: @Sendable (BrandAccount) -> Void
    private let http: BrandHTTP
    private var commandID = Int.random(in: 1...100)

    public init(account: BrandAccount, save: @escaping @Sendable (BrandAccount) -> Void = { _ in },
                transport: @escaping HTTPTransport = defaultTransport) {
        self.account = account
        self.save = save
        self.http = BrandHTTP(transport: transport)
    }

    // MARK: Sign-in

    public static let signIn = BrandSignIn(
        provider: .dreame,
        hint: tr("Entre com a conta do app Dreamehome. Os robôs aparecem na lista para limpar, voltar à base e ver o estado e a bateria. Os Dreame que estão no Mi Home vêm pela conta Xiaomi."),
        needsPassword: true,
        appName: "Dreamehome"
    ) { email, password in
        let http = BrandHTTP(transport: defaultTransport)
        let visitor = BrandCrypto.randomHex(16)
        var lastError: Error = ProviderError.api(tr("E-mail ou senha errados"))
        var firstAccepted: BrandAccount?
        for server in servers {
            do {
                let body = "grant_type=password&scope=all&platform=ANDROID&type=account&username="
                    + (email.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? email)
                    + "&password=" + BrandCrypto.md5Hex(password + salt)
                var values = ["server": server, "visitor": visitor]
                let token = try await http.json("POST", "https://\(server)\(host)/dreame-auth/oauth/token",
                                                body: Data(body.utf8), headers: headers(email: email, values: values, form: true))
                guard let access = token.string("access_token") else { continue }
                values.merge(tokenValues(token)) { _, new in new }
                values["access"] = access
                let account = BrandAccount(email: email, values: values)
                // The robots live on the account's own server: the password works on others, which show none.
                if let robots = try? await DreameClient(account: account).robots(), !robots.isEmpty { return .done(account) }
                if firstAccepted == nil { firstAccepted = account }
            } catch ProviderError.unauthorized {
                continue
            } catch {
                lastError = error
            }
        }
        if let firstAccepted { return .done(firstAccepted) }
        throw lastError
    }

    static func tokenValues(_ token: [String: Any]) -> [String: String] {
        var values: [String: String] = [:]
        values["refresh"] = token.string("refresh_token")
        values["expires"] = String(Date().timeIntervalSince1970 + Double(token.int("expires_in") ?? 3600))
        values["tenant"] = token.string("tenant_id")
        values["region"] = token.string("region")
        values["lang"] = token.string("lang")
        values["country"] = token.string("country")
        return values.compactMapValues { $0 }
    }

    /// What every call carries: the app's identity, the tenant, the region (encrypted) and the token.
    static func headers(email: String, values: [String: String], form: Bool = false) -> [String: String] {
        var headers = [
            "User-Agent": agent,
            "dreame-meta": "cv=a_\(appVersion);canvasHash=\(BrandCrypto.md5Hex(email + "c").prefix(8));webglHash=\(BrandCrypto.md5Hex(email + "w").prefix(8));visitorIdHash=\(values["visitor"] ?? "")",
            "tenant-id": values["tenant"] ?? "000000",
            "authorization": "Basic " + basic,
            "Content-Type": form ? "application/x-www-form-urlencoded" : "application/json",
        ]
        if let region = values["region"], let lang = values["lang"], let country = values["country"],
           let sealed = try? BrandCrypto.aes(true, key: Data(clientKey.utf8), Data("\(region)|\(lang)|\(country)".utf8)) {
            headers["dreame-rlc"] = sealed.base64EncodedString()
        }
        if let access = values["access"] { headers["dreame-auth"] = access }
        return headers
    }

    // MARK: Robots

    func robots() async throws -> [Robot] {
        let response = try await request("dreame-user-iot/iotuserbind/device/listV2", params: nil)
        let records = response.dict("data")?.dict("page")?.list("records") ?? []
        return records.compactMap { item in
            guard let did = item.string("did"), let model = item.string("model"), model.contains("vacuum") else { return nil }
            let info = item.dict("deviceInfo")
            let name = item.string("customName").flatMap { $0.isEmpty ? nil : $0 } ?? info?.string("displayName") ?? model
            return Robot(did: did, name: name, model: model, online: item["online"] as? Bool ?? true,
                         bindDomain: item.string("bindDomain") ?? "")
        }
    }

    func read(_ robot: Robot) async throws -> [MIoTMap.Property: MIoTValue] {
        let params = Self.map.properties.map { ["did": robot.did, "siid": $0.siid, "piid": $0.piid] }
        let result = try await command("get_properties", params: params, on: robot)
        var out: [MIoTMap.Property: MIoTValue] = [:]
        for item in result as? [[String: Any]] ?? [] where item.int("code") ?? 0 == 0 {
            if let siid = item.int("siid"), let piid = item.int("piid"), let value = item["value"].flatMap(MIoTValue.init) {
                out[.init(siid: siid, piid: piid)] = value
            }
        }
        return out
    }

    func run(_ action: MIoTMap.Action, on robot: Robot) async throws {
        _ = try await command("action", params: ["did": robot.did, "siid": action.siid, "aiid": action.aiid, "in": [Any]()], on: robot)
    }

    private func command(_ method: String, params: Any, on robot: Robot) async throws -> Any? {
        commandID += 1
        let relay = robot.bindDomain.split(separator: ".").first.map { "-" + $0 } ?? ""
        let response = try await request("dreame-iot-com\(relay)/device/sendCommand", params: [
            "did": robot.did, "id": commandID,
            "data": ["did": robot.did, "id": commandID, "method": method, "params": params] as [String: Any],
        ])
        guard let data = response.dict("data"), let result = data["result"] else {
            throw ProviderError.api(response.string("msg") ?? tr("O robô não respondeu"))
        }
        return result
    }

    // MARK: Requests

    private func request(_ path: String, params: [String: Any]?) async throws -> [String: Any] {
        try await renewIfNeeded()
        guard let server = account["server"] else { throw ProviderError.unauthorized }
        let body: Data? = try params.map { try JSONSerialization.data(withJSONObject: Self.signed($0), options: [.sortedKeys]) }
        var response = try await http.json("POST", "https://\(server)\(Self.host)/\(path)", body: body ?? Data(),
                                           headers: Self.headers(email: account.email, values: account.values))
        if response.int("code") == 401 {
            try await renew()
            response = try await http.json("POST", "https://\(server)\(Self.host)/\(path)", body: body ?? Data(),
                                           headers: Self.headers(email: account.email, values: account.values))
        }
        if response.int("code") == 401 { throw ProviderError.unauthorized }
        return response
    }

    private func renewIfNeeded() async throws {
        let expires = account["expires"].flatMap(Double.init) ?? 0
        if Date().timeIntervalSince1970 > expires - 600 { try await renew() }
    }

    private func renew() async throws {
        guard let server = account["server"], let refresh = account["refresh"] else { throw ProviderError.unauthorized }
        let body = "grant_type=refresh_token&scope=all&platform=ANDROID&type=account&refresh_token=" + refresh
        var headers = Self.headers(email: account.email, values: account.values, form: true)
        headers["dreame-auth"] = nil
        let token = try await http.json("POST", "https://\(server)\(Self.host)/dreame-auth/oauth/token", body: Data(body.utf8), headers: headers)
        guard let access = token.string("access_token") else { throw ProviderError.unauthorized }
        account.values.merge(Self.tokenValues(token)) { _, new in new }
        account["access"] = access
        save(account)
    }

    /// The call's signature: its parameters spliced in Dreame's way, the time and the app's key, in MD5.
    static func signed(_ params: [String: Any], millis: Int = Int(Date().timeIntervalSince1970 * 1000)) -> [String: Any] {
        var out = params
        out["sign"] = BrandCrypto.md5Hex(spliced(params, top: true) + String(millis) + clientKey)
        out["timestamp"] = millis
        return out
    }

    static func spliced(_ object: [String: Any], top: Bool) -> String {
        var parts: [String] = []
        for key in object.keys.sorted() {
            let value = object[key]!
            if let nested = value as? [String: Any] {
                let inner = spliced(nested, top: false)
                parts.append(inner.isEmpty ? "\(key)=]" : "\(key)=[\(inner)]")
            } else if value is [Any] {
                // Lists only count at the top.
                if top, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
                    parts.append("\(key)=\(String(decoding: data, as: UTF8.self))")
                }
            } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                parts.append("\(key)=\(number.boolValue ? "true" : "false")")
            } else if value is NSNull {
                parts.append("\(key)=null")
            } else if top {
                parts.append("\(key)=\(value)")
            } else if let text = value as? String,
                      let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                parts.append("\(key)=\(String(decoding: data, as: UTF8.self))")
            } else {
                parts.append("\(key)=\(value)")
            }
        }
        return parts.joined(separator: "&")
    }
}

/// Dreamehome's robots in the list: on is cleaning, off is back to the dock.
public struct DreameProvider: DeviceProvider {
    public let provider = Provider.dreame
    let client: DreameClient

    public func devices() async throws -> [HomeDevice] {
        let robots = try await client.robots()
        return await withTaskGroup(of: HomeDevice.self) { group in
            for robot in robots {
                group.addTask {
                    let values = robot.online ? ((try? await client.read(robot)) ?? [:]) : [:]
                    return DreameClient.map.device(provider: .dreame, id: robot.did, name: robot.name, online: robot.online, values: values)
                }
            }
            var out: [HomeDevice] = []
            for await device in group { out.append(device) }
            return out.sorted { $0.name < $1.name }
        }
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command, let robot = try await client.robots().first(where: { $0.did == device.rawID }),
              let action = on ? DreameClient.map.start : DreameClient.map.dock else { throw ProviderError.unsupported }
        try await client.run(action, on: robot)
    }
}
