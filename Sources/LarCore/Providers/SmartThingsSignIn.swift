#if !os(watchOS)
import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Signing in to SmartThings with an OAuth integration: the account's own page in a browser sheet, back to the app
/// at `lar://oauth`, and the code traded for the first refresh token. Each app (Mac, iPhone, the TV) needs its own
/// integration: the refresh token turns over at every renewal, so two apps sharing one log each other out.
public enum SmartThingsSignIn {
    public static let redirect = "lar://oauth"
    static let scopes = "r:locations:* r:devices:* x:devices:*"
    static let authorize = URL(string: "https://api.smartthings.com/oauth/authorize")!

    public static func authorizeURL(clientID: String, state: String) -> URL {
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The code in the link the sign-in came back with, when it's ours (same state) and not an error.
    public static func code(in callback: URL, state: String) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return items.first(where: { $0.name == "code" })?.value
    }

    /// Signs in and returns the refresh token to save with the integration's ID and secret.
    @MainActor
    public static func run(clientID: String, secret: String) async throws -> String {
        let state = UUID().uuidString
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizeURL(clientID: clientID, state: state),
                                                     callbackURLScheme: "lar") { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: ProviderError.api(error?.localizedDescription ?? "SmartThings: sem resposta"))
                }
            }
            session.presentationContextProvider = Anchor.shared
            session.start()
        }
        guard let code = code(in: callback, state: state) else { throw ProviderError.api("SmartThings não autorizou") }
        return try await exchange(code: code, clientID: clientID, secret: secret)
    }

    static func exchange(code: String, clientID: String, secret: String,
                         transport: HTTPTransport = { try await URLSession.shared.data(for: $0) }) async throws -> String {
        var lastError = ProviderError.api("SmartThings: sem resposta")
        for host in SmartThingsClient.authHosts {
            var request = URLRequest(url: host)
            request.httpMethod = "POST"
            request.setValue("Basic " + Data("\(clientID):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: redirect),
            ]
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            do {
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let json = try? JSONDecoder().decode(JSONValue.self, from: data), let refresh = json["refresh_token"]?.string,
                   (200..<300).contains(status) {
                    return refresh
                }
                if status == 400 || status == 401 { throw ProviderError.unauthorized }
                lastError = .api("SmartThings: HTTP \(status)")
            } catch let error as ProviderError where error == .unauthorized {
                throw error
            } catch let error as ProviderError {
                lastError = error
            } catch {
                lastError = .network(error.localizedDescription)
            }
        }
        throw lastError
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = Anchor()

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                #if os(macOS)
                NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
                #else
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
                #endif
            }
        }
    }
}
#endif
