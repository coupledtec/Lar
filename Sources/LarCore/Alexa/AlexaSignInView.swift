#if !os(watchOS) && !os(tvOS)
import SwiftUI
import WebKit
import os

/// Amazon's sign-in page in a web view (password, then whatever second step the account has: app, SMS, e-mail),
/// its answer caught on the way to the landing page (never opened), and the Lar registered with the code. Ends
/// with the account, an error, or nil when closed.
public struct AlexaSignInView: View {
    let onFinish: (Result<AlexaAccount, Error>?) -> Void
    @State private var attempt = AlexaSignIn.Attempt(serial: AppSettings.alexaAccount?.serial)
    @State private var registering = false

    public init(onFinish: @escaping (Result<AlexaAccount, Error>?) -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Entrar na Amazon (Alexa)").font(.headline)
                Spacer()
                if registering { ProgressView().controlSize(.small) }
                Button("Cancelar") { onFinish(nil) }
            }
            .padding(12)
            Divider()
            AlexaWebView(attempt: attempt) { url in
                guard !registering else { return }
                guard let code = AlexaSignIn.code(in: url) else {
                    onFinish(.failure(ProviderError.api(tr("A Amazon não autorizou"))))
                    return
                }
                registering = true
                Task {
                    do {
                        onFinish(.success(try await AlexaSignIn.register(code: code, attempt: attempt)))
                    } catch {
                        onFinish(.failure(error))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 680)
        #endif
    }
}

/// The page, with the cookies Amazon's mobile sign-in expects set first; hands over the landing address.
@MainActor
private struct AlexaWebView {
    let attempt: AlexaSignIn.Attempt
    let onLanding: (URL) -> Void

    /// Amazon's cookies, apart from everything else the app opens (the sign-in stays for the next time).
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "3B7A1C9E-5D24-4F60-8A13-6E2C0B9D47F1")!)

    func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = AlexaApp.appAgent
        view.navigationDelegate = coordinator
        let attempt = attempt
        Task { @MainActor in
            let store = Self.dataStore.httpCookieStore
            for domain in Set([".amazon.\(attempt.domain)", ".amazon.com"]) {
                for (name, value) in attempt.cookies {
                    if let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE"]) {
                        await store.setCookie(cookie)
                    }
                }
            }
            view.load(URLRequest(url: attempt.url))
        }
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLanding: onLanding) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let onLanding: (URL) -> Void
        private var done = false
        static let log = Logger(subsystem: "com.coupled.lar", category: "alexa")

        init(onLanding: @escaping (URL) -> Void) {
            self.onLanding = onLanding
        }

        private func finish(_ url: URL) {
            guard !done else { return }
            done = true
            Self.log.notice("amazon sign-in answered, code \(AlexaSignIn.code(in: url) != nil)")
            onLanding(url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, AlexaSignIn.isLanding(url) {
                decisionHandler(.cancel)
                finish(url)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url, AlexaSignIn.isLanding(url) {
                webView.stopLoading()
                finish(url)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url, AlexaSignIn.isLanding(url) {
                webView.stopLoading()
                finish(url)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
            if let url = failing ?? webView.url, AlexaSignIn.isLanding(url) { finish(url) }
        }
    }
}

#if os(macOS)
extension AlexaWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension AlexaWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
#endif
