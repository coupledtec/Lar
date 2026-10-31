import SwiftUI

/// Signing in to the Xbox with a code typed at microsoft.com/link (any phone or computer will do), then waiting for
/// it. Ends with the account, an error, or nil when cancelled.
public struct XboxSignInView: View {
    let onFinish: (Result<XboxAccount, Error>?) -> Void
    @State private var code: XboxSignIn.Code?
    @State private var error: String?
    @State private var attempt = 0
    @Environment(\.openURL) private var openURL

    public init(onFinish: @escaping (Result<XboxAccount, Error>?) -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Entrar no Xbox").font(.headline)
                Spacer()
                Button("Cancelar") { onFinish(nil) }
            }
            if let code {
                Text("Abra \(code.verificationURL.absoluteString.replacingOccurrences(of: "https://", with: "")) em qualquer celular ou computador, digite o código abaixo e entre com a conta Microsoft do Xbox.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(code.userCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                #if !os(tvOS) && !os(watchOS)
                Button("Copiar o código e abrir a página") {
                    copy(code.userCode)
                    openURL(code.verificationURL)
                }
                .frame(maxWidth: .infinity)
                #endif
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Esperando você entrar…").foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.orange)
                Button("Tentar de novo") { self.error = nil; attempt += 1 }
            } else {
                ProgressView()
            }
            Divider()
            XboxConsoleSetup()
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 440)
        #endif
        .task(id: attempt) { await run() }
    }

    private func run() async {
        do {
            let code = try await XboxSignIn.start()
            self.code = code
            let account = try await XboxSignIn.finish(code)
            onFinish(.success(account))
        } catch is CancellationError {
        } catch {
            code = nil
            self.error = (error as? ProviderError)?.message ?? error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS) || os(visionOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// What the console needs for Lar to reach it (the same the Xbox app needs), step by step.
public struct XboxConsoleSetup: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Xbox").font(.subheadline.weight(.semibold))
            Text("1. Configurações → Dispositivos e conexões → Recursos remotos: marque \"Habilitar recursos remotos\".")
            Text("2. Na mesma tela, em Preferências do app Xbox: \"Permitir conexões de qualquer dispositivo\".")
            Text("3. Configurações → Geral → Opções de energia: escolha \"Suspensão\". Em \"Economia de energia\" o Xbox não liga pelo Lar.")
            Text("Se ele não responder, reinicie o console: segure o botão Xbox por 10 segundos e ligue de novo.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }
}
