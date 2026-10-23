import LarCore
import SwiftUI
import UIKit

/// Each account's state, how long its last read took and its last error; the TVs; a report to copy (no keys).
/// The Mac's Diagnostics screen.
struct DiagnosticsView: View {
    var model: LarModel

    @State private var copied = false

    private var home: HomeStore { model.home }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        Form {
            Section("Contas") {
                ForEach(Provider.allCases, id: \.self) { provider in
                    let health = home.health[provider]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            Text(stateText(home.accounts[provider])).foregroundStyle(.secondary)
                        }
                        if let health, let lastRead = health.lastRead {
                            Text("\(health.deviceCount) aparelhos · lido \(lastRead.formatted(.relative(presentation: .named)))"
                                 + (health.duration.map { " em \($0.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" } ?? ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let error = health?.lastError, let at = health?.lastErrorAt {
                            Text("Último erro \(at.formatted(.relative(presentation: .named))): \(error)")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                LabeledContent("TVs pareadas", value: "\(model.settings.pairedTVs.count)")
                LabeledContent("Porta-chaves compartilhado", value: Keychain.sharedGroup != nil ? "Sim" : "Não")
                LabeledContent("Versão", value: version)
            }
            Section {
                Button(copied ? "Copiado" : "Copiar relatório (sem chaves)") {
                    UIPasteboard.general.string = home.diagnosticsReport(
                        app: "iPhone", version: version, pairedTVs: model.settings.pairedTVs.count,
                        sharedKeychain: Keychain.sharedGroup != nil)
                    copied = true
                }
                Button("Ler as contas de novo") { Task { await home.refresh() } }
            }
        }
        .navigationTitle("Diagnóstico")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stateText(_ state: AccountState?) -> String {
        switch state ?? .notConfigured {
        case .notConfigured: "não configurada"
        case .loading: "conectando…"
        case .connected: "conectada"
        case .unauthorized: "chave recusada"
        case .failed: "sem resposta"
        }
    }
}
