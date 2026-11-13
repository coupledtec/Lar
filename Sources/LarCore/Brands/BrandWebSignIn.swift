#if !os(watchOS) && !os(tvOS)
import SwiftUI
import WebKit

/// A brand's own sign-in page (Sony's, for PlayStation), its one-time code caught on the way to the brand's app
/// (never opened). The password stays on the brand's page.
struct BrandWebSignIn: View {
    let web: BrandToken.Web
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel)
            }
            .padding(12)
            Divider()
            BrandWebView(web: web, onCode: onCode)
        }
        #if os(macOS)
        .frame(width: 460, height: 680)
        #endif
    }

    /// The code in the brand's redirect ("…://redirect/?code=XXXX&cid=…").
    nonisolated static func code(in url: URL, redirect: String) -> String? {
        guard url.absoluteString.hasPrefix(redirect) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }
}

@MainActor
private struct BrandWebView {
    let web: BrandToken.Web
    let onCode: (String) -> Void

    func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing kept: each sign-in starts clean.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Some sign-in pages refuse what doesn't look like a browser.
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = coordinator
        view.load(URLRequest(url: web.url))
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(redirect: web.redirect, onCode: onCode) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let redirect: String
        let onCode: (String) -> Void
        private var done = false

        init(redirect: String, onCode: @escaping (String) -> Void) {
            self.redirect = redirect
            self.onCode = onCode
        }

        private func check(_ url: URL?) -> Bool {
            guard let url, url.absoluteString.hasPrefix(redirect) else { return false }
            if !done, let code = BrandWebSignIn.code(in: url, redirect: redirect) {
                done = true
                onCode(code)
            }
            return true
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(check(action.request.url) ? .cancel : .allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            _ = check((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
        }
    }
}

#if os(macOS)
extension BrandWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension BrandWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
#endif
