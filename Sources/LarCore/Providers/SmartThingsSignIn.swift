#if !os(watchOS)
import Foundation
import SwiftUI
#if os(tvOS)
import CoreImage
#else
import WebKit
#endif
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
        var lastError = ProviderError.api(tr("SmartThings: sem resposta"))
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

#if os(tvOS)
/// The Apple TV has no web view: the sign-in page opens on the phone (the QR code), and the code SmartThings shows on
/// the way back (the "code" in the address, or in the page that opens) is typed here.
public struct SmartThingsSignInView: View {
    let clientID: String
    let secret: String
    let onFinish: (Result<String, Error>?) -> Void
    @State private var code = ""
    @State private var exchanging = false

    public init(clientID: String, secret: String, onFinish: @escaping (Result<String, Error>?) -> Void) {
        self.clientID = clientID
        self.secret = secret
        self.onFinish = onFinish
    }

    public var body: some View {
        let url = SmartThingsSignIn.authorizeURL(clientID: clientID, state: "tv")
        HStack(alignment: .top, spacing: 60) {
            QRCodeView(text: url.absoluteString)
                .frame(width: 420, height: 420)
            VStack(alignment: .leading, spacing: 24) {
                Text("Entrar no SmartThings").font(.title2.weight(.semibold))
                Text("Aponte a câmera do celular para o código e entre na sua conta Samsung. No fim, a página mostra um \"code\" de 6 letras: digite-o aqui.")
                    .foregroundStyle(.secondary)
                TextField("Código", text: $code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Entrar") {
                        exchanging = true
                        Task {
                            do {
                                onFinish(.success(try await SmartThingsSignIn.exchange(code: code.trimmingCharacters(in: .whitespaces),
                                                                                       clientID: clientID, secret: secret)))
                            } catch {
                                exchanging = false
                                onFinish(.failure(error))
                            }
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || exchanging)
                    Button("Cancelar") { onFinish(nil) }
                    if exchanging { ProgressView() }
                }
            }
        }
        .padding(60)
    }
}

/// A QR code for a link, sharp at any size.
public struct QRCodeView: View {
    let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
#else
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
                    onFinish(.failure(ProviderError.api(tr("SmartThings não autorizou"))))
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
        let view = WKWebView(frame: .zero, configuration: SmartThingsSignIn.configuration())
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

// MARK: - Signing in again by itself

extension SmartThingsSignIn {
    /// The Samsung account's cookies, kept for this sign-in only (apart from everything else the app opens): with
    /// the account still signed in there, a new sign-in goes through without anyone at the screen.
    @MainActor static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6C1F3A52-8E0B-4D27-9B4A-2F5D7E1C9A30")!)

    @MainActor static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        return configuration
    }

    /// The sign-in page, opened where no one sees it: when the Samsung account is still signed in and the
    /// integration already allowed, SmartThings answers at once with a code, traded here for a new refresh token.
    /// Nil when the page wants the person (signed out, a new permission), or after `timeout`.
    @MainActor
    public static func renewSilently(clientID: String, secret: String, timeout: Duration = .seconds(25)) async -> String? {
        let state = UUID().uuidString
        let code: String? = await withCheckedContinuation { continuation in
            let attempt = SilentAttempt(continuation)
            let coordinator = SignInWebView.Coordinator { url in attempt.finish(Self.code(in: url, state: state)) }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 640), configuration: configuration())
            view.navigationDelegate = coordinator
            view.load(URLRequest(url: authorizeURL(clientID: clientID, state: state)))
            attempt.keep = (view, coordinator)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                attempt.finish(nil)
            }
        }
        guard let code else { return nil }
        return try? await exchange(code: code, clientID: clientID, secret: secret)
    }

    @MainActor private final class SilentAttempt {
        var continuation: CheckedContinuation<String?, Never>?
        /// The page and its delegate, alive until the answer.
        var keep: (WKWebView, AnyObject)?

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func finish(_ code: String?) {
            continuation?.resume(returning: code)
            continuation = nil
            keep?.0.stopLoading()
            keep = nil
        }
    }
}

/// SmartThings refused the saved integration's token (another device renewed it, or it expired): tries a sign-in
/// by itself, and only asks the person when that can't work.
@MainActor
public enum SmartThingsReconnect {
    private static var lastTry: Date?
    private static var trying = false

    /// What the person is told when the sign-in can't go by itself.
    public static let needsPersonAlert = HomeAlert(id: "smartthings-signin", title: tr("SmartThings desconectado"),
                                                   body: tr("Abra os Ajustes do Lar → SmartThings → Entrar de novo."))

    /// - Parameters:
    ///   - renewed: the new refresh token is saved; read the accounts again.
    ///   - needsPerson: the Samsung account wants a sign-in (say so; Settings has "Entrar de novo").
    public static func attempt(_ settings: any AccountSettings, renewed: @escaping @MainActor () -> Void,
                               needsPerson: @escaping @MainActor () -> Void) {
        guard case .oauth(let clientID, let secret, _)? = settings.smartThings, !trying else { return }
        // At most once every ten minutes: a refused integration (deleted, wrong secret) mustn't loop.
        if let lastTry, Date().timeIntervalSince(lastTry) < 600 { return }
        lastTry = Date()
        trying = true
        Task { @MainActor in
            defer { trying = false }
            guard let refresh = await SmartThingsSignIn.renewSilently(clientID: clientID, secret: secret) else {
                needsPerson()
                return
            }
            settings.smartThings = .oauth(clientID: clientID, secret: secret, refreshToken: refresh)
            renewed()
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
#endif
