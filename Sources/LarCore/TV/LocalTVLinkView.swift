#if !os(watchOS)
import SwiftUI

/// On an LG TV from ThinQ or a Samsung TV from SmartThings: its full remote over the home network, paired once
/// (the TV asks on screen). The remote then appears on this same device.
public struct LocalTVLinkView: View {
    let device: HomeDevice
    let onLinked: () -> Void
    @State private var host = ""
    @State private var busy = false
    @State private var message: String?

    public init(device: HomeDevice, onLinked: @escaping () -> Void) {
        self.device = device
        self.onLinked = onLinked
    }

    private var kind: LocalTV.Kind { device.provider == .lg ? .lg : .samsung }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Controle completo pela rede", systemImage: "av.remote").font(.headline)
            Text("Setas, OK, voltar, início, volume, canais, entradas, apps e digitar, direto na TV. Na primeira vez, a TV pergunta na tela se aceita o Lar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Endereço da TV (ex.: 192.168.0.30)", text: $host)
                    #if os(iOS) || os(visionOS) || os(tvOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .autocorrectionDisabled()
                Button(busy ? "Aguardando a TV…" : "Ativar") { pair() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(kind == .lg
                 ? "O endereço está na TV em Configurações → Geral → Rede → Conexão (Wi-Fi ou cabo) → Configurações avançadas."
                 : "O endereço está na TV em Configurações → Geral → Rede → Status da rede → Configurações de IP.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.1)))
        #if os(macOS)
        .task {
            // The Mac finds it by itself when there's only one TV of the brand.
            let found = await LocalTVs.discover().filter { $0.value == kind }
            if host.isEmpty, found.count == 1, let only = found.keys.first { host = only }
        }
        #endif
    }

    private func pair() {
        let host = host.trimmingCharacters(in: .whitespaces)
        busy = true
        message = String(localized: "Aceite o pedido do Lar na tela da TV.")
        Task {
            do {
                _ = try await LocalTVs.pair(kind, host: host, linkedTo: device.id)
                message = nil
                onLinked()
            } catch {
                message = (error as? ProviderError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}
#endif
