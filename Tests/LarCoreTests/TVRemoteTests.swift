import Foundation
import Security
import Testing
@testable import LarCore

// MARK: - Google TV remote protocol

@Suite struct TVRemoteProtocolTests {
    @Test func framesRoundTrip() throws {
        let message = Data(repeating: 7, count: 300)
        let framed = TVRemoteProtocol.frame(message)
        #expect(framed.prefix(2) == Data([0xac, 0x02]))
        var buffer = framed + Data([1, 2])
        let (read, consumed) = try #require(try TVRemoteProtocol.unframe(buffer))
        #expect(read == message)
        buffer = Data(buffer.dropFirst(consumed))
        #expect(buffer == Data([1, 2]))
        #expect(try TVRemoteProtocol.unframe(framed.prefix(100)) == nil)
    }

    @Test func pairingRequestEncoding() throws {
        let message = try ProtoReader(TVRemoteProtocol.pairingRequest(clientName: "Lar"))
        #expect(message.int(1) == 2)
        #expect(message.int(2) == 200)
        let request = try #require(try message.message(10))
        #expect(request.string(1) == "atvremote")
        #expect(request.string(2) == "Lar")
    }

    @Test func configurationAskForHexCodeOfSix() throws {
        let message = try ProtoReader(TVRemoteProtocol.pairingConfiguration())
        let configuration = try #require(try message.message(30))
        let encoding = try #require(try configuration.message(1))
        #expect(encoding.int(1) == 3)
        #expect(encoding.int(2) == 6)
        #expect(configuration.int(2) == 1)
    }

    /// Vectors from the Python computation of androidtvremote2 (hashlib over the same numbers).
    @Test func pairingSecretMatchesReference() throws {
        let clientModulus = try #require(Data(hex: String(repeating: "C0FFEE", count: 20)))
        let serverModulus = try #require(Data(hex: String(repeating: "BADA55", count: 20)))
        let client = RSAPublicNumbers(modulus: clientModulus, exponent: Data([1, 0, 1]))
        let server = RSAPublicNumbers(modulus: serverModulus, exponent: Data([1, 0, 1]))
        #expect(TVRemoteProtocol.pairingSecret(code: "800000", client: client, server: server)?.first == 0x80)
        #expect(TVRemoteProtocol.pairingSecret(code: "0d1a2b", client: client, server: server)?.first == 0x0d)
        // The first two symbols check the rest: a typo is caught before the TV sees it.
        #expect(TVRemoteProtocol.pairingSecret(code: "810000", client: client, server: server) == nil)
        #expect(TVRemoteProtocol.pairingSecret(code: "80000", client: client, server: server) == nil)
        #expect(TVRemoteProtocol.pairingSecret(code: "80000G", client: client, server: server) == nil)
    }

    @Test func readsTheTVsMessages() throws {
        var ping = ProtoWriter()
        ping.message(8) { $0.varint(1, 42) }
        #expect(try TVRemoteProtocol.incoming(ping.data) == .ping(42))

        var start = ProtoWriter()
        start.message(40) { $0.varint(1, 1) }
        #expect(try TVRemoteProtocol.incoming(start.data) == .power(true))
        var standby = ProtoWriter()
        standby.message(40) { _ in }
        #expect(try TVRemoteProtocol.incoming(standby.data) == .power(false))

        var volume = ProtoWriter()
        volume.message(50) { v in
            v.string(3, "TV")
            v.varint(6, 100)
            v.varint(7, 15)
        }
        #expect(try TVRemoteProtocol.incoming(volume.data) == .volume(level: 15, max: 100, muted: false))

        var ime = ProtoWriter()
        ime.message(20) { $0.message(1) { $0.string(12, "com.netflix.ninja") } }
        #expect(try TVRemoteProtocol.incoming(ime.data) == .app("com.netflix.ninja"))

        var configure = ProtoWriter()
        configure.message(1) { $0.varint(1, 1) }
        #expect(try TVRemoteProtocol.incoming(configure.data) == .configure)
    }

    @Test func keyAndAnswers() throws {
        let key = try #require(try ProtoReader(TVRemoteProtocol.key(26)).message(10))
        #expect(key.int(1) == 26)
        #expect(key.int(2) == 3)
        #expect(try ProtoReader(TVRemoteProtocol.pingResponse(9)).message(9)?.int(1) == 9)
        #expect(try ProtoReader(TVRemoteProtocol.setActive()).message(2)?.int(1) == 622)
        let configure = try #require(try ProtoReader(TVRemoteProtocol.configure(model: "Lar")).message(1))
        #expect(configure.int(1) == 622)
        #expect(try configure.message(2)?.string(5) == "atvremote")
    }

    @Test func certificateIsReadableBySecurity() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let publicDER = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let tbs = TVRemoteIdentity.tbsCertificate(publicKeyPKCS1: publicDER, serial: Data([1, 2, 3]),
                                                  notBefore: Date(timeIntervalSince1970: 1_790_000_000), years: 20)
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?)
        let der = TVRemoteIdentity.certificate(tbs: tbs, signature: signature)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == TVRemoteIdentity.commonName)
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == publicDER)
        #expect(RSAPublicNumbers(pkcs1: publicDER)?.exponent == Data([1, 0, 1]))
    }

    @Test func appsWithoutADB() {
        let apps = AndroidTVProvider.commonApps(current: "com.stremio.one")
        #expect(apps.first?.name == "Stremio")
        #expect(apps.contains { $0.name == "Netflix" })
        #expect(AndroidTVProvider.commonApps(current: "io.freemytv").first?.name == "Netflix")
        #expect(AndroidTVProvider.link(forApp: "com.netflix.ninja") == "https://www.netflix.com/title")
        #expect(AndroidTVProvider.link(forApp: "com.stremio.one") == "market://launch?id=com.stremio.one")
    }
}

// MARK: - The watch's TVs, through the iPhone

@Suite struct TVRelayTests {
    /// A TV account that records what it was asked.
    actor FakeTV: TVRemoteProvider {
        nonisolated let provider = Provider.androidTV
        var devicesList: [HomeDevice]
        var log: [String] = []

        init(_ devices: [HomeDevice]) { devicesList = devices }

        func devices() async throws -> [HomeDevice] { log.append("devices"); return devicesList }
        func send(_ command: HomeCommand, to device: HomeDevice) async throws { log.append("\(command) \(device.rawID)") }
        func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws { log.append("key \(key.rawValue)") }
        func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] { [.init(package: "com.netflix.ninja", name: "Netflix")] }
        func openApp(_ package: String, on device: HomeDevice) async throws { log.append("open \(package)") }
        func type(_ text: String, on device: HomeDevice) async throws { log.append("type \(text)") }
    }

    static func tv(_ id: String, paired: Bool) -> HomeDevice {
        var device = HomeDevice(provider: .androidTV, rawID: id, name: id, kind: .tv, isOn: true)
        device.controls["pairable"] = "1"
        if paired { device.controls["link"] = "remote" }
        return device
    }

    /// The watch's provider talking straight to the iPhone's handler, as WatchConnectivity would carry it.
    @Test func watchControlsTheIPhonesTVs() async throws {
        let quarto = Self.tv("Quarto", paired: true), sala = Self.tv("Sala", paired: false)
        let phone = FakeTV([quarto, sala])
        let watch = RelayedTVProvider { data in
            let request = try JSONDecoder().decode(TVRelay.Request.self, from: data)
            return try JSONEncoder().encode(await TVRelay.handle(request, tv: phone, known: [quarto, sala]))
        }
        // Only what can be controlled from the wrist: the paired TV.
        #expect(try await watch.devices().map(\.rawID) == ["Quarto"])
        try await watch.send(.power(false), to: quarto)
        try await watch.press(.volumeUp, on: quarto)
        try await watch.openApp("com.netflix.ninja", on: quarto)
        try await watch.type("bluey", on: quarto)
        #expect(try await watch.apps(on: quarto).map(\.name) == ["Netflix"])
        #expect(await phone.log == ["devices", "power(false) Quarto", "key 24", "open com.netflix.ninja", "type bluey"])
    }

    @Test func errorsComeBackAsMessages() async throws {
        let none = RelayedTVProvider { data in
            let request = try JSONDecoder().decode(TVRelay.Request.self, from: data)
            return try JSONEncoder().encode(await TVRelay.handle(request, tv: nil, known: []))
        }
        await #expect(throws: ProviderError.api("Sem TVs no iPhone")) { try await none.devices() }
        let away = RelayedTVProvider { _ in throw CancellationError() }
        await #expect(throws: ProviderError.network("iPhone fora de alcance")) { try await away.devices() }
    }
}


@Suite struct TVTextTests {
    @Test func keyboardCountersAndText() throws {
        var batch = ProtoWriter()
        batch.message(21) { $0.varint(1, 7); $0.varint(2, 3) }
        #expect(try TVRemoteProtocol.incoming(batch.data) == .keyboard(imeCounter: 7, fieldCounter: 3))

        let edit = try #require(try ProtoReader(TVRemoteProtocol.text("ação", imeCounter: 7, fieldCounter: 3)).message(21))
        #expect(edit.int(1) == 7)
        #expect(edit.int(2) == 3)
        let field = try #require(try edit.message(3)?.message(2))
        #expect(field.string(3) == "ação")
        #expect(field.int(1) == 4)
        #expect(field.int(2) == 4)
    }

    @Test func adbTextIsQuoted() {
        #expect(AndroidTVProvider.shellText("bluey") == "'bluey'")
        #expect(AndroidTVProvider.shellText("o pato") == "'o%spato'")
        #expect(AndroidTVProvider.shellText("it's; rm") == "'it'\\''s;%srm'")
    }
}

@Suite struct FreeMyTVTests {
    @Test func exportIsPlainForTheTV() throws {
        let scene = HomeScene(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Dormir", symbol: "moon.fill", actions: [
            .init(deviceID: "lg:ac", deviceName: "Ar", command: .power(true)),
            .init(deviceID: "lg:ac", deviceName: "Ar", command: .temperature(24)),
            .init(deviceID: "tuya:l", deviceName: "Luz", command: .color(LightColor(hue: 0, saturation: 1))),
        ])
        let data = FreeMyTV.export(scenes: [scene], customizations: ["smartThings:t": DeviceCustomization(name: "TV", isFavorite: true, room: "Sala")],
                                   grouping: .room)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["grouping"] as? String == "room")
        let scenes = try #require(json["scenes"] as? [[String: Any]])
        #expect(scenes.first?["symbol"] as? String == "bedtime")
        let actions = try #require(scenes.first?["actions"] as? [[String: Any]])
        #expect(actions.count == 2)
        #expect(actions[1]["type"] as? String == "temperature")
        let devices = try #require(json["devices"] as? [String: [String: Any]])
        #expect(devices["smartThings:t"]?["room"] as? String == "Sala")
    }

    @Test func broadcastNeedsNoQuoting() {
        let args = FreeMyTV.notice(title: "Porteiro chamando", body: "Atenda; já!", doorbell: true)
        #expect(args.hasPrefix("--es kind doorbell -a io.freemytv.LAR -n io.freemytv/.LarReceiver"))
        #expect(!args.contains(";") && !args.contains("'") && !args.contains("á"))
    }
}
