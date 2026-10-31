import Foundation
import Testing
@testable import LarCore

@Suite struct SmartThingsSignInTests {
    @Test func authorizeAsksForACodeBackInTheApp() throws {
        let url = SmartThingsSignIn.authorizeURL(clientID: "client", state: "s1")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "redirect_uri" }?.value == "https://httpbin.org/get")
        #expect(items.first { $0.name == "response_type" }?.value == "code")
        #expect(items.first { $0.name == "client_id" }?.value == "client")
    }

    @Test func codeOnlyWithTheSameState() throws {
        let back = try #require(URL(string: "lar://oauth?code=abc&state=s1"))
        #expect(SmartThingsSignIn.code(in: back, state: "s1") == "abc")
        #expect(SmartThingsSignIn.code(in: back, state: "other") == nil)
        #expect(SmartThingsSignIn.code(in: try #require(URL(string: "lar://oauth?error=access_denied&state=s1")), state: "s1") == nil)
    }

    @Test func codeIsTradedForTheRefreshToken() async throws {
        let refresh = try await SmartThingsSignIn.exchange(code: "abc", clientID: "client", secret: "secret") { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("grant_type=authorization_code"))
            #expect(body.contains("code=abc"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("client:secret".utf8).base64EncodedString())
            let json = Data(#"{"access_token":"a","refresh_token":"r1","expires_in":86399}"#.utf8)
            return (json, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(refresh == "r1")
    }

    @Test func refusedCodeIsUnauthorized() async {
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await SmartThingsSignIn.exchange(code: "old", clientID: "c", secret: "s") { request in
                (Data(#"{"error":"invalid_grant"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            }
        }
    }
}
