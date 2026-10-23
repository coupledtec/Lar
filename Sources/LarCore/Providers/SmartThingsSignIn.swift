#if !os(watchOS)
import Foundation
import SwiftUI
import WebKit
import os

/// Signing in to SmartThings with an OAuth integration: the account's own page in a web view, its answer caught on
/// the way to the integration's redirect (the page never loads), and the code traded for the first refresh token.
/// Each app (Mac, iPhone, the TV) needs its own integration: the refresh token turns over at every renewal, so two
/// apps sharing one log each other out.
public enum SmartThingsSignIn {
    /// The redirect registered with the integrations. SmartThings doesn't send the browser to an app's own scheme,
    /// so it's a web address that's never actually opened.
    public static let redirect = "https://httpbin.org/get"
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

    public static func exchange(code: String, clientID: String, secret: String,
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

}

/// A sign-in to show: with which integration.
public struct SmartThingsSignInRequest: Identifiable {
    public let id = UUID()
    public let clientID: String
    public let secret: String

    public init(clientID: String, secret: String) {
        self.clientID = clientID
        self.secret = secret
    }
}

/// The sign-in page; ends with the refresh token, an error, or nil when closed.
public struct SmartThingsSignInView: View {
    let clientID: String
    let secret: String
    let onFinish: (Result<String, Error>?) -> Void
    @State private var state = UUID().uuidString
    @State private var exchanging = false

    public init(clientID: String, secret: String, onFinish: @escaping (Result<String, Error>?) -> Void) {
        self.clientID = clientID
        self.secret = secret
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Entrar no SmartThings").font(.headline)
                Spacer()
                if exchanging { ProgressView().controlSize(.small) }
                Button("Cancelar") { onFinish(nil) }
            }
            .padding(12)
            Divider()
            SignInWebView(url: SmartThingsSignIn.authorizeURL(clientID: clientID, state: state)) { callback in
                guard !exchanging else { return }
                guard let code = SmartThingsSignIn.code(in: callback, state: state) else {
                    onFinish(.failure(ProviderError.api("SmartThings não autorizou")))
                    return
                }
                exchanging = true
                Task {
                    do {
                        onFinish(.success(try await SmartThingsSignIn.exchange(code: code, clientID: clientID, secret: secret)))
                    } catch {
                        onFinish(.failure(error))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 640)
        #endif
    }
}

/// A web view that hands over the first link going to the redirect instead of opening it.
@MainActor
private struct SignInWebView {
    let url: URL
    let onCallback: (URL) -> Void

    func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let onCallback: (URL) -> Void
        private var done = false

        init(onCallback: @escaping (URL) -> Void) {
            self.onCallback = onCallback
        }

        static let log = Logger(subsystem: "com.coupled.lar", category: "smartthings")

        static func isCallback(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.host() == URL(string: SmartThingsSignIn.redirect)?.host() || url.scheme == "lar"
        }

        private func finish(_ url: URL) {
            guard !done else { return }
            Self.log.notice("sign-in answered: \(url.host() ?? "-", privacy: .public), code \(url.query()?.contains("code=") == true)")
            done = true
            onCallback(url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            Self.log.notice("sign-in page: \(action.request.url?.host() ?? "-", privacy: .public)\(action.request.url?.path() ?? "", privacy: .public)")
            if let url = action.request.url, Self.isCallback(url) {
                decisionHandler(.cancel)
                finish(url)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url, Self.isCallback(url) {
                webView.stopLoading()
                finish(url)
            }
        }

        // SmartThings sends the browser on with a server redirect, which doesn't always ask the policy again: the
        // address is checked again as the page starts and as it ends (the redirect's page is never needed).
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url, Self.isCallback(url) {
                webView.stopLoading()
                finish(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, Self.isCallback(url) { finish(url) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Self.log.error("sign-in failed: \(error.localizedDescription, privacy: .public)")
            let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
            if let url = failing ?? webView.url, Self.isCallback(url) { finish(url) }
        }
    }
}

#if os(macOS)
extension SignInWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension SignInWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
#endif
