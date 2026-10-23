import LarCore
import SwiftUI

/// The intercom's SIP account in Settings: server, user, password (keychain), the intercom's number and the keys
/// that open the gate.
struct PorteiroSection: View {
    var phone: PhoneStore

    @State private var draft = PhoneSettings.load()
    @State private var password = ""
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PORTEIRO (VOIP)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor)
            }
            Toggle("Atender e ligar para o porteiro pelo Lar", isOn: $draft.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            grid
            HStack {
                Text("A senha fica no Porta-chaves. O Mac fica registrado no servidor e toca mesmo com o popover fechado.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Salvar") {
                    draft.port = UInt16(port) ?? 5060
                    let newPassword = password.isEmpty ? nil : password
                    password = ""
                    Task { await phone.save(draft, password: newPassword) }
                }
                .disabled(draft.server.isEmpty || draft.user.isEmpty)
            }
        }
        .padding(12)
        .card()
        .onAppear {
            draft = PhoneSettings.load()
            port = String(draft.port)
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            row("Servidor", TextField("sip.provedor.com.br", text: $draft.server))
            row("Porta", TextField("5060", text: $port))
            row("Usuário", TextField("ramal ou usuário", text: $draft.user))
            row("Senha", SecureField(PhoneSettings.password == nil ? "senha" : "•••••• salva", text: $password))
            row("Domínio", TextField("opcional (se diferente do servidor)", text: $draft.domain))
            row("Porteiro", TextField("número ou ramal do porteiro", text: $draft.doorNumber))
            row("Abrir", TextField("teclas que abrem o portão, ex.: *1", text: $draft.doorCode))
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
    }

    private func row(_ title: String, _ field: some View) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            field
        }
    }

    private var statusText: String {
        switch phone.registration {
        case .off: phone.settings.isEnabled ? "Desligado" : ""
        case .registering: "Registrando…"
        case .registered: "Registrado"
        case .failed(let reason): reason
        }
    }

    private var statusColor: Color {
        switch phone.registration {
        case .registered: .green
        case .failed: Theme.warning
        default: Theme.secondaryText
        }
    }
}
