import Foundation
import Testing
@testable import LarCore

/// The robot and lock brands: their message formats and signatures, against values computed with Python and OpenSSL
/// (the same steps as the open libraries that document each brand).
@Suite struct RoborockTests {
    static let frame = "312e300001e2400000d43112345678006500603d355e798f12875baf9635940e0ea4ef4431020934f6426088a6989eca996356f05ac7f40eadeeb58e1a45961adcb1d5e84c8e1f2bef7866a2d5ed145546d1101a53bd931a12906f1bf12371d017f012d98ba86273f395580e9a73dff0d2598cf9b346a3"

    @Test func messageMatchesReference() throws {
        #expect(RoborockMessage.scrambledTimestamp(0x1234_5678) == "67482315")
        #expect(BrandCrypto.hex(RoborockMessage.key(timestamp: 0x1234_5678, localKey: "abcdefghijklmnop"))
                == "11baa9cd29a99dd6a1a07bd169da292c")
        var message = try RoborockMessage.request(id: 12345, method: "get_status", params: [Any](), timestamp: 0x1234_5678)
        message.sequence = 123_456
        message.random = 54321
        let encoded = try RoborockMessage.encode(message, localKey: "abcdefghijklmnop")
        #expect(BrandCrypto.hex(encoded) == Self.frame)

        let decoded = try #require(try RoborockMessage.decode(encoded, localKey: "abcdefghijklmnop").first)
        #expect(decoded.protocol == 101)
        #expect(String(decoding: decoded.payload, as: UTF8.self)
                == #"{"dps":{"101":"{\"id\":12345,\"method\":\"get_status\",\"params\":[]}"},"t":305419896}"#)
    }

    @Test func answersAreMatchedById() throws {
        let inner = #"{"id":777,"result":[{"state":8,"battery":97}]}"#
        let payload = try JSONSerialization.data(withJSONObject: ["dps": ["102": inner], "t": 1])
        let reply = RoborockMessage(sequence: 1, random: 2, timestamp: 1_700_000_000, protocol: 102, payload: payload)
        let decoded = try #require(try RoborockMessage.decode(try RoborockMessage.encode(reply, localKey: "k"), localKey: "k").first)
        #expect(decoded.responseID == 777)
        let first = try #require((decoded.responseResult as? [[String: Any]])?.first)
        #expect(first["state"] as? Int == 8)
        #expect(decoded.responseError == nil)
    }

    @Test func signaturesMatchReference() {
        let rriot = RoborockClient.Rriot(u: "user1", s: "sess1", h: "hmackey", k: "mqttkey", r: .init(a: "", m: ""))
        #expect(RoborockClient.mqttUser(rriot) == "45ecae99")
        #expect(String(BrandCrypto.md5Hex("sess1:mqttkey").dropFirst(16)) == "fd576b9bc4c9d0ec")
        #expect(RoborockClient.hawk(rriot, path: "/v3/user/homes/42", timestamp: 1_700_000_000, nonce: "abcDEF12")
                == #"Hawk id="user1",s="sess1",ts="1700000000",nonce="abcDEF12",mac="TPEmTt9x3VzoX7Qc9oWYYvBlHqD2Se1vKbPSr5WLGmw=""#)
    }

    @Test func robotsFromTheHomeData() {
        let home: [String: Any] = [
            "products": [["id": "p1", "model": "roborock.vacuum.a15", "category": "robot.vacuum.cleaner"],
                         ["id": "p2", "model": "roborock.wetdryvac.a56", "category": "roborock.wetdryvac"]],
            "devices": [["duid": "d1", "name": "S7", "localKey": "key1", "productId": "p1", "pv": "1.0", "online": true,
                         "deviceStatus": ["121": 8, "122": 100]],
                        ["duid": "d2", "name": "Dyad", "localKey": "key2", "productId": "p2", "pv": "A01"]],
            "receivedDevices": [["duid": "d3", "name": "Q7", "localKey": "key3", "pv": "B01", "online": false]],
        ]
        let robots = RoborockClient.robots(fromHome: home)
        #expect(robots.map(\.duid) == ["d1", "d3"])
        #expect(robots[0].state == 8 && robots[0].battery == 100)
        let device = RoborockProvider.device(robots[0], status: .init(state: 5, battery: 80))
        #expect(device.isOn == true)
        #expect(device.detail == "Limpando · bateria 80%")
        #expect(RoborockProvider.device(robots[1], status: nil).isOnline == false)
    }
}

@Suite struct MQTTTests {
    @Test func packetsRoundTrip() throws {
        let publish = MQTTPacket.publish("rr/m/o/a", Data([1, 2, 3]), qos: 1, id: 7)
        let (packet, consumed) = try #require(try MQTTPacket.unframe(publish + Data([0xff])))
        #expect(consumed == publish.count)
        let parsed = try #require(MQTTPacket.parsePublish(packet))
        #expect(parsed == .init(topic: "rr/m/o/a", payload: Data([1, 2, 3]), qos: 1, id: 7))

        // A long payload: a remaining length of two bytes.
        let big = MQTTPacket.publish("t", Data(repeating: 9, count: 300), qos: 0, id: 0)
        #expect(big[1] & 0x80 != 0)
        #expect(try MQTTPacket.unframe(big.prefix(100)) == nil)
        #expect(try MQTTPacket.parsePublish(#require(try MQTTPacket.unframe(big)).0)?.payload.count == 300)

        let connect = MQTTPacket.connect(.init(host: "h", port: 1, clientID: "c", username: "u", password: "p"))
        #expect(connect.first == 0x10)
        #expect(connect.contains(0xc2))
    }

    @Test func crcMatchesZlib() {
        #expect(BrandCrypto.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite struct XiaomiTests {
    @Test func signingMatchesReference() throws {
        let ssecurity = Data(0..<16).base64EncodedString()
        let nonce = XiaomiSigner.nonce(random: Data([1, 2, 3, 4, 5, 6, 7, 8]), millis: 1_700_000_000_000)
        #expect(nonce == "AQIDBAUGBwgBsFUV")
        #expect(try XiaomiSigner.signedNonce(nonce, ssecurity: ssecurity) == "5ep+rMHy/Bph+UDBR3Cb6aW2JDdKFCrVRtJBDO5BLUQ=")
        let fields = try XiaomiSigner.encryptedParams(path: "/home/device_list", nonce: nonce, ssecurity: ssecurity,
                                                      params: [("data", #"{"a":1}"#)])
        let values = Dictionary(fields, uniquingKeysWith: { first, _ in first })
        #expect(values["data"] == "J+nT+LPZJw==")
        #expect(values["rc4_hash__"] == "GuSAttu4DYsHDUjcvE3SFsIlvZb/HVniKNmJJQ==")
        #expect(values["signature"] == "QkoG29AXL9BQLK/w0owAJwfcl9Q=")
        #expect(values["_nonce"] == nonce)
        // The answer comes back in the same RC4.
        let signed = try XiaomiSigner.signedNonce(nonce, ssecurity: ssecurity)
        let reply = XiaomiSigner.rc4(signed, Data(#"{"code":0}"#.utf8)).base64EncodedString()
        #expect(String(decoding: try XiaomiSigner.decrypt(reply, nonce: nonce, ssecurity: ssecurity), as: UTF8.self) == #"{"code":0}"#)
    }

    @Test func robotMapFromTheSpec() throws {
        let spec: [String: Any] = ["services": [
            ["iid": 2, "type": "urn:miot-spec-v2:service:vacuum:00007810:xiaomi-c102gl:1",
             "properties": [["iid": 1, "type": "urn:miot-spec-v2:property:status:00000007:xiaomi-c102gl:1",
                             "value-list": [["value": 1, "description": "Sweeping"], ["value": 5, "description": "Go Charging"],
                                            ["value": 6, "description": "Charging"]]]],
             "actions": [["iid": 1, "type": "urn:miot-spec-v2:action:start-sweep:00002804:xiaomi-c102gl:1"]]],
            ["iid": 3, "type": "urn:miot-spec-v2:service:battery:00007805:xiaomi-c102gl:1",
             "properties": [["iid": 1, "type": "urn:miot-spec-v2:property:battery-level:00000014:xiaomi-c102gl:1"]],
             "actions": [["iid": 1, "type": "urn:miot-spec-v2:action:start-charge:00002802:xiaomi-c102gl:1"]]],
        ]]
        let map = try #require(MIoTMap.from(spec: spec))
        #expect(map.kind == .vacuum)
        #expect(map.start == .init(siid: 2, aiid: 1))
        #expect(map.dock == .init(siid: 3, aiid: 1))
        let cleaning = map.device(provider: .xiaomi, id: "1", name: "Robô", online: true,
                                  values: [.init(siid: 2, piid: 1): .int(1), .init(siid: 3, piid: 1): .int(64)])
        #expect(cleaning.isOn == true)
        #expect(cleaning.detail == "Limpando · bateria 64%")
        let going = map.device(provider: .xiaomi, id: "1", name: "Robô", online: true, values: [.init(siid: 2, piid: 1): .int(5)])
        #expect(going.isOn == false)
        #expect(going.detail == "Voltando à base")
    }
}

@Suite struct DreameTests {
    @Test func signingMatchesReference() throws {
        let params: [String: Any] = ["did": "123", "id": 7, "data": [
            "did": "123", "id": 7, "method": "get_properties", "params": [["did": "123", "siid": 2, "piid": 1]],
        ] as [String: Any]]
        #expect(DreameClient.spliced(params, top: true) == #"data=[did="123"&id=7&method="get_properties"]&did=123&id=7"#)
        let signed = DreameClient.signed(params, millis: 1_700_000_000_000)
        #expect(signed["sign"] as? String == "bae07f934df5891f3fff64c41384336c")
        #expect(signed["timestamp"] as? Int == 1_700_000_000_000)
        #expect(BrandCrypto.md5Hex("secret" + DreameClient.salt) == "ab51518dc498dcac64b000f288be8ea6")
        let headers = DreameClient.headers(email: "a@b.c", values: ["region": "us", "lang": "en", "country": "BR", "access": "tok"])
        #expect(headers["dreame-rlc"] == "7/Qr3HrKE4b+ZaxntEVgig==")
        #expect(headers["dreame-auth"] == "tok")
    }
}

@Suite struct EcovacsTests {
    @Test func signingMatchesReference() {
        var meta = EcovacsClient.meta
        meta["country"] = "br"
        meta["deviceId"] = "dev"
        let signed = EcovacsClient.sign(["account": "a@b.c", "password": "x", "requestId": "r", "authTimespan": "1", "authTimeZone": "GMT-8"],
                                        extra: meta, key: EcovacsClient.clientKey, secret: EcovacsClient.clientSecret)
        #expect(signed["authSign"] == "82792d557895519851f8b086b369f1fe")
        #expect(signed["authAppkey"] == EcovacsClient.clientKey)
    }

    @Test func publicKeyFromSPKI() throws {
        let spki = try #require(Data(base64Encoded: "MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBALaLFqnutKVlW9oydHBE0Dee2EVSSg4+XUUd8ZJJ96ysy77GHOHsIq1Xaa7lwQdh/1l+idMpSyuHmQfUYuxYDj0CAwEAAQ=="))
        let pkcs1 = try #require(EcovacsClient.rsaPublicKey(fromSPKI: spki))
        #expect(pkcs1.first == 0x30)
        #expect(pkcs1.count == 74)
    }

    @Test func stateOfTheRobot() {
        let robot = EcovacsClient.Robot(did: "d", name: "Deebot", deviceClass: "c", resource: "r", online: true)
        let cleaning = EcovacsProvider.device(robot, status: .init(state: "clean", charging: false, battery: 70))
        #expect(cleaning.isOn == true && cleaning.detail == "Limpando · bateria 70%")
        #expect(EcovacsProvider.device(robot, status: .init(state: "idle", charging: true, battery: 100)).detail == "Carregado · bateria 100%")
    }
}

@Suite struct YaleTests {
    @Test func lockFromDetail() {
        let lock = YaleClient.lock(id: "L1", name: "Porta", detail: [
            "LockStatus": ["status": "kAugLockState_Locked", "doorState": "kAugDoorState_Closed"], "battery": 0.82,
            "Bridge": ["status": ["current": "online"]],
        ])
        #expect(lock.locked == true && lock.doorOpen == false && lock.battery == 82 && lock.online)
        #expect(YaleProvider.device(lock).detail == "Trancada · Porta fechada · bateria 82%")
        let open = YaleClient.lock(id: "L1", name: "Porta", detail: ["LockStatus": ["status": "kAugLockState_Unlocked", "doorState": "kAugLockDoorState_Open"]])
        #expect(open.locked == false && open.doorOpen == true)
    }
}

@Suite struct IRobotTests {
    @Test func stateComesInPieces() {
        var status = IRobotClient.Status()
        IRobotClient.merge(Data(#"{"state":{"reported":{"batPct":91}}}"#.utf8), into: &status)
        IRobotClient.merge(Data(#"{"state":{"reported":{"cleanMissionStatus":{"phase":"run","cycle":"clean"}}}}"#.utf8), into: &status)
        #expect(status == .init(phase: "run", battery: 91))
        let robot = IRobotClient.Robot(blid: "B1", name: "Roomba", password: "p")
        let device = IRobotProvider.device(robot, status: status)
        #expect(device.isOn == true && device.detail == "Limpando · bateria 91%")
        #expect(IRobotProvider.device(robot, status: nil).isOnline == false)
    }
}

@Suite struct EufyTests {
    @Test func protocolBuffers() {
        #expect(EufyClient.control(start: true) == "BBoCCAE=")
        #expect(EufyClient.control(start: false) == "AggG")
        #expect(EufyClient.workState("BhAFMgIIAQ==") == "paused")
        #expect(EufyClient.workState("BhADGgIIAQ==") == "charged")
        #expect(EufyClient.workState("AhAF") == "cleaning")
    }

    @Test func robotsNewAndOld() {
        let novel = EufyClient.Robot(serial: "S1", name: "X10", model: "T2351", online: true, dps: ["153": "AhAF", "163": "77"])
        let device = EufyProvider.device(novel)
        #expect(device.isOn == true && device.detail == "Limpando · bateria 77%")
        let legacy = EufyClient.Robot(serial: "S2", name: "11S", model: "T2108", online: true, dps: ["15": "Recharge", "104": "40"])
        #expect(EufyProvider.device(legacy).detail == "Voltando à base · bateria 40%")
    }

    @Test func pkcs8KeyInside() throws {
        // PKCS#8 of a tiny "key": version 0, rsaEncryption, OCTET STRING { 30 03 02 01 05 }.
        let pkcs8 = Data([0x30, 0x16, 0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
                          0x05, 0x00, 0x04, 0x05, 0x30, 0x03, 0x02, 0x01, 0x05])
        #expect(ClientIdentity.pkcs8Inner(pkcs8) == Data([0x30, 0x03, 0x02, 0x01, 0x05]))
    }
}

@Suite struct PlayStationTests {
    @Test func codeComesFromTheRedirect() {
        let location = "com.scee.psxandroid.scecompcall://redirect/?code=v3.AbC123&cid=1234-abcd"
        #expect(PlayStationClient.code(fromRedirect: location) == "v3.AbC123")
        #expect(PlayStationClient.code(fromRedirect: "https://my.account.sony.com/central/signin/?error=login_required") == nil)
    }

    @Test func theSignInPageHandsTheCode() {
        let redirect = PlayStationClient.redirect
        #expect(BrandWebSignIn.code(in: URL(string: redirect + "/?code=v3.XyZ&cid=9")!, redirect: redirect) == "v3.XyZ")
        #expect(BrandWebSignIn.code(in: URL(string: "https://my.account.sony.com/central/signin/")!, redirect: redirect) == nil)
        #expect(PlayStationClient.authorizeURL.absoluteString.contains("client_id=09515159-7237-4370-9b40-3806e67c0891"))
    }

    @Test func consolesAreThePS5AndPS4() {
        let answer: [String: Any] = ["accountId": "1", "accountDevices": [
            ["deviceId": "a", "deviceType": "PS5"], ["deviceId": "b", "deviceType": "PSVita"], ["deviceId": "c", "deviceType": "PS4"],
        ]]
        #expect(PlayStationClient.consoles(answer) == [.init(id: "a", type: "PS5"), .init(id: "c", type: "PS4")])
    }

    @Test func presenceSaysTheGame() {
        let playing: [String: Any] = ["basicPresence": [
            "availability": "availableToPlay",
            "primaryPlatformInfo": ["onlineStatus": "online", "platform": "ps5"],
            "gameTitleInfoList": [["npTitleId": "PPSA01", "titleName": "Astro Bot", "format": "PS5"]],
        ]]
        #expect(PlayStationClient.presence(playing) == .init(online: true, platform: "PS5", game: "Astro Bot"))
        let away: [String: Any] = ["basicPresence": ["primaryPlatformInfo": ["onlineStatus": "offline", "platform": "PS5"]]]
        #expect(PlayStationClient.presence(away).online == false)
    }

    @Test func theConsoleInUseShowsTheGame() {
        let consoles: [PlayStationClient.Console] = [.init(id: "a", type: "PS5"), .init(id: "b", type: "PS4")]
        let devices = PlayStationProvider.devices(consoles, presence: .init(online: true, platform: "PS5", game: "Astro Bot"))
        #expect(devices.map(\.name) == ["PS5", "PS4"])
        #expect(devices[0].detail == "Astro Bot")
        #expect(devices[0].kind == .gameConsole)
        #expect(devices[1].controls["playing"] == "0")
    }
}

/// PS Remote Play's pairing, against values computed with Python and OpenSSL from chiaki-ng's description.
@Suite struct PlayStationRemotePlayTests {
    let ambassador = Data(0..<16)

    @Test func payloadMatchesTheReference() {
        let account = PlayStationRemotePlay.accountID("1234567890123456789")
        #expect(account == "FYHpffQQIhE=")
        let (body, crypt) = PlayStationRemotePlay.payload(ambassador: ambassador, pin: 12345678, accountID: account ?? "")
        #expect(BrandCrypto.hex(crypt.bright) == "d860e146bdb0bd94b460070bb1f3866d")
        #expect(BrandCrypto.hex(PlayStationRemotePlay.aeropause(ambassador, keyOffset: 8)) == "7b0a388cfad1da4345260d8aec78656c")
        #expect(body.count == 587)
        #expect(BrandCrypto.hex(BrandCrypto.sha256(body)) == "1de3fe744749973ca7c6cfa30a51c89f3f31a92f117d97cca510b9356d0756f3")
    }

    @Test func pairingReadsTheConsolesKey() throws {
        let (_, crypt) = PlayStationRemotePlay.payload(ambassador: ambassador, pin: 12345678, accountID: "FYHpffQQIhE=")
        let body = Data(hex: "348c3ab58e20bd908fee01d63eb7833afc94693ec137a67055f812752ef30587d2d899b80abe1d89ca245871cbb4c6e23687116791880d5a5d799b3a1e1088715ff65802d545fdc529f64dc1e951deeed129edb60e5b9d0fd7b5031ea5193f2bfb21c262f41811add101944718113b8747bc2eb242f63c2a9b9567330c22aa3e1abf2d37e31a2cc0")!
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let pairing = try PlayStationRemotePlay.pairing(host: "192.0.2.10", response: response, crypt: crypt)
        #expect(pairing.credential == String(UInt64(0x1a2b3c4d)))
        #expect(pairing.nickname == "PS5-123")
        #expect(pairing.registKey == "3161326233633464" && pairing.rpKey == "00112233445566778899aabbccddeeff" && pairing.canSleep)
        #expect(throws: ProviderError.self) {
            try PlayStationRemotePlay.pairing(host: "192.0.2.10", response: Data("HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 0x80108b09\r\n\r\n".utf8), crypt: crypt)
        }
    }

    @Test func sessionCipherMatchesTheReference() {
        let crypt = PlayStationRemotePlay.Crypt(nonce: Data(0x30..<0x40), morning: Data(0xa0..<0xb0))
        #expect(BrandCrypto.hex(crypt.ambassador) == "51142b5fe613c47400b9528a70692b6b")
        #expect(BrandCrypto.hex(crypt.bright) == "c1c955dfbf4c2b927f9e6bce3b0ca355")
        let request = String(decoding: PlayStationRemotePlay.controlRequest(host: "192.0.2.10", registKey: Data("31613262".utf8),
                                                                            crypt: crypt, deviceID: Data(count: 32)), as: UTF8.self)
        #expect(request.contains("RP-Auth: 9Dx6Dky8A/8rkwBhwXXXbw==\r\n"))
        #expect(request.contains("RP-OSType: E8WOsRvqED+C9Q==\r\n"))
        #expect(BrandCrypto.hex(PlayStationRemotePlay.message(.rest)) == "0000000000500000")
    }

    @Test func searchAnswersSayOnOrResting() {
        let on = Data("HTTP/1.1 200 Ok\nhost-id:ABC\nhost-type:PS5\nhost-name:PS5-123\nrunning-app-name:Astro Bot\n".utf8)
        #expect(PlayStationRemotePlay.state(on) == .on(name: "PS5-123", app: "Astro Bot"))
        #expect(PlayStationRemotePlay.state(Data("HTTP/1.1 620 Server Standby\nhost-name:PS5-123\n".utf8)) == .standby(name: "PS5-123"))
        let wake = String(decoding: PlayStationRemotePlay.wakeMessage(credential: "439041101"), as: UTF8.self)
        #expect(wake.hasPrefix("WAKEUP * HTTP/1.1\n") && wake.contains("user-credential:439041101\n"))
    }
}

/// The controller's stream: secp256k1 and the stream cipher, against Python's cryptography package.
@Suite struct PlayStationStreamTests {
    @Test func secp256k1MatchesTheReference() {
        let a = Secp256k1.keyPair(privateKey: Data(repeating: 0x11, count: 32))
        let b = Secp256k1.keyPair(privateKey: Data(repeating: 0x7e, count: 32))
        #expect(BrandCrypto.hex(a.publicKey) == "044f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa385b6b1b8ead809ca67454d9683fcf2ba03456d6fe2c4abe2b07f0fbdbb2f1c1")
        #expect(BrandCrypto.hex(Secp256k1.sharedSecret(a.privateKey, publicKey: b.publicKey) ?? Data()) == "b22edae719195d59cfbad13ba6009f56b522b0e1aaaf1c93aac45fa0525459d5")
        #expect(Secp256k1.sharedSecret(b.privateKey, publicKey: a.publicKey) == Secp256k1.sharedSecret(a.privateKey, publicKey: b.publicKey))
    }

    @Test func gkCryptMatchesTheReference() {
        let crypt = PlayStationRemotePlay.GKCrypt(index: 2, handshakeKey: Data(0x40..<0x50), secret: Data(0..<32))
        #expect(BrandCrypto.hex(crypt.keyBase) == "58fbc8450bcc45074ac4a1d5ce558d25")
        #expect(BrandCrypto.hex(crypt.iv) == "caff0b243cb8d729d3fc0d688ce8f1a2")
        #expect(BrandCrypto.hex(crypt.gmacBase) == "75f4b0a426ed24cae9500ad0f26f91f0")
        #expect(BrandCrypto.hex(crypt.crypt(Data(0..<28), at: 16)) == "20ef18ee7bbb6841a144ab7c19a51598daa72b478e10a8d8e09bea22")
        #expect(BrandCrypto.hex(crypt.gmac(Data(50..<90), at: 0x20)) == "c4b36ee6")
    }

    @Test func protobufRoundTrips() {
        let message = PlayStationRemotePlay.controllerConnection()
        #expect(PlayStationRemotePlay.messageType(message) == .controllerConnection)
        #expect(BrandCrypto.hex(message) == "0815b2010410011806")
        #expect(PlayStationRemotePlay.feedbackState().count == 28)
    }
}

@Suite struct PlayStationAccountTests {
    @Test func trophiesAndArtComeFromTheAccount() {
        let trophies = PlayStationClient.trophies(["trophyLevel": 312, "earnedTrophies": ["platinum": 4, "gold": 30, "silver": 90, "bronze": 400]])
        #expect(trophies == .init(level: 312, platinum: 4, gold: 30, silver: 90, bronze: 400))
        let presence = PlayStationClient.presence(["basicPresence": [
            "primaryPlatformInfo": ["onlineStatus": "online", "platform": "PS5"],
            "gameTitleInfoList": [["titleName": "Astro Bot", "npTitleIconUrl": "https://example.com/a.png"]],
        ]])
        #expect(presence.art == "https://example.com/a.png" && presence.game == "Astro Bot")
    }
}
