import Foundation
import Testing
@testable import LarCore

@Suite struct XboxTests {
    /// Answers by host and path, like Microsoft and Xbox network; records what was sent.
    final class Fake: @unchecked Sendable {
        var sent: [URLRequest] = []
        var power = "ConnectedStandby"
        var commandResult = #"{"result":{"errorCode":"OK"}}"#
        var refreshAnswer = #"{"access_token":"at","refresh_token":"rt2"}"#

        func handle(_ request: URLRequest) -> (Data, URLResponse) {
            sent.append(request)
            let url = request.url!
            let body: String
            var status = 200
            switch (url.host!, url.path) {
            case ("login.microsoftonline.com", let path) where path.hasSuffix("/token"):
                body = refreshAnswer
                if body.contains("invalid_grant") { status = 400 }
            case ("user.auth.xboxlive.com", _): body = #"{"Token":"ut"}"#
            case ("xsts.auth.xboxlive.com", _):
                body = #"{"Token":"xt","NotAfter":"2099-01-01T00:00:00.0000000Z","DisplayClaims":{"xui":[{"uhs":"H","xid":"X1","gtg":"Jogador"}]}}"#
            case ("xccs.xboxlive.com", "/lists/devices"):
                body = #"{"result":[{"id":"C1","name":"XBOX Series S","powerState":"\#(power)","remoteManagementEnabled":true}]}"#
            case ("xccs.xboxlive.com", "/consoles/C1"): body = #"{"powerState":"\#(power)","playbackState":"Stopped"}"#
            case ("xccs.xboxlive.com", "/lists/installedApps"):
                body = #"{"result":[{"oneStoreProductId":"9N1","name":"Far Cry 3","isGame":true},{"oneStoreProductId":"9P2","name":"YouTube","isGame":false},{"name":"Sem produto"}]}"#
            case ("xccs.xboxlive.com", "/commands"): body = commandResult
            case ("userpresence.xboxlive.com", _):
                body = #"{"state":"Online","devices":[{"type":"Scarlett","titles":[{"name":"Início","placement":"Background"},{"name":"Far Cry 3","placement":"Full"}]}]}"#
            default: body = "{}"; status = 404
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        func commands() -> [[String: Any]] {
            sent.filter { $0.url?.path == "/commands" }.compactMap {
                (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any]
            }
        }
    }

    final class Saved: @unchecked Sendable { var account: XboxAccount? }

    func provider(_ fake: Fake, saved: Saved = Saved()) -> XboxProvider {
        XboxProvider(client: XboxClient(account: XboxAccount(refreshToken: "rt1", gamertag: "?"),
                                        save: { saved.account = $0 }, transport: { fake.handle($0) }))
    }

    @Test func listsTheConsoleWithWhatIsPlaying() async throws {
        let fake = Fake()
        fake.power = "On"
        let saved = Saved()
        let devices = try await provider(fake, saved: saved).devices()
        #expect(devices.count == 1)
        let xbox = try #require(devices.first)
        #expect(xbox.id == "xbox:C1")
        #expect(xbox.name == "XBOX Series S")
        #expect(xbox.isOn == true)
        #expect(xbox.kind == .gameConsole)
        #expect(Labels.kindTitle(xbox.kind) == "Jogos")
        #expect(xbox.detail == "Far Cry 3")
        #expect(xbox.hasRemote && xbox.hasDirectionalPad && xbox.canType && !xbox.hasChannels)
        // The renewed refresh token and the gamertag are kept.
        #expect(saved.account == XboxAccount(refreshToken: "rt2", gamertag: "Jogador"))
        let xccs = try #require(fake.sent.first { $0.url?.host == "xccs.xboxlive.com" })
        #expect(xccs.value(forHTTPHeaderField: "Authorization") == "XBL3.0 x=H;xt")
        #expect(xccs.value(forHTTPHeaderField: "skillplatform") == "RemoteManagement")
        let user = try #require(fake.sent.first { $0.url?.host == "user.auth.xboxlive.com" })
        #expect(String(decoding: user.httpBody!, as: UTF8.self).contains(#""RpsTicket":"d=at""#))
    }

    @Test func sleepIsOffAndCanWake() async throws {
        let fake = Fake()
        let xbox = provider(fake)
        let device = try #require(try await xbox.devices().first)
        #expect(device.isOn == false)
        #expect(device.canSwitch)
        try await xbox.send(.power(true), to: device)
        let command = try #require(fake.commands().last)
        #expect(command["type"] as? String == "Power")
        #expect(command["command"] as? String == "WakeUp")
        #expect(command["linkedXboxId"] as? String == "C1")
        // The cloud still says asleep: the list keeps it on for a while.
        #expect(try await xbox.devices().first?.isOn == true)
    }

    @Test func remoteKeysBecomeControllerButtons() async throws {
        let fake = Fake()
        let xbox = provider(fake)
        let device = HomeDevice(provider: .xbox, rawID: "C1", name: "Xbox", kind: .gameConsole, isOn: true)
        try await xbox.press(.select, on: device)
        try await xbox.press(.back, on: device)
        try await xbox.press(.home, on: device)
        try await xbox.press(.volumeUp, on: device)
        try await xbox.press(XboxProvider.Button.y, on: device)
        let sent = fake.commands().map { "\($0["type"]!)/\($0["command"]!)" }
        #expect(sent == ["Shell/InjectKey", "Shell/InjectKey", "Shell/GoHome", "Audio/Volume", "Shell/InjectKey"])
        let keys = fake.commands().compactMap { (($0["parameters"] as? [[String: String]])?.first)?["keyType"] }
        #expect(keys == ["A", "B", "Y"])
        await #expect(throws: ProviderError.unsupported) { try await xbox.press(.channelUp, on: device) }
    }

    @Test func appsAndTyping() async throws {
        let fake = Fake()
        let xbox = provider(fake)
        let device = HomeDevice(provider: .xbox, rawID: "C1", name: "Xbox", kind: .gameConsole, isOn: true)
        let apps = try await xbox.apps(on: device)
        // Apps first, then games; nothing without a store product.
        #expect(apps.map(\.name) == ["YouTube", "Far Cry 3"])
        try await xbox.openApp("9P2", on: device)
        try await xbox.type("halo", on: device)
        let params = fake.commands().compactMap { ($0["parameters"] as? [[String: String]])?.first }
        #expect(params == [["oneStoreProductId": "9P2"], ["replacementString": "halo"]])
    }

    @Test func unreachableConsoleSaysWhatToCheck() async throws {
        let fake = Fake()
        fake.commandResult = #"{"result":{"errorCode":"ErrorCallingWNS","errorMessage":"Send command failed"}}"#
        let xbox = provider(fake)
        let device = HomeDevice(provider: .xbox, rawID: "C1", name: "Xbox", kind: .gameConsole, isOn: false)
        await #expect(throws: ProviderError.api("O Xbox não respondeu: confira se está em Suspensão, com os recursos remotos ligados e na internet.")) {
            try await xbox.send(.power(true), to: device)
        }
    }

    @Test func expiredSignInIsUnauthorized() async {
        let fake = Fake()
        fake.refreshAnswer = #"{"error":"invalid_grant"}"#
        await #expect(throws: ProviderError.unauthorized) { _ = try await provider(fake).devices() }
    }

    @Test func expectedPowerLastsUntilTheCloudAgreesOrAMinute() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let expected = ExpectedPower(now: { clock.now })
        await expected.set(true, for: "C1")
        #expect(await expected.power(of: "C1", reported: false) == true)
        clock.now = clock.now.addingTimeInterval(61)
        #expect(await expected.power(of: "C1", reported: false) == false)
        await expected.set(false, for: "C1")
        #expect(await expected.power(of: "C1", reported: false) == false)
        // Agreed: forgotten, so a later change on the console itself shows.
        #expect(await expected.power(of: "C1", reported: true) == true)
    }

    @Test func formBodyEncodesReservedCharacters() {
        #expect(XboxClient.formBody(["scope": "a b", "t": "x+y/z="]) == "scope=a%20b&t=x%2By%2Fz%3D")
    }
}
