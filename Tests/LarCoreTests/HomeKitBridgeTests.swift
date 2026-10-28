import CryptoKit
import Foundation
import Testing
@testable import LarCore

@Suite struct HomeKitBridgeTests {
    static func data(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    // The client's side and the expected values, computed with Python (pow, hashlib).
    static let b = "980432e7d7d3dedc5a88ecc9cfba88491bdcaed329c9bae5a7b8b769bd6b3cf2de04411c63f2219d6e3810ad22782c2daf1bc0e52016fec59a240176386b094b0b640d687f33a2b2c7b4641622a7fdaca7ba2a0e3e1a4d5fc78931206b5e7aa69274088a9f58abb695631870e462ed7d7e0d8dde3366b9ac86d5f5884de5b41725f4e21ea7b9f9253f4681a7d4503d69b599d05e9ac65f0b507d5175bf9c14f0406f006cd9c1e561d0919681e939901ff435773e72b9181faf743d51bc68dd477341269cc4c073c0e096eef74997135e6a107a4f22bbea4ce85f966511b76ef2634c9ce68a86aa78edd8bfe9f4411f889f84ff5a492a1396bbaf66157c394ef350e7deacb802693576934ff6222418871b08c4396856d27b6ef89ec2f16d528949fd4be0b1cffc842512a9fe4729c67a9ccb433ab04476b753a618adea64b32684ffda198b43a2bf5fa4579eb71e0f2cc39169ca791551676284ad03b85f5ba9f15b70ccfaa75d4abe6b9863fd18ef7996fe4744f927fe04fe52297d7c6ad8f4"
    static let a = "dbdf6cbeb0f973827860aa0b05c83a216f7dc09d433d4adbc69db3c2514f370e23b1bbb332e20e0cfb02585cc5f18fcaa7fe62bf275711c321b64af075b740a7c99fefd2c5009e555cda19f02efafa1efa6569b324ac7c8d75f7e0070859087020ee96518fa059a0429c7837dd10feae106d476c27aa1bfb0d8cdad21746974e951fd976cb262998152ca2564d585aac31d88b7b32d0873e49f0e539df9511f44a57e3dad6db3661ae5e1082eb6aa45806ccd8960b9076db1cb259cdc919fb1e18b40ce89d002fdf602de5b617cf34b0ad5a166f59b470423bd3b4b96c23b3875f635e3292666927b67cb1dfeacacac11483953762c4e8dbb93ea21a69f565d7b8b3788b70c1173bfa1c862798547528668ea56aec44f44388c94219fe2b101e713155fcb03394edb67d1bee78758a21a86628fdf100bf61de453149266c3a1482df3fbcd660dd926ae83eb26f1002e3d8251f88d7466e3da482b0f080a189898a61f8efa5e889fbc902981b647f81c60dbedc73b34e0b75fde6669dae16ca83"
    static let m1 = "a744cf9d4e92712eaacfdf9cc2c748475667cd744ee798027a4e7a0b01e36dca2d35799a879ee13426df8e509f4e8dbe510ff5cee8532fb5daf84f67458a3454"
    static let m2 = "f8ca2f19fd9c7ed3a3b4200f5943f1588ea4bc0bcf95424bdca4218184cf35538c00b38d8b9fa74459d10d42fb5a8dabcf394828a88435e1555ce2db84121912"
    static let k = "20c369dc01cdb3117a9aa0115cb12a9e0d2bb653bb5740c2b24b2e64fb7fd3fc87b1b321b3933d85024f782912f6845a9618cd405cb4c7b7cde8d8fb81ed6e12"

    @Test func srpMatchesTheReference() throws {
        let server = HAPSRPServer(code: "123-45-678", salt: Data(0..<16), secret: Data(100..<132))
        #expect(server.publicKey == Self.data(Self.b))
        let result = try #require(server.verify(clientKey: Self.data(Self.a), proof: Self.data(Self.m1)))
        #expect(result.proof == Self.data(Self.m2))
        #expect(result.key == Self.data(Self.k))
        #expect(server.verify(clientKey: Self.data(Self.a), proof: Data(count: 64)) == nil)
        let wrongCode = HAPSRPServer(code: "123-45-679", salt: Data(0..<16), secret: Data(100..<132))
        #expect(wrongCode.verify(clientKey: Self.data(Self.a), proof: Self.data(Self.m1)) == nil)
    }

    @Test func tlvSplitsAndJoinsLongValues() {
        let long = Data((0..<600).map { UInt8($0 % 256) })
        let tlv = HAPTLV([(.state, Data([2])), (.publicKey, long), (.identifier, Data("a".utf8))])
        let decoded = HAPTLV(decoding: tlv.encoded)
        #expect(decoded[.publicKey] == long)
        #expect(decoded.byte(.state) == 2)
        #expect(decoded[.identifier] == Data("a".utf8))
    }

    @Test func setupURIEncodesCodeAndCategory() {
        var identity = HAPIdentity.make()
        identity.setupCode = "518-08-582"
        identity.setupID = "1QJ8"
        // HAP-NodeJS's encoding for this code, a bridge (category 2) on IP.
        let payload = UInt64(51808582) | (1 << 28) | (2 << 31)
        let encoded = String(payload, radix: 36).uppercased()
        #expect(identity.setupURI() == "X-HM://" + String(repeating: "0", count: 9 - encoded.count) + encoded + "1QJ8")
        #expect(identity.setupURI().count == 7 + 9 + 4)
    }

    @Test func codesAreWellFormed() {
        for _ in 0..<50 {
            let code = HAPIdentity.makeCode()
            #expect(code.count == 10)
            #expect(code.filter(\.isNumber).count == 8)
        }
    }

    @Test func rolesAndWrites() {
        let light = HomeDevice(provider: .tuya, rawID: "1", name: "Sala", kind: .light, isOn: false, brightness: 0.5,
                               color: LightColor(hue: 10, saturation: 0.5))
        let role = HAPRole(light)
        #expect(role == .light(dims: true, color: true))
        #expect(HAPAccessories.value(10, of: light, role: role!) as? Int == 50)
        var color: LightColor?
        let command = HAPAccessories.command(9, value: NSNumber(value: true), device: light, role: role!, color: &color)
        #expect(command == .some(.power(true)))
        _ = HAPAccessories.command(11, value: NSNumber(value: 200), device: light, role: role!, color: &color)
        #expect(color == LightColor(hue: 200, saturation: 0.5))
        let ac = HomeDevice(provider: .lg, rawID: "2", name: "Quarto", kind: .airConditioner, isOn: true,
                            controls: ["targetTemperature": "22"])
        #expect(HAPRole(ac) == .thermostat)
        #expect(HAPAccessories.command(12, value: NSNumber(value: 23.4), device: ac, role: .thermostat, color: &color)
            == .some(.temperature(23.5)))
        // Cameras with live video go to the Home app (from the Mac); one off the network doesn't.
        #expect(HAPRole(HomeDevice(provider: .tuya, rawID: "3", name: "Cam", kind: .camera, isOn: true)) == .camera)
        #expect(HAPRole(HomeDevice(provider: .tuya, rawID: "4", name: "Cam", kind: .camera, isOnline: false)) == nil)
        #expect(HAPAccessories.cleanName("  Luz da sala 💡 ") == "Luz da sala")
    }

    @Test func httpRequestsParseOneAtATime() throws {
        var buffer = Data("PUT /characteristics HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}GET /characteristics?id=1.9,2.10 HTTP/1.1\r\n\r\n".utf8)
        let first = try #require(HTTPRequest.parse(&buffer))
        #expect(first.method == "PUT")
        #expect(first.body == Data("{}".utf8))
        let second = try #require(HTTPRequest.parse(&buffer))
        #expect(second.query["id"] == "1.9,2.10")
        #expect(HTTPRequest.parse(&buffer) == nil)
    }
}

@Suite struct HomeAppDuplicatesTests {
    @Test func matchesByNameAndKindFamily() {
        let devices = [
            HomeDevice(provider: .tuya, rawID: "1", name: "Luz da Sala", kind: .light, isOn: true),
            HomeDevice(provider: .homeKit, rawID: "A", name: "luz da sala", kind: .plug, isOn: true),
            HomeDevice(provider: .lg, rawID: "2", name: "Ar Quarto", kind: .airConditioner, isOn: false),
            HomeDevice(provider: .homeKit, rawID: "B", name: "Ar Quarto", kind: .light, isOn: false),
            HomeDevice(provider: .homeKit, rawID: "C", name: "Abajur", kind: .light, isOn: false),
        ]
        let matches = HomeAppDuplicates.matches(in: devices, names: ["lg:2": "Ar do Quarto"])
        #expect(matches == ["homeKit:A": "tuya:1"])
        let renamed = HomeAppDuplicates.matches(in: devices, names: ["tuya:1": "Abajur"])
        #expect(renamed["homeKit:C"] == "tuya:1")
    }

    @Test func oldCustomizationsStillDecode() throws {
        let old = Data(#"{"isFavorite":true,"isHidden":false}"#.utf8)
        let decoded = try JSONDecoder().decode(DeviceCustomization.self, from: old)
        #expect(decoded.isFavorite)
        #expect(decoded.excludedFromHomeApp == nil)
    }
}

@Suite struct SRTPTests {
    // RFC 3711, B.3 (key derivation).
    @Test func derivesTheRFCSessionKeys() {
        let srtp = SRTPContext(masterKey: HomeKitBridgeTests.data("E1F97A0D3E018BE0D64FA32C06DE4139"),
                               masterSalt: HomeKitBridgeTests.data("0EC675AD498AFEEBB6960B3AABE6"))
        #expect(srtp.rtpKey == HomeKitBridgeTests.data("C61E7A93744F39EE10734AFE3FF7A087"))
        #expect(srtp.rtpSalt == HomeKitBridgeTests.data("30CBBC08863D8C85D49DB34A9AE1"))
        #expect(srtp.rtpAuth == HomeKitBridgeTests.data("CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))
    }
}

#if os(macOS)
@MainActor
@Suite struct HAPCameraTests {
    @Test func setupEndpointsAnswersWithTheSameKeysAndAPort() throws {
        let cameras = HAPCameras()
        let session = Data(repeating: 7, count: 16)
        let address = CameraTLV([(1, CameraTLV.byte(0)), (2, Data("127.0.0.1".utf8)), (3, CameraTLV.uint16(50000)),
                                 (4, CameraTLV.uint16(50002))]).encoded
        let srtp = CameraTLV([(1, CameraTLV.byte(0)), (2, Data(repeating: 1, count: 16)), (3, Data(repeating: 2, count: 14))]).encoded
        let write = CameraTLV([(1, session), (3, address), (4, srtp), (5, srtp)]).encoded.base64EncodedString()
        #expect(cameras.write(14, aid: 2, value: write, local: "::ffff:127.0.0.1", url: { throw URLError(.badURL) }) == .ok)
        let text = try #require(cameras.value(14, aid: 2) as? String)
        let response = CameraTLV(decoding: try #require(Data(base64Encoded: text)))
        #expect(response[1] == session)
        #expect(response[2] == Data([0]))
        let mine = CameraTLV(decoding: try #require(response[3]))
        #expect(String(decoding: try #require(mine[2]), as: UTF8.self) == "127.0.0.1")
        #expect((CameraTLV.integer(mine[3]) ?? 0) > 0)
        #expect(response[4] == srtp)
        cameras.stopAll()
    }

    @Test func supportedVideoListsH264AndSizes() throws {
        let outer = CameraTLV(decoding: try #require(Data(base64Encoded: HAPCameras.supportedVideo)))
        let configuration = CameraTLV(decoding: try #require(outer[1]))
        #expect(configuration[1] == Data([0]))
        let sizes = configuration.items.filter { $0.0 == 3 }.map { CameraTLV(decoding: $0.1) }
        #expect(sizes.contains { CameraTLV.integer($0[1]) == 1280 && CameraTLV.integer($0[2]) == 720 })
    }
}
#endif

@Suite struct SmartThingsGuideTests {
    @Test func manualLinkMatchesTheAppsSignIn() throws {
        let manual = try #require(URLComponents(string: SmartThingsManualGuide.authorizeLink(clientID: "abc")))
        let app = try #require(URLComponents(url: SmartThingsSignIn.authorizeURL(clientID: "abc", state: "x"),
                                             resolvingAgainstBaseURL: false))
        func value(_ name: String, _ c: URLComponents) -> String? { c.queryItems?.first { $0.name == name }?.value }
        for name in ["client_id", "redirect_uri", "scope", "response_type"] { #expect(value(name, manual) == value(name, app)) }
        #expect(SmartThingsManualGuide.steps.count == 5)
        #expect(SmartThingsManualGuide.createCommand.contains(SmartThingsSignIn.redirect))
    }
}
