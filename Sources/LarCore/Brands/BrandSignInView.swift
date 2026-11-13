import SwiftUI

/// Signing in to a robot or lock brand: the e-mail (and password, when the brand takes one), then the code the
/// brand sends, when it sends one. Ends with the account, or nil when cancelled.
public struct BrandSignInView: View {
    let signIn: BrandSignIn
    let onFinish: (BrandAccount?) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var codeStep: (hint: String, finish: @Sendable (String) async throws -> BrandAccount)?
    @State private var busy = false
    @State private var error: String?

    public init(signIn: BrandSignIn, onFinish: @escaping (BrandAccount?) -> Void) {
        self.signIn = signIn
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Entrar: \(signIn.provider.name)").font(.headline)
                Spacer()
                Button("Cancelar") { onFinish(nil) }
            }
            Text(signIn.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let codeStep {
                Text(codeStep.hint).fixedSize(horizontal: false, vertical: true)
                TextField("Código", text: $code)
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textContentType(.oneTimeCode)
                    .onSubmit(finish)
                button("Entrar", disabled: code.trimmingCharacters(in: .whitespaces).isEmpty, action: finish)
            } else if let token = signIn.token {
                if let url = URL(string: token.link) {
                    Link(destination: url) { Label(token.link.replacingOccurrences(of: "https://", with: ""), systemImage: "safari") }
                        .font(.footnote)
                }
                SecureField(token.label, text: $password)
                    .onSubmit(start)
                button("Entrar", disabled: password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: start)
            } else {
                TextField("E-mail", text: $email)
                    .textContentType(.username)
                    #if os(iOS) || os(visionOS) || os(tvOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                if signIn.needsPassword {
                    SecureField("Senha", text: $password)
                        .textContentType(.password)
                        .onSubmit(start)
                }
                button(signIn.needsPassword ? "Entrar" : "Receber o código",
                       disabled: !email.contains("@") || (signIn.needsPassword && password.isEmpty), action: start)
            }
            if let error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text(signIn.token != nil
                 ? "Integração não oficial: a marca pode mudá-la. O token não fica guardado: só a chave que a marca devolve, no Porta-chaves."
                 : signIn.keepsPassword
                 ? "Os aparelhos precisam já estar no app \(signIn.appName). Integração não oficial: a marca pode mudá-la. A senha fica no Porta-chaves deste aparelho, porque a marca não renova a sessão sozinha."
                 : "Os aparelhos precisam já estar no app \(signIn.appName). Integração não oficial: a marca pode mudá-la. A senha não fica guardada: só a chave que a marca devolve, no Porta-chaves.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if !os(tvOS) && !os(watchOS)
        .textFieldStyle(.roundedBorder)
        #endif
        .padding(16)
        #if os(macOS)
        .frame(width: 420)
        #endif
        .disabled(busy)
    }

    private func button(_ title: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if busy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
    }

    private func start() {
        let email = email.trimmingCharacters(in: .whitespaces), password = password
        Task {
            busy = true
            error = nil
            do {
                switch try await signIn.start(email, password) {
                case .done(let account): onFinish(account)
                case .code(let hint, let finish): codeStep = (hint, finish)
                }
            } catch {
                self.error = (error as? ProviderError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }

    private func finish() {
        guard let codeStep else { return }
        let code = code
        Task {
            busy = true
            error = nil
            do {
                onFinish(try await codeStep.finish(code))
            } catch {
                self.error = (error as? ProviderError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}
