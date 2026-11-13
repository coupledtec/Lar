#if !os(watchOS)
import SwiftUI

/// Pairing the PS5 with Remote Play, so the Lar can turn it on: its address on the network and the 8-digit code it
/// shows. Ends with the pairing, or nil when cancelled.
public struct PlayStationPairView: View {
    let onFinish: (PlayStationRemotePlay.Pairing?) -> Void

    @State private var host = PlayStationClient.savedPairing?.host ?? ""
    @State private var code = ""
    @State private var loginPIN = PlayStationClient.savedPairing?.loginPIN ?? ""
    @State private var busy = false
    @State private var searching = false
    @State private var found: [String: PlayStationRemotePlay.State] = [:]
    @State private var error: String?
    @State private var paired: PlayStationRemotePlay.Pairing?
    @State private var showFailure = false

    public init(onFinish: @escaping (PlayStationRemotePlay.Pairing?) -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ligar o PS5 pelo Lar").font(.headline)
                Spacer()
                Button("Cancelar") { onFinish(nil) }
            }
            Text("No PS5, uma vez só:").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Configurações → Sistema → Reprodução remota: ative Ativar Reprodução remota.")
                Text("2. Configurações → Sistema → Economia de energia → Recursos disponíveis no Modo de repouso: ative Permanecer conectado à internet e Ativar a ligação do PS5 pela rede.")
                Text("3. Configurações → Sistema → Reprodução remota → Vincular dispositivo: aparece um código de 8 números.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField("Endereço do PS5 (ex.: 192.168.0.20)", text: $host)
                #if os(iOS) || os(visionOS) || os(tvOS)
                // The decimal pad has a comma instead of a dot in Portuguese: numbers and punctuation have both.
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onChange(of: host) { _, typed in
                    let clean = typed.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
                    if clean != typed { host = clean }
                }
                .autocorrectionDisabled()
            #if os(macOS)
            HStack {
                Button(searching ? "Procurando…" : "Procurar na rede") { search() }
                    .disabled(searching)
                ForEach(found.keys.sorted(), id: \.self) { address in
                    Button(label(address)) { host = address }
                }
            }
            .font(.footnote)
            #else
            Text("O endereço está no PS5 em Configurações → Rede → Status da conexão → Ver status da conexão (Endereço IPv4).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            TextField("Código de 8 números", text: $code)
                #if os(iOS) || os(visionOS) || os(tvOS)
                .keyboardType(.numberPad)
                #endif
            SecureField("Senha de acesso da conta no PS5 (se tiver)", text: $loginPIN)
                #if os(iOS) || os(visionOS) || os(tvOS)
                .keyboardType(.numberPad)
                #endif
            Text("Ao ligar pelo Lar, o PS5 já entra com a conta PlayStation do Lar. Se ela tiver senha de acesso no console, o Lar a digita (fica só no Porta-chaves).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: pair) {
                HStack {
                    Text("Parear")
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || host.isEmpty || code.filter(\.isNumber).count != 8)
            if let error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Depois de pareado, o PS5 liga e entra em Modo de repouso pela lista do Lar. Desligar por completo só pelo próprio console: a Sony não deixa de fora. Integração não oficial: a Sony pode mudá-la.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
        .padding(16)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .disabled(busy)
        .alert("PS5 pareado", isPresented: Binding(get: { paired != nil }, set: { if !$0 { paired = nil } })) {
            Button("OK") { if let paired { onFinish(paired) } }
        } message: {
            Text("\(paired?.nickname ?? "PS5") (\(paired?.host ?? "")) agora liga e entra em Modo de repouso pela lista do Lar.")
        }
        .alert("Não deu para parear", isPresented: $showFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    #if os(macOS)
    private func label(_ address: String) -> String {
        switch found[address] {
        case .on(let name, _): "\(name ?? "PS5") · \(address)"
        case .standby(let name): "\(name ?? "PS5") · \(address) · " + tr("em repouso")
        case nil: address
        }
    }

    private func search() {
        searching = true
        Task {
            found = await PlayStationRemotePlay.discover()
            if found.count == 1, let only = found.keys.first { host = only }
            if found.isEmpty { error = tr("Nenhum PS5 respondeu. Ele está ligado ou em repouso, na mesma rede?") }
            searching = false
        }
    }
    #endif

    private func pair() {
        let host = host.trimmingCharacters(in: .whitespaces), code = code
        Task {
            busy = true
            error = nil
            do {
                guard let account = PlayStationClient.savedAccountID else {
                    throw ProviderError.api(tr("Entre de novo na conta PlayStation."))
                }
                var pairing = try await PlayStationRemotePlay.pair(host: host, pin: code, accountID: account)
                let passcode = loginPIN.filter(\.isNumber)
                pairing.loginPIN = passcode.isEmpty ? nil : passcode
                paired = pairing
            } catch {
                self.error = (error as? ProviderError)?.message ?? error.localizedDescription
                showFailure = true
            }
            busy = false
        }
    }
}
#endif
