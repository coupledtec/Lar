import AppKit
import LarCore
import SwiftUI

/// Each account's state, how long its last read took and its last error; the TVs; a report to copy (no keys).
struct DiagnosticsView: View {
    var model: AppModel
    var onBack: () -> Void

    @State private var copied = false

    private var home: HomeStore { model.home }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BackButton(action: onBack)
                Text("Diagnóstico").font(.system(size: 13, weight: .semibold))
                Spacer()
                if home.isRefreshing { ProgressView().controlSize(.mini) }
                Button("Ler de novo") { Task { await home.refresh() } }
                    .font(.system(size: 11))
            }
            Divider()
            ForEach(Provider.allCases, id: \.self) { provider in
                DiagnosticsRow(provider: provider, state: home.accounts[provider], health: home.health[provider])
            }
            Divider()
            Text("TVs pareadas pelo controle do Google TV: \(model.settings.pairedTVs.count)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text("Lar \(Self.version) · Mac")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Button(copied ? "Copiado" : "Copiar relatório (sem chaves)") {
                let report = home.diagnosticsReport(app: "Mac", version: Self.version,
                                                    pairedTVs: model.settings.pairedTVs.count, sharedKeychain: Keychain.sharedGroup != nil)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                copied = true
            }
            .font(.system(size: 11))
        }
    }
}

struct DiagnosticsRow: View {
    var provider: Provider
    var state: AccountState?
    var health: AccountHealth?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(provider.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(stateText).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            if let health, let lastRead = health.lastRead {
                Text("\(health.deviceCount) aparelhos · lido \(lastRead.formatted(.relative(presentation: .named)))"
                     + (health.duration.map { " em \($0.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" } ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let error = health?.lastError, let at = health?.lastErrorAt {
                Text("Último erro \(at.formatted(.relative(presentation: .named))): \(error)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var stateText: String {
        switch state ?? .notConfigured {
        case .notConfigured: "não configurada"
        case .loading: "conectando…"
        case .connected: "conectada"
        case .unauthorized: "chave recusada"
        case .failed: "sem resposta"
        }
    }

    private var color: Color {
        switch state ?? .notConfigured {
        case .connected: .green
        case .notConfigured: .gray
        case .loading: .yellow
        default: .orange
        }
    }
}
