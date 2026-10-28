import Foundation

/// How an account's reads have been going: for the Diagnostics screen and its report.
public struct AccountHealth: Sendable, Equatable {
    public var lastRead: Date?
    public var duration: Duration?
    public var deviceCount = 0
    public var lastError: String?
    public var lastErrorAt: Date?

    public init() {}
}

extension HomeStore {
    /// A plain-text report of the accounts' state, safe to share: no keys, no tokens, no device names.
    public func diagnosticsReport(app: String, version: String, pairedTVs: Int, sharedKeychain: Bool, now: Date = Date()) -> String {
        var lines = ["Lar \(version) · \(app)", "Gerado em \(now.formatted(date: .numeric, time: .standard))", ""]
        for provider in Provider.available {
            let state: String = switch accounts[provider] ?? .notConfigured {
            case .notConfigured: tr("não configurada")
            case .loading: tr("conectando")
            case .connected: tr("conectada")
            case .unauthorized: "chave recusada"
            case .failed(let message): "falhou (\(message))"
            }
            var line = "\(provider.name): \(state)"
            if let entry = health[provider] {
                line += " · \(entry.deviceCount) aparelhos"
                if let duration = entry.duration { line += " · leitura em \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" }
                if let error = entry.lastError, let at = entry.lastErrorAt {
                    line += " · último erro \(at.formatted(date: .omitted, time: .shortened)): \(error)"
                }
            }
            lines.append(line)
        }
        lines += ["", "TVs pareadas: \(pairedTVs)", "Porta-chaves compartilhado: \(sharedKeychain ? "sim" : "não")",
                  "Aparelhos na lista: \(devices.count), online: \(devices.filter(\.isOnline).count)"]
        // Locks and robots: how the brand reports their state (codes and values only), to map it.
        let raw = devices.filter { $0.controls["tuyaStatus"] != nil }
        if !raw.isEmpty {
            lines += ["", "Fechaduras e robôs (Smart Life):"]
            lines += raw.map { "\(Labels.kindTitle($0.kind)) [\($0.controls["tuyaCategory"] ?? "?")]: \($0.controls["tuyaStatus"] ?? "")" }
        }
        return lines.joined(separator: "\n")
    }
}
