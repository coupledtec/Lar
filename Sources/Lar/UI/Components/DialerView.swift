import LarCore
import SwiftUI

/// The phone's dial pad: type a number (or extension) and call; a shortcut to the intercom; the registration's
/// state. The same view on the Mac and on the iPhone.
struct DialerView: View {
    var phone: PhoneStore
    /// Opens Settings → Porteiro (when the account isn't set up yet).
    var onSettings: () -> Void
    /// After a call starts (the iPhone closes the dial pad; the call shows full screen).
    var onCall: () -> Void = {}

    @State private var number = ""

    private static let keys = [("1", ""), ("2", "ABC"), ("3", "DEF"), ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
                               ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"), ("*", ""), ("0", "+"), ("#", "")]

    var body: some View {
        VStack(spacing: 14) {
            status
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 18), count: 3), spacing: 12) {
                ForEach(Self.keys, id: \.0) { key, letters in
                    Button { number.append(key) } label: {
                        VStack(spacing: 0) {
                            Text(key).font(.system(size: 26))
                            Text(letters).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.secondary.opacity(0.18)))
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 30) {
                Button { call(phone.settings.doorNumber) } label: {
                    Label("Porteiro", systemImage: "bell.and.waves.left.and.right").labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .disabled(phone.settings.doorNumber.isEmpty || !ready)
                .help("Ligar para o porteiro")
                .accessibilityLabel("Ligar para o porteiro")
                Button { call(number) } label: {
                    Image(systemName: "phone.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(Circle().fill(Color.green))
                }
                .buttonStyle(.plain)
                .disabled(number.isEmpty || !ready)
                .opacity(number.isEmpty || !ready ? 0.5 : 1)
                .accessibilityLabel("Ligar")
                Button { if !number.isEmpty { number.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title3).frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .opacity(number.isEmpty ? 0 : 1)
                .accessibilityLabel("Apagar")
            }
        }
        .padding(.vertical, 8)
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            let typed = press.characters.filter { "0123456789*#".contains($0) }
            if !typed.isEmpty { number += typed; return .handled }
            if press.key == .delete, !number.isEmpty { number.removeLast(); return .handled }
            if press.key == .return, !number.isEmpty, ready { call(number); return .handled }
            return .ignored
        }
        #endif
    }

    private var ready: Bool { phone.registration == .registered }

    @ViewBuilder
    private var status: some View {
        if !phone.isConfigured {
            VStack(spacing: 6) {
                Text("Configure o servidor SIP (usuário, senha e o número do porteiro) para ligar e atender.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Abrir Ajustes → Porteiro", action: onSettings)
                    .font(.footnote)
            }
        } else {
            switch phone.registration {
            case .registered: Label("Registrado", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
            case .registering: Label("Registrando…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).font(.footnote)
            case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
            case .off: Label("Desligado", systemImage: "phone.down").foregroundStyle(.secondary).font(.footnote)
            }
        }
    }

    private func call(_ target: String) {
        guard !target.isEmpty else { return }
        Task { await phone.dial(target) }
        number = ""
        onCall()
    }
}
