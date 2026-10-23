import LarCore
import SwiftUI

/// A call with the intercom (or any number): who it is and how long it's been, answer or decline, open the gate,
/// mute, keypad, hang up. The same view on the Mac (in a window) and on the iPhone (full screen).
struct CallView: View {
    var phone: PhoneStore
    var call: PhoneCall

    @State private var showsKeypad = false

    private var isActive: Bool { if case .active = call.state { true } else { false } }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            Image(systemName: call.name == "Porteiro" || !call.isOutgoing ? "bell.and.waves.left.and.right.fill" : "phone.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: call.state == .incoming || call.state == .ringing)
            Text(call.name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            status
                .font(.callout)
                .foregroundStyle(.secondary)
            if showsKeypad, isActive { keypad }
            Spacer(minLength: 8)
            controls
        }
        .padding(24)
        .frame(minWidth: 280, minHeight: 360)
    }

    @ViewBuilder
    private var status: some View {
        switch call.state {
        case .incoming: Text("Chamando…")
        case .dialing: Text("Ligando…")
        case .ringing: Text("Tocando…")
        case .active(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(since))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
            }
        case .ended(let reason): Text(reason)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch call.state {
        case .incoming:
            HStack(spacing: 40) {
                round("phone.down.fill", "Recusar", .red) { Task { await phone.decline() } }
                round("phone.fill", "Atender", .green) { Task { await phone.answer() } }
            }
        case .active:
            VStack(spacing: 18) {
                if !phone.settings.doorCode.isEmpty {
                    Button { Task { await phone.openDoor() } } label: {
                        Label("Abrir portão", systemImage: "door.left.hand.open")
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 28) {
                    round(phone.isMuted ? "mic.slash.fill" : "mic.fill", phone.isMuted ? "Com som" : "Mudo",
                          phone.isMuted ? .orange : .secondary) { phone.isMuted.toggle() }
                    round("circle.grid.3x3.fill", "Teclado", showsKeypad ? .accentColor : .secondary) { showsKeypad.toggle() }
                    round("phone.down.fill", "Desligar", .red) { Task { await phone.hangup() } }
                }
            }
        case .dialing, .ringing:
            round("phone.down.fill", "Desligar", .red) { Task { await phone.hangup() } }
        case .ended:
            EmptyView()
        }
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 12), count: 3), spacing: 10) {
            ForEach(keys, id: \.self) { key in
                Button { Task { await phone.sendKeys(key) } } label: {
                    Text(key)
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.secondary.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func round(_ symbol: String, _ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(color))
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
