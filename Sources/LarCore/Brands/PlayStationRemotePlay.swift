import CommonCrypto
import Foundation

/// PS Remote Play's pairing and wake-up on the home network, as the open chiaki-ng documents it (rewritten in Swift,
/// PS5 only): the console's 8-digit code once, which gives a key; then the key wakes it from rest mode, and a search
/// says whether it's on or resting. Unofficial: Sony may change it.
public enum PlayStationRemotePlay {
    static let registPort: UInt16 = 9295
    static let discoveryPort: UInt16 = 9302
    static let protocolVersion = "00030010"
    /// The Remote Play app's client type, sent at pairing.
    static let clientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f"
    static let hmacKey = Data([0x46, 0x46, 0x87, 0xb3, 0x49, 0xca, 0x8c, 0xe8, 0x59, 0xc5, 0x27, 0x0f, 0x5d, 0x7a, 0x69, 0xd6])
    /// The PS5's key tables (16 rows of 32), from which the pairing's keys are picked.
    static let keys0 = Data(hex: [
        "24d8c2694c677871ee31bd2b83b21d61c9a78eed9ad36a6b5cc83579a724e21706602edff4db271055d9ea164e900cbf",
        "406f54a531702d5d1e27df3740ba9d5dffe1057080d4b7c2967f2f42eb5a08dec1b55215f6b5f2d969a5c7c47f4664a4",
        "fd4698a7e12a8e6faf654228b9c26f3ee3e44ee45b9d6010b85ab07d040c4c2478bdb8badb8fe3a0756d28c2335b3283",
        "dd51b0a58d0966e45cb8700be68214b6d2b0c2e055f384ad9d3af877f59d9aa97df1451b9b5525d8c1ff03a5480b1b19",
        "0cbde0cd48f32c9919d6b8bbd635436f71e3ef3e97b8e940a847e0e001169da7e5944b1dd280a27ff29810380db856c3",
        "7a4b4c85ec2f2389afd5ba9aadb0619c51b46d024926a43484203530230a4714321a960ee80f9696d4ba683a671574e0",
        "d6604c685073142f1159acc832d1db4c8a94753361d1d4fdaa6a6168d8ae314fb8077b270ff90bb0c264b372ea8b8740",
        "09b482b4ad76f936056089c820eba5f1510b27a7f0768496ebb12ec28528bc4834d4018d5b2554e0c44fa0fa998d6d7a",
        "64b1a95da4f9f522eb9af4a87a784b7fe28b0450437d262d1998386a4f2d30152e4fcdb9ce9e8d12c9fe338b84ce5b40",
        "e37f726d6c8a6a9e54f1e3645d6e7fac1ae7f7fa0022ed2b23fa58c5eb44925dccaa829f23fba6c9652ae07912652c34",
        "c52316c9cc0530f3960b90671aa7694c3e43249d4e68bd8b756e9d076f1a6aba"
    ].joined())!
    static let keys1 = Data(hex: [
        "794d7830fe10524ca8905b9a7e5fd3e113e0f10fa3e7bb457fdc8ed5f1045c7851eff8655903398437ae59df23b66034",
        "e64be2f54c13c6daf9fdb36584d645ec2c00f2eddccb936e6146e5d60194ee78850e685eb55bcdd36341fc81431c6f7c",
        "bae8bd8631d5707fb54a903e84e171e00299f471e702ed36afde56c290e0aec2f9af53c6d862163227fb6e9b48c6eaff",
        "6f780222982c1fbfb08ea939bcdf17ded70ee17a010ec387fcaae46b0f5b0af118198ae52c369b403099249448d747b2",
        "af6b8c409e4d6d3407c1262fbb14f7bc3652bd84fe4a9af48adb3489aaf10d940b92f41ce46c792d6ec0190ad5559414",
        "0513c26223b3d426c444567acd1cead474b936409f08fb4962059298ad1d9f8a768bd40f214076b61691459366cc12ea",
        "4df409e2ac33d06f4351073ed7952c1e1f0c24b30e3aef95f5eb77dd20f23598f2aea966e613ef5d3a2d66ede21ee932",
        "4a40bf37c67029d98ca1614a293dc7559c949ec911451028a727d1d3d08479c7a9b0f6af458c3cd4df3bf70da24f1397",
        "7827f048c0a5ab830105d012d71e123a4e9877aebab14eb53b59ca6da51180919c0769595a53707c9597116d668da3bd",
        "bb2db0bf9b10cbc70f5b7e67e2b04bba1012b9bc97fd48e48ac10fa1309d5620241a7d5ba0b4be9d384fb456a84d137c",
        "44e88497eb782c5285e4a2f6f3d9719eeeb81147fba91bc740c6e1196d50a12a"
    ].joined())!

    /// The session's tables (32 rows of the 16 bytes used), from which a session's keys are picked by its nonce.
    static let sessionKeysA = Data(hex: [
        "7fae83204739b65b239b5ca537c4df592ab3fdb232863ce71a96149db1d9907288ace4147723049e30ec3f27e7c2b176",
        "a1ee5deac0b968eea261b9b469120990ff23bb189356ff48d8d371a1c361308354056b8d42560401d80be7830a66b294",
        "5217285ce510c77703ba5189736a2868b16778794c6eb197b3b77f54a7025535e7566bc33cee8931d5f1235cec453c55",
        "331720a07617233f76acb4cc075a6222589615c9f8197ba007b301c8fce0b6f430b6688750069854512b2e5715011f85",
        "bafa39eccfe812883083a62ad208d5aefb2f1383ce0a24cb427aa6266d52d69babca48539e31055d5078e50d2d877c83",
        "3fbc19ae901bce021d75d3d16fd1c2f048f0b337054dbe6927da04c233a345b17171e0f3cc8ba618886d1e2f3c6b6989",
        "e6c5f900ca329f2087d7ea1518bbe024450ce7c21abcccff6d3f1557941ca22561a2b1ef31a8a9021aa289f8ecee97f6",
        "9d95f3c75dcb12082c49e1d5936752a39ee54462eeebbea49a953db3693fda9af3e20b7255138b971258f44a5236c642",
        "6c78c98b44bc858093ba6ce3d23995c65814c5a2d9ef2d9d97f7ec55f72e4c0fe8b8348645fcf461934a7f2c3febd1ce",
        "c3d21cc10e4a44f774ce00694399bdb77d2b99ce223b2dc96f4d38874520c5671113e6e7866892930a71a55b9501ae09",
        "17d5d72f9e5686d1989c24a28284adee07facfea1be76dc1f38a0b214e6647a4"
    ].joined())!
    static let sessionKeysB = Data(hex: [
        "e134171df517dae11be60c7335d46b42f4b69372ae46405d263098f8c7beb72ccf797090c57af3b13d590859e141ae65",
        "1d37b5a78b198a50502da9894e6e7dbf2989b61132db0d7558e29a1a1b08662a309b97be9f0c1e4eff3ae20615ba579d",
        "4942db524bbbd9638f6d9d3bd7e349bcdc76ac59e6e356811d29f96548c37050d488bf3a7e0022b28a80fef9751ad1cc",
        "19076062dc4b996495eaf6ccfc97e57febfcdaf3423a43b0d224fe04d131477755bc0a759082a2182f12263192eb4738",
        "6e45e09983807402e304e67a64c9088af0993426a2a5c815e9916fd7c1c7e6c55d2c6b55bb5b44d1f8369b81193a4718",
        "d7aef2b8b1c1b7d6e89f6a68317dbef39ff2e237410986523faca4984e426c8164316bfdf8017514acb5182fefd5424d",
        "2d392c1124220fac65bfd6daef8200fb622c8dd8b6776e1a2aa534daad7564886cb018cec8ed825d4d1843895706fdc2",
        "5c82232b437f55ecf8fb23ed49921dcf3b6aad42071a765eda5a23441d2dc9ec61f29b4fb412334d6a86e2f0d94d457a",
        "098a95edd9862af2c6fd722f3d189f7fab504885710d68559196a28751daf84cb045bd9f988d5a504765686fc308784c",
        "90c256a96203d1bd7754706a96cebde057cbf44d2c8fb82cae4e314deeb950317530ffb1fcef2e0508283d448a4a03e3",
        "546913d59b68125b4acfa2b9509fc0cc1bcd10d79229651e028d084e68d370f7"
    ].joined())!

    /// What pairing hands back: what's needed to wake the console and open a session, kept with the PlayStation
    /// account.
    public struct Pairing: Sendable, Equatable {
        public var host: String
        /// The wake-up's credential: the console's key read as a hex number.
        public var credential: String
        public var nickname: String?
        public var mac: String?
        /// The console's key as it sent it (hex) and the session key ("RP-Key"), for rest mode (nil from pairings
        /// made before them).
        public var registKey: String?
        public var rpKey: String?
        /// The console's login passcode for the account, when it has one (asked when a session opens).
        public var loginPIN: String?

        public init(host: String, credential: String, nickname: String? = nil, mac: String? = nil,
                    registKey: String? = nil, rpKey: String? = nil) {
            self.host = host
            self.credential = credential
            self.nickname = nickname
            self.mac = mac
            self.registKey = registKey
            self.rpKey = rpKey
        }

        /// Paired with what rest mode needs.
        public var canSleep: Bool { registKey != nil && rpKey != nil }

        /// The pairing as an account's values (kept with the PlayStation account, in the keychain).
        var values: [String: String?] {
            ["rp.host": host, "rp.credential": credential, "rp.nickname": nickname, "rp.mac": mac,
             "rp.registKey": registKey, "rp.rpKey": rpKey, "rp.loginPIN": loginPIN]
        }
    }

    public enum State: Sendable, Equatable {
        case on(name: String?, app: String?)
        case standby(name: String?)
    }

    // MARK: Crypto

    /// The pairing's cipher: AES-128-CFB with a key from the tables and the code, and an IV from the ambassador.
    struct Crypt {
        var bright: Data
        var ambassador: Data

        init(bright: Data, ambassador: Data) {
            self.bright = bright
            self.ambassador = ambassador
        }

        /// A session's cipher, from the console's nonce and the session key it gave at pairing.
        init(nonce: Data, morning: Data) {
            let rowA = Int(nonce[0] >> 3) * 16, rowB = Int(nonce[7] >> 3) * 16
            ambassador = Data((0..<16).map { i in (nonce[i] &- 0x2d &- UInt8(i)) ^ PlayStationRemotePlay.sessionKeysA[rowA + i] })
            bright = Data((0..<16).map { i in
                ((morning[i] &+ 0x18 &+ UInt8(i)) ^ nonce[i]) ^ PlayStationRemotePlay.sessionKeysB[rowB + i]
            })
        }

        init(ambassador: Data, pin: UInt32, keyOffset: Int) {
            var bright = Data((0..<16).map { PlayStationRemotePlay.keys0[$0 * 0x20 + keyOffset] })
            bright[12] ^= UInt8((pin >> 24) & 0xff)
            bright[13] ^= UInt8((pin >> 16) & 0xff)
            bright[14] ^= UInt8((pin >> 8) & 0xff)
            bright[15] ^= UInt8(pin & 0xff)
            self.bright = bright
            self.ambassador = ambassador
        }

        func iv(counter: UInt64) -> Data {
            var message = ambassador
            withUnsafeBytes(of: counter.bigEndian) { message.append(contentsOf: $0) }
            return BrandCrypto.hmacSHA256(key: PlayStationRemotePlay.hmacKey, message).prefix(16)
        }

        func crypt(_ data: Data, encrypt: Bool, counter: UInt64 = 0) -> Data {
            var cryptor: CCCryptorRef?
            let iv = iv(counter: counter)
            let status = bright.withUnsafeBytes { key in
                iv.withUnsafeBytes { vector in
                    CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES),
                                            CCPadding(ccNoPadding), vector.baseAddress, key.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
                }
            }
            guard status == kCCSuccess, let cryptor else { return Data() }
            defer { CCCryptorRelease(cryptor) }
            var out = Data(count: data.count)
            var moved = 0
            out.withUnsafeMutableBytes { output in
                data.withUnsafeBytes { input in
                    _ = CCCryptorUpdate(cryptor, input.baseAddress, data.count, output.baseAddress, output.count, &moved)
                }
            }
            return out
        }
    }

    /// The ambassador as the console reads it from the request: mixed with the second table.
    static func aeropause(_ ambassador: Data, keyOffset: Int) -> Data {
        Data((0..<16).map { i in (ambassador[i] ^ keys1[i * 0x20 + keyOffset]) &+ 0xd3 &+ UInt8(i) })
    }

    /// The PSN account id (a decimal number) as the console wants it: 8 bytes, little endian, in Base64.
    static func accountID(_ decimal: String) -> String? {
        guard let value = UInt64(decimal) else { return nil }
        return withUnsafeBytes(of: value.littleEndian) { Data($0) }.base64EncodedString()
    }

    /// The pairing request's body: filler with the ambassador hidden in it, then the account, encrypted.
    static func payload(ambassador: Data, pin: UInt32, accountID: String) -> (Data, Crypt) {
        var body = Data(repeating: 0x41, count: 0x1e0)
        let crypt = Crypt(ambassador: ambassador, pin: pin, keyOffset: Int(body[0x18d] & 0x1f))
        let aeropause = aeropause(ambassador, keyOffset: Int(body[0] >> 3))
        body.replaceSubrange(0xc7..<0xcf, with: aeropause[8..<16])
        body.replaceSubrange(0x191..<0x199, with: aeropause[0..<8])
        let inner = "Client-Type: \(clientType)\r\nNp-AccountId: \(accountID)\r\n"
        body.append(crypt.crypt(Data(inner.utf8), encrypt: true))
        return (body, crypt)
    }

    static func requestHead(length: Int) -> Data {
        Data(("POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\n"
              + "Connection: close\r\nContent-Length: \(length)\r\nRP-Version: 1.0\r\n\r\n").utf8)
    }

    /// "Key: value" lines.
    static func headers(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            out[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// The console's answer to pairing, decrypted: its key (read as the wake-up's credential), name and address.
    static func pairing(host: String, response: Data, crypt: Crypt) throws -> Pairing {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw ProviderError.api(tr("O PS5 respondeu de um jeito inesperado")) }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let status = head.components(separatedBy: "\r\n").first ?? ""
        guard status.contains(" 200") else {
            let reason = headers(head)["RP-Application-Reason"] ?? ""
            throw ProviderError.api(reason.isEmpty ? tr("O PS5 recusou o pareamento. Confira o código e tente de novo.")
                                                   : tr("O PS5 recusou o pareamento (\(reason)). Gere um código novo e tente de novo."))
        }
        let body = crypt.crypt(Data(response[split.upperBound...]), encrypt: false)
        let fields = headers(String(decoding: body, as: UTF8.self))
        // The key comes as hex of an ASCII hex number ("3161…" for "1a…"): that number is the credential.
        guard let hex = fields["PS5-RegistKey"], let ascii = Data(hex: hex).flatMap({ String(data: $0, encoding: .ascii) }),
              let number = UInt64(ascii.trimmingCharacters(in: CharacterSet(charactersIn: "\0")), radix: 16) else {
            throw ProviderError.api(tr("O PS5 não devolveu a chave"))
        }
        return Pairing(host: host, credential: String(number), nickname: fields["PS5-Nickname"], mac: fields["PS5-Mac"],
                       registKey: hex, rpKey: fields["RP-Key"])
    }

    static func searchMessage() -> Data { Data("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(protocolVersion)\n".utf8) }

    static func wakeMessage(credential: String) -> Data {
        Data(("WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\nuser-credential:\(credential)\n"
              + "device-discovery-protocol-version:\(protocolVersion)\n").utf8)
    }

    /// "HTTP/1.1 200 Ok" (on) or "620 Server Standby" (resting), with its name and the app in front.
    static func state(_ answer: Data) -> State? {
        let text = String(decoding: answer, as: UTF8.self)
        let fields = headers(text)
        if text.hasPrefix("HTTP/1.1 200") { return .on(name: fields["host-name"], app: fields["running-app-name"]) }
        if text.hasPrefix("HTTP/1.1 620") { return .standby(name: fields["host-name"]) }
        return nil
    }

    // MARK: Network

    /// Pairs with the console at `host` using the code shown on it (Configurações → Sistema → Reprodução remota →
    /// Vincular dispositivo).
    public static func pair(host: String, pin: String, accountID decimal: String) async throws -> Pairing {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 8, let code = UInt32(digits) else { throw ProviderError.api(tr("O código do PS5 tem 8 números.")) }
        guard let account = accountID(decimal) else { throw ProviderError.api(tr("Entre de novo na conta PlayStation.")) }
        // The console must be on and awake to pair: it answers this first.
        guard await LAN.udp(host: host, port: registPort, Data("SRC3\0".utf8), timeout: 3).map({ $0.starts(with: Data("RES3".utf8)) }) == true else {
            throw ProviderError.api(tr("O PS5 não respondeu em \(host). Ele precisa estar ligado (fora do repouso) e na mesma rede."))
        }
        try? await Task.sleep(for: .milliseconds(100))
        let ambassador = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let (body, crypt) = payload(ambassador: ambassador, pin: code, accountID: account)
        let response = try await LAN.tcp(host: host, port: registPort, requestHead(length: body.count) + body, timeout: 5)
        return try pairing(host: host, response: response, crypt: crypt)
    }

    /// Whether the console is on or resting (nil: no answer, unplugged or off the network).
    public static func state(host: String) async -> State? {
        guard let answer = await LAN.udp(host: host, port: discoveryPort, searchMessage(), timeout: 2) else { return nil }
        return state(answer)
    }

    /// Wakes the console from rest mode (it takes a few seconds to answer as on).
    public static func wake(_ pairing: Pairing) async throws {
        guard await LAN.send(host: pairing.host, port: discoveryPort, wakeMessage(credential: pairing.credential)) else {
            throw ProviderError.network(tr("Não deu para falar com o PS5 em \(pairing.host)"))
        }
    }

    // MARK: Session (rest mode)

    /// Commands on the session's control channel.
    public enum Command: UInt16, Sendable {
        case rest = 0x50
        case home = 0x14
    }

    static func sessionRequest(host: String, registKey: String) -> Data {
        Data(("GET /sie/ps5/rp/sess/init HTTP/1.1\r\nHost: \(host):\(registPort)\r\nUser-Agent: remoteplay Windows\r\n"
              + "Connection: close\r\nContent-Length: 0\r\nRP-Registkey: \(registKey)\r\nRp-Version: 1.0\r\n\r\n").utf8)
    }

    /// The session's nonce, from the console's answer to `sessionRequest`.
    static func nonce(_ response: Data) throws -> Data {
        let head = String(decoding: response, as: UTF8.self)
        let fields = headers(head)
        guard head.hasPrefix("HTTP/1.1 200"), let text = fields["RP-Nonce"], let nonce = Data(base64Encoded: text), nonce.count == 16 else {
            let reason = fields["RP-Application-Reason"].map { " (\($0))" } ?? ""
            throw ProviderError.api(tr("O PS5 recusou a sessão\(reason). Pareie de novo em Ajustes → Jogos."))
        }
        return nonce
    }

    /// The control channel's request: the console's key, a device id and the client, each encrypted in turn.
    static func controlRequest(host: String, registKey: Data, crypt: Crypt, deviceID: Data) -> Data {
        var counter: UInt64 = 0
        func field(_ value: Data) -> String {
            defer { counter += 1 }
            return crypt.crypt(value, encrypt: true, counter: counter).base64EncodedString()
        }
        var key = registKey.prefix(16)
        key.append(Data(count: 16 - key.count))
        let auth = field(key), did = field(deviceID), os = field(Data("Win10.0.0\0".utf8))
        let bitrate = field(Data(count: 4)), streaming = field(Data([1, 0, 0, 0]))
        return Data(("GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\nHost: \(host):\(registPort)\r\nUser-Agent: remoteplay Windows\r\n"
                     + "Connection: keep-alive\r\nContent-Length: 0\r\nRP-Auth: \(auth)\r\nRP-Version: 1.0\r\nRP-Did: \(did)\r\n"
                     + "RP-ControllerType: 3\r\nRP-ClientType: 11\r\nRP-OSType: \(os)\r\nRP-ConPath: 1\r\nRP-PadProcNo: 3\r\n"
                     + "RP-StartBitrate: \(bitrate)\r\nRP-StreamingType: \(streaming)\r\n\r\n").utf8)
    }

    static func deviceID() -> Data {
        Data([0x00, 0x18, 0x00, 0x00, 0x00, 0x07, 0x00, 0x40, 0x00, 0x80]) + Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            + Data(count: 6)
    }

    /// A command with no payload: its size (0) and type.
    static func message(_ command: Command) -> Data {
        Data([0, 0, 0, 0, UInt8(command.rawValue >> 8), UInt8(command.rawValue & 0xff), 0, 0])
    }

    /// The control channel's messages from the console.
    enum Incoming: UInt16 {
        case loginPINRequest = 0x4
        case login = 0x5
        case heartbeat = 0xfe
    }

    /// A message with a payload, encrypted with the session's next counter.
    static func message(type: UInt16, payload: Data, crypt: Crypt, counter: UInt64) -> Data {
        let size = UInt32(payload.count)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 0xff), UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
                     UInt8(type >> 8), UInt8(type & 0xff), 0, 0]) + crypt.crypt(payload, encrypt: true, counter: counter)
    }

    /// The counter of the messages sent with a payload (after the five of the request).
    final class Counter: @unchecked Sendable {
        var next: UInt64 = 5
    }

    /// Opens a Remote Play session (control channel only, no video) for `stay` seconds, which logs the paired account
    /// in on the console, sending `commands` (rest mode, home) and the console's login code when it asks.
    public static func session(_ pairing: Pairing, commands: [Command] = [], loginPIN: String? = nil, stay: Double = 1.5) async throws {
        guard let registHex = pairing.registKey, let registKey = Data(hex: registHex),
              let rpHex = pairing.rpKey, let morning = Data(hex: rpHex), morning.count == 16 else {
            throw ProviderError.api(tr("Pareie o PS5 de novo (Ajustes → Jogos) para usar o Modo de repouso."))
        }
        let nonce = try nonce(try await LAN.tcp(host: pairing.host, port: registPort, sessionRequest(host: pairing.host, registKey: registHex), timeout: 5))
        let crypt = Crypt(nonce: nonce, morning: morning)
        let request = controlRequest(host: pairing.host, registKey: registKey, crypt: crypt, deviceID: deviceID())
        let counter = Counter()
        let pin = loginPIN.map { Data($0.filter(\.isNumber).utf8) }
        let (head, received) = try await LAN.control(host: pairing.host, port: registPort, request, timeout: 5, stay: stay,
                                                     commands: commands.map(message)) { type, _ in
            switch Incoming(rawValue: type) {
            case .heartbeat: return message(type: 0x1fe, payload: Data(), crypt: crypt, counter: 0)
            case .loginPINRequest:
                guard let pin, !pin.isEmpty else { return nil }
                defer { counter.next += 1 }
                return message(type: 0x8004, payload: pin, crypt: crypt, counter: counter.next)
            default: return nil
            }
        }
        guard head.starts(with: Data("HTTP/1.1 200".utf8)) else {
            let reason = headers(String(decoding: head, as: UTF8.self))["RP-Application-Reason"].map { " (\($0))" } ?? ""
            throw ProviderError.api(tr("O PS5 recusou o comando\(reason). Ele pode estar com outra sessão de Remote Play aberta."))
        }
        if received.contains(Incoming.loginPINRequest.rawValue), pin == nil {
            throw ProviderError.api(tr("O PS5 pediu a senha de acesso da conta. Informe-a em Ajustes → Jogos → PlayStation."))
        }
    }

    public static func send(_ command: Command, to pairing: Pairing) async throws {
        try await session(pairing, commands: [command], loginPIN: pairing.loginPIN)
    }

    /// Wakes the console and, once it answers as on, opens a session so it enters the paired account (instead of
    /// stopping at the user choice).
    public static func wakeAndSignIn(_ pairing: Pairing) async throws {
        try await wake(pairing)
        guard pairing.canSleep else { return }
        // In the background: the console takes a while to wake, and the list shouldn't wait for it.
        Task.detached { await signIn(pairing) }
    }

    static func signIn(_ pairing: Pairing) async {
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1.5))
            if case .on? = await state(host: pairing.host) {
                try? await Task.sleep(for: .seconds(2))
                try? await session(pairing, loginPIN: pairing.loginPIN, stay: 4)
                return
            }
        }
    }

    #if os(macOS)
    /// The consoles answering the search on the network, by address (the Mac only: the iPhone needs a permission
    /// from Apple for broadcasts, so it's given the address instead).
    public static func discover() async -> [String: State] {
        await LAN.broadcast(port: discoveryPort, searchMessage(), seconds: 2).compactMapValues(state)
    }
    #endif
}
