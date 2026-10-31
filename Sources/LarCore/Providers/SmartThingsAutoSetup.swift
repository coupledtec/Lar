#if !os(watchOS) && !os(tvOS)
import Foundation
import SwiftUI
import WebKit
import os

/// SmartThings set up with the least the person has to do: they sign in to the Samsung account and tap "Authorize"
/// once per device. In one page (the sign-in's own cookies): SmartThings' tokens page, where a personal token is
/// filled in, generated and read by the app (it expires in 24 h and is never kept); with it, one integration per
/// device ("Lar (iPhone)", "Lar (Apple Watch)"); then each integration's sign-in, already signed in.
@MainActor
@Observable
public final class SmartThingsAutoSetup: NSObject {
    public struct Result: Sendable {
        public let device: String
        public let clientID: String
        public let secret: String
        public let refreshToken: String
    }

    public enum Phase: Equatable {
        case signIn
        case creating
        case authorize(String)
        case done
        case failed(String)
    }

    public private(set) var phase: Phase = .signIn
    private let devices: [String]
    private let onFinish: ([Result]) -> Void
    private var integrations: [(device: String, integration: SmartThingsSetup.Integration)] = []
    private var results: [Result] = []
    private var state = UUID().uuidString
    private var tookToken = false
    @ObservationIgnored private(set) lazy var webView: WKWebView = makeWebView()
    static let log = Logger(subsystem: "com.coupled.lar", category: "smartthings")

    /// - Parameter devices: the names the integrations are made for, this device's first.
    public init(devices: [String], onFinish: @escaping ([Result]) -> Void) {
        self.devices = devices
        self.onFinish = onFinish
    }

    public var message: String {
        switch phase {
        case .signIn: tr("Entre na sua conta Samsung. O Lar cria o resto sozinho.")
        case .creating: tr("Criando as integrações…")
        case .authorize(let device): tr("Toque em “Authorize” para liberar o Lar no \(device).")
        case .done: tr("Pronto.")
        case .failed(let message): message
        }
    }

    public func start() {
        webView.load(URLRequest(url: SmartThingsSetup.tokensPage))
    }

    private func makeWebView() -> WKWebView {
        let configuration = SmartThingsSignIn.configuration()
        let script = WKUserScript(source: Self.tokenScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(WeakHandler(self), name: "lar")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }

    // MARK: Steps

    private func took(token: String) {
        guard !tookToken else { return }
        tookToken = true
        phase = .creating
        Self.log.notice("auto setup: personal token read")
        Task {
            do {
                for device in devices {
                    let made = try await SmartThingsSetup.createIntegration(personalToken: token, deviceName: device)
                    integrations.append((device, made))
                }
                authorizeNext()
            } catch {
                phase = .failed((error as? ProviderError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func authorizeNext() {
        guard results.count < integrations.count else {
            phase = .done
            onFinish(results)
            return
        }
        let next = integrations[results.count]
        state = UUID().uuidString
        phase = .authorize(next.device)
        webView.load(URLRequest(url: SmartThingsSignIn.authorizeURL(clientID: next.integration.clientID, state: state)))
    }

    private func callback(_ url: URL) {
        guard case .authorize = phase else { return }
        let current = integrations[results.count]
        guard let code = SmartThingsSignIn.code(in: url, state: state) else {
            phase = .failed(tr("SmartThings não autorizou o \(current.device)"))
            return
        }
        phase = .creating
        Task {
            do {
                let refresh = try await SmartThingsSignIn.exchange(code: code, clientID: current.integration.clientID,
                                                                   secret: current.integration.secret)
                results.append(Result(device: current.device, clientID: current.integration.clientID,
                                      secret: current.integration.secret, refreshToken: refresh))
                authorizeNext()
            } catch {
                phase = .failed((error as? ProviderError)?.message ?? error.localizedDescription)
            }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if let token = message["token"] as? String, phase == .signIn { took(token: token) }
        if let page = message["page"] as? String { Self.log.notice("auto setup page: \(page, privacy: .public)") }
    }

    /// On SmartThings' tokens page: opens the new-token form, names it, ticks every permission, generates it, and
    /// hands the new token over (from the page's own answer, or as it shows on the screen).
    static let tokenScript = #"""
    (() => {
      if (window.__lar) return; window.__lar = true;
      const uuid = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
      const post = (m) => { try { window.webkit.messageHandlers.lar.postMessage(m); } catch (e) {} };
      let submitted = false, sent = false, opened = false, filled = false, before = new Set();
      const found = (t) => {
        if (sent || !submitted || before.has(t.toLowerCase())) return;
        sent = true; post({ token: t });
      };
      const scan = (text) => {
        try {
          const walk = (o) => {
            if (!o || typeof o !== 'object') return;
            for (const [k, v] of Object.entries(o)) {
              if (typeof v === 'string' && /token/i.test(k) && /^[0-9a-f-]{36}$/i.test(v)) found(v); else walk(v);
            }
          };
          walk(JSON.parse(text));
        } catch (e) {}
      };
      const originalFetch = window.fetch;
      window.fetch = async (...args) => {
        const response = await originalFetch(...args);
        try { response.clone().text().then(scan); } catch (e) {}
        return response;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (...args) {
        this.addEventListener('load', () => { try { scan(this.responseText); } catch (e) {} });
        return open.apply(this, args);
      };
      const label = (el) => (el.innerText || el.value || '').trim();
      const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const setValue = (input, value) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      };
      const uuidsNow = () => {
        const all = [document.body.innerText, ...[...document.querySelectorAll('input, textarea')].map((i) => i.value)];
        return all.flatMap((t) => t.match(uuid) || []).map((u) => u.toLowerCase());
      };
      const step = () => {
        if (location.hostname !== 'account.smartthings.com') return;
        if (submitted) { if (!sent) uuidsNow().forEach(found); return; }
        const boxes = [...document.querySelectorAll('input[type=checkbox]')];
        const name = [...document.querySelectorAll('input[type=text], input:not([type])')].filter(visible)[0];
        if (!filled && boxes.length >= 3 && name) {
          filled = true;
          setValue(name, 'Lar ' + new Date().toISOString().slice(0, 16).replace('T', ' '));
          boxes.forEach((box) => { if (!box.checked) box.click(); });
          setTimeout(() => {
            const submit = [...document.querySelectorAll('button, input[type=submit]')].filter(visible)
              .find((b) => /generate token|gerar token|create token|criar token/i.test(label(b)))
              || document.querySelector('form button[type=submit]');
            before = new Set(uuidsNow());
            submitted = true;
            if (submit) submit.click();
            post({ page: 'submitted:' + !!submit });
          }, 700);
          return;
        }
        if (!opened && !filled) {
          const button = [...document.querySelectorAll('button, a')].filter(visible)
            .find((b) => /generate new token|gerar novo token|new token|novo token/i.test(label(b)));
          if (button) { opened = true; button.click(); }
        }
      };
      new MutationObserver(step).observe(document.documentElement, { childList: true, subtree: true });
      setInterval(step, 1000);
      post({ page: location.hostname + location.pathname });
    })();
    """#
}

// MARK: Navigation (the sign-ins' answers)

extension SmartThingsAutoSetup: WKNavigationDelegate {
    private static func isCallback(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host() == URL(string: SmartThingsSignIn.redirect)?.host()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, Self.isCallback(url) {
            decisionHandler(.cancel)
            callback(url)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url, Self.isCallback(url) {
            webView.stopLoading()
            callback(url)
        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, Self.isCallback(url) {
            webView.stopLoading()
            callback(url)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if let url = failing ?? webView.url, Self.isCallback(url) { callback(url) }
    }
}

/// The script's messages, without the page keeping the setup alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: SmartThingsAutoSetup?

    init(_ target: SmartThingsAutoSetup) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}

/// The page, with what the app is doing above it.
public struct SmartThingsAutoSetupView: View {
    @State private var setup: SmartThingsAutoSetup
    let onCancel: () -> Void

    public init(devices: [String], onFinish: @escaping ([SmartThingsAutoSetup.Result]) -> Void, onCancel: @escaping () -> Void) {
        _setup = State(initialValue: SmartThingsAutoSetup(devices: devices, onFinish: onFinish))
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configurar o SmartThings").font(.headline)
                    Text(setup.message).font(.footnote)
                        .foregroundStyle(isFailure ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if setup.phase == .creating { ProgressView().controlSize(.small) }
                Button("Cancelar") { onCancel() }
            }
            .padding(12)
            Divider()
            AutoSetupWebView(webView: setup.webView)
        }
        .onAppear { setup.start() }
        #if os(macOS)
        .frame(width: 520, height: 700)
        #endif
    }

    private var isFailure: Bool { if case .failed = setup.phase { true } else { false } }
}

private struct AutoSetupWebView {
    let webView: WKWebView
}

#if os(macOS)
extension AutoSetupWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension AutoSetupWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
#endif
