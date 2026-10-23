import LarCore
import SwiftUI

/// The intercom's SIP account (the Mac's Settings → Porteiro): server, user, password (keychain), the intercom's
/// number and the keys that open the gate.
struct PorteiroSection: View {
    var phone: PhoneStore

    @State private var draft = PhoneSettings.load()
    @State private var password = ""
    @State private var port = ""

    var body: some View {
        Section {
            Toggle("Atender e ligar pelo Lar", isOn: $draft.isEnabled)
            TextField("Servidor (sip.provedor.com.br)", text: $draft.server)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Porta (5060)", text: $port).keyboardType(.numberPad)
            TextField("Usuário ou ramal", text: $draft.user).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(PhoneSettings.password == nil ? "Senha" : "Senha · salva", text: $password)
            TextField("Domínio (opcional)", text: $draft.domain).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Número do porteiro", text: $draft.doorNumber).keyboardType(.phonePad)
            TextField("Teclas que abrem o portão (ex.: *1)", text: $draft.doorCode).keyboardType(.phonePad)
            Button("Salvar") {
                draft.port = UInt16(port) ?? 5060
                let newPassword = password.isEmpty ? nil : password
                password = ""
                Task { await phone.save(draft, password: newPassword) }
            }
            .disabled(draft.server.isEmpty || draft.user.isEmpty)
        } header: {
            HStack {
                Text("Porteiro (VoIP)")
                Spacer()
                Text(statusText).foregroundStyle(phone.registration == .registered ? .green : .secondary)
            }
        } footer: {
            Text("No iPhone, o porteiro toca com o Lar aberto (com o app fechado, só com a conta paga de desenvolvedor da Apple). O Mac toca sempre. Use um ramal diferente do Mac, ou um grupo de toque no PABX, para os dois tocarem.")
        }
        .onAppear {
            draft = PhoneSettings.load()
            port = String(draft.port)
        }
    }

    private var statusText: String {
        switch phone.registration {
        case .off: ""
        case .registering: "Registrando…"
        case .registered: "Registrado"
        case .failed(let reason): reason
        }
    }
}
