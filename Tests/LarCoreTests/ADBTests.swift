import Foundation
import Testing
@testable import LarCore

@Suite struct ADBTests {
    // A fixed odd 2048-bit number and its values, computed with Python (pow).
    static let nHex = "f59cde66bacfb3d00b1f9163ce9ff57f43b7a3a69a8dca03580d7b71d8f564135be6128e18c267976142ea7d17be31111a2a73ed562b0f79c37459eef50bea63371ecd7b27cd813047229389571aa8766c307511b2b9437a28df6ec4ce4a2bbdc241330b01a9e71fde8a774bcf36d58b4737819096da1dac72ff5d2a386ecbe06b65a6a48b8148f6b38a088ca65ed389b74d0fb132e706298fadc1a606cb0fb39a1de644815ef6d13b8faa1837f8a88b17fc695a07a0ca6e0822e8f36c031199972a846916419f828b9d2434e465e150bd9c66b3ad3c2d6d1a3d1fa7bc8960a923b8c1e9392456de3eb13b9046685257bdd640fb06671ad11c80317fa3b1799d"
    static let rrHex = "6ac9d3650c9f17c66fc8e83406c961e23d841209e21ee9056ec53b482859172d302186b5c2cd888e09880b5d1aca1dc4029a2bb008e7739f1053c923485105c57aa449801fa65235006abd7ebed330e3608705c3a03eb184dfadcac821df5297ed5b795e783d3e8b49c6a7d6b3572d93335a124e15d84c0927efd0251866a0795fefb0dbfc6d8f64d496dd0ee5dc8dbe686f9db8960c41033096dca77161e6135e6104d73b923fb5a5f0799f1dd3dfab5ebbbbece7f4ee6ff11fa128b4c46a33532d3d66ca0bc92483420cb7db06d34ef438f1ce2f7bc4da9bdcf837c3d8d8159ee989ed6ee6791b59b4b5918de9a966abd958b2dd612d5bbdb45c75d8aeab82"

    static func bytes(_ hex: String) -> [UInt8] {
        let padded = hex.count % 2 == 1 ? "0" + hex : hex
        return stride(from: 0, to: padded.count, by: 2).map {
            let start = padded.index(padded.startIndex, offsetBy: $0)
            return UInt8(padded[start..<padded.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    @Test func n0inv() {
        let n = BigWords(bigEndian: Self.bytes(Self.nHex), words: 64)
        #expect(ADBKey.n0inv(n.words[0]) == 2_946_771_787)
    }

    @Test func rSquared() {
        let n = BigWords(bigEndian: Self.bytes(Self.nHex), words: 64)
        #expect(ADBKey.rSquared(n) == BigWords(bigEndian: Self.bytes(Self.rrHex), words: 64))
    }

    @Test func realKeyMakesAValidBlob() throws {
        let key = try ADBKey.generate()
        let blob = try key.publicKeyBlob(name: "lar@mac")
        let text = String(decoding: blob, as: UTF8.self)
        #expect(text.hasSuffix(" lar@mac\0"))
        let base64 = String(text.split(separator: " ")[0])
        let raw = try #require(Data(base64Encoded: base64))
        #expect(raw.count == 524)
        #expect(raw.prefix(4) == Data([64, 0, 0, 0]))
        // Exponent 65537 at the end.
        #expect(raw.suffix(4) == Data([0x01, 0x00, 0x01, 0x00]))
        #expect(try key.sign(Data(repeating: 7, count: 20)).count == 256)
    }

    @Test func keyFileIsPrivateAndReloads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lar-test-\(UUID().uuidString)/adbkey")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = try ADBKey.generate()
        try ADBKey.save(key, to: file)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let again = try ADBKey(privateKeyData: Data(contentsOf: file))
        #expect(try again.publicKeyBlob(name: "x") == key.publicKeyBlob(name: "x"))
    }

    @Test func messageRoundTrip() throws {
        let data = ADBClient.encode(ADBClient.open, 5, 0, Data("shell:ls\0".utf8))
        let header = try #require(try ADBClient.decodeHeader(data))
        #expect(header.command == ADBClient.open)
        #expect(header.arg0 == 5)
        #expect(header.length == 9)
        #expect(data.count == 33)
    }

    @Test func corruptMagicIsRejected() {
        var data = ADBClient.encode(ADBClient.okay, 1, 2, nil)
        data[20] ^= 0xff
        #expect(throws: ADBError.self) { try ADBClient.decodeHeader(data) }
    }
}

@Suite struct AndroidTVTests {
    @Test func awakeWithAnApp() {
        let output = """
        name=TV do Quarto
        serial=ABC123
          mWakefulness=Awake
            mResumedActivity: ActivityRecord{83c15bd u0 com.crunchyroll.crunchyroid/.player.ui.PlayerActivity t11699}
        """
        let device = AndroidTVProvider.device(fromStatus: output, host: "192.168.1.50")
        #expect(device.name == "TV do Quarto")
        #expect(device.isOn == true)
        #expect(device.detail == "Crunchyroll")
        // Known by its serial, so a new address doesn't make it a new TV.
        #expect(device.id == "androidTV:ABC123")
        #expect(device.controls["host"] == "192.168.1.50")
    }

    @Test func asleepWithoutNameUsesTheAdvertisedOne() {
        let device = AndroidTVProvider.device(fromStatus: "name=null\nserial=X\n  mWakefulness=Asleep\n", host: "tv", fallbackName: "TV da Sala")
        #expect(device.name == "TV da Sala")
        #expect(device.isOn == false)
        #expect(device.detail == "Em repouso")
    }

    @Test func launcherAppsKnownFirstWithoutSystemOnes() {
        let output = """
        com.android.tv.settings/.MainSettings
        com.zebra.app/.Main
        com.netflix.ninja/.MainActivity
        com.netflix.ninja/.Other
        io.freemytv/.HomeActivity
        """
        let apps = AndroidTVProvider.apps(fromQuery: output)
        #expect(apps.map(\.name) == ["Netflix", "Zebra"])
    }

    @Test func macFromTheFirstCard() {
        let output = "name=TV\nserial=S\n  mWakefulness=Awake\n    link/ether 02:00:00:aa:bb:cc brd ff:ff:ff:ff:ff:ff\n"
        #expect(AndroidTVProvider.device(fromStatus: output, host: "h").controls["mac"] == "02:00:00:aa:bb:cc")
    }

    @Test func magicPacket() throws {
        let packet = try #require(WakeOnLAN.packet(mac: "02:00:00:aa:bb:cc"))
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xff })
        #expect(Array(packet[6..<12]) == [0x02, 0x00, 0x00, 0xaa, 0xbb, 0xcc])
        #expect(WakeOnLAN.packet(mac: "nope") == nil)
    }

    @Test func readableNamesForUnknownApps() {
        #expect(AndroidTVProvider.appName("tv.pluto.android") == "Pluto")
        #expect(AndroidTVProvider.appName("com.xcloud.app") == "XCloudTV")
    }

    /// A TV that's off the network: discovery finds nothing, the remembered TV shows offline under the same id.
    @Test func rememberedTVShowsOfflineWhenNotFound() async throws {
        let known = AndroidTVProvider.KnownTV(serial: "ABC123", name: "TV do Quarto", host: "192.168.1.40")
        let provider = AndroidTVProvider(known: [known], discover: { [] }, makeKey: { try ADBKey.generate() })
        let devices = try await provider.devices()
        #expect(devices.count == 1)
        #expect(devices.first?.id == "androidTV:ABC123")
        #expect(devices.first?.isOnline == false)
    }

    /// ADB refused but the Google TV remote port answers: the TV is on, offered for pairing, with no switch yet.
    @Test func tvWithoutADBIsOfferedForPairing() async throws {
        let provider = AndroidTVProvider(discover: { [TVDiscovery.Found(name: "TV da Sala", host: "127.0.0.1")] },
                                         makeKey: { try ADBKey.generate() }, probe: { _, port in port == 6466 })
        let device = try #require(try await provider.devices().first)
        #expect(device.isOnline)
        #expect(device.isOn == nil)
        #expect(!device.canSwitch)
        #expect(device.controls["pairable"] == "1")
        #expect(device.controls["pairingKey"] == "TV da Sala")
    }

    /// A paired TV that doesn't answer (in standby it leaves the network) is off, and switching it on can be tried.
    @Test func silentPairedTVCanStillBeSwitchedOn() async throws {
        let provider = AndroidTVProvider(discover: { [TVDiscovery.Found(name: "TV da Sala", host: "127.0.0.1")] },
                                         useADB: false, paired: ["TV da Sala"],
                                         makeIdentity: { throw TVRemoteError.connection("sem resposta") },
                                         probe: { _, _ in false })
        let device = try #require(try await provider.devices().first)
        #expect(!device.isOnline)
        #expect(device.isOn == false)
        #expect(device.canSwitch)
        #expect(device.detail == "Desligada ou fora da rede")
    }

    /// Without ADB (the iPhone), a TV that's advertised but silent is off, not pairable.
    @Test func silentTVWithoutADBIsOffline() async throws {
        let provider = AndroidTVProvider(discover: { [TVDiscovery.Found(name: "TV da Sala", host: "127.0.0.1")] },
                                         useADB: false, probe: { _, _ in false })
        let device = try #require(try await provider.devices().first)
        #expect(!device.isOnline)
        #expect(device.controls["pairable"] == nil)
        let answering = AndroidTVProvider(discover: { [TVDiscovery.Found(name: "TV da Sala", host: "127.0.0.1")] },
                                          useADB: false, probe: { _, _ in true })
        #expect(try await answering.devices().first?.controls["pairable"] == "1")
    }

    /// A discovered TV that doesn't answer still shows, offline, with the reason.
    @Test func unreachableDiscoveredTVSaysWhy() async throws {
        let provider = AndroidTVProvider(discover: { [TVDiscovery.Found(name: "TV da Sala", host: "127.0.0.1")] },
                                         makeKey: { try ADBKey.generate() })
        let devices = try await provider.devices()
        #expect(devices.map(\.name) == ["TV da Sala"])
        #expect(devices.first?.isOnline == false)
        #expect(devices.first?.detail.isEmpty == false)
    }
}
