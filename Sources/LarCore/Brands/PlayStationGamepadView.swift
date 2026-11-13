#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// The session behind the controller screen: one at a time, opened when the screen shows (waking the console if
/// it's resting) and closed when it goes away.
@MainActor
public final class PlayStationGamepad: ObservableObject {
    public static let shared = PlayStationGamepad()

    public enum Phase: Equatable {
        /// Not connected; `resting` says whether the console is in rest mode (nil: not known yet or not answering).
        case idle(resting: Bool?)
        case waking, connecting, ready, failed(String)
    }

    @Published public private(set) var phase = Phase.idle(resting: nil)
    /// The console's open text field (its current text), nil when none.
    @Published public var keyboard: String?

    /// Whether the console is on or resting, for the screen's button (never wakes it).
    public func check() {
        guard case .idle = phase, let pairing = PlayStationClient.savedPairing else { return }
        Task {
            let state = await PlayStationRemotePlay.state(host: pairing.host)
            guard case .idle = phase else { return }
            switch state {
            case .on?: phase = .idle(resting: false)
            case .standby?: phase = .idle(resting: true)
            case nil: phase = .idle(resting: nil)
            }
        }
    }
    private var session: PlayStationControllerSession?
    private var task: Task<Void, Never>?

    public func connect() {
        guard task == nil, session == nil || phase != .ready else { return }
        guard let pairing = PlayStationClient.savedPairing, pairing.canSleep else {
            phase = .failed(tr("Pareie o PS5 em Ajustes → Jogos → PlayStation para usar o controle."))
            return
        }
        task = Task {
            defer { task = nil }
            do {
                if case .standby? = await PlayStationRemotePlay.state(host: pairing.host) {
                    phase = .waking
                    try await PlayStationRemotePlay.wake(pairing)
                    var on = false
                    for _ in 0..<30 where !on {
                        try await Task.sleep(for: .seconds(1.5))
                        if case .on? = await PlayStationRemotePlay.state(host: pairing.host) { on = true }
                    }
                    guard on else { throw ProviderError.network(tr("O PS5 não ligou")) }
                    try await Task.sleep(for: .seconds(2))
                }
                phase = .connecting
                let session = try await PlayStationControllerSession.open(pairing) { status in
                    guard case .closed(let reason) = status else { return }
                    Task { @MainActor in
                        PlayStationGamepad.shared.session = nil
                        if PlayStationGamepad.shared.phase == .ready {
                            PlayStationGamepad.shared.phase = reason.map { .failed($0) } ?? .idle(resting: nil)
                        }
                    }
                }
                session.onKeyboard = { text in
                    Task { @MainActor in PlayStationGamepad.shared.keyboard = text }
                }
                self.session = session
                phase = .ready
            } catch {
                phase = .failed((error as? ProviderError)?.message ?? error.localizedDescription)
            }
        }
    }

    public func disconnect() {
        task?.cancel()
        task = nil
        session?.close()
        session = nil
        phase = .idle(resting: nil)
        check()
    }

    public func set(_ button: PlayStationRemotePlay.Button, pressed: Bool) { session?.set(button, pressed: pressed) }

    public func sticks(left: CGPoint, right: CGPoint) {
        session?.setSticks(left: (left.x, left.y), right: (right.x, right.y))
    }

    public func type(_ text: String) {
        session?.type(text)
        keyboard = nil
    }

    public func cancelKeyboard() {
        session?.cancelKeyboard()
        keyboard = nil
    }

    public func rest() {
        session?.send(.rest)
    }
}

/// A DualSense on the screen: the face buttons, the D-pad, the shoulders and triggers, Create, Options, PS, the
/// touchpad and both sticks (dragged; tapped for L3/R3). Buttons hold while touched.
public struct PlayStationGamepadView: View {
    let name: String
    /// A button's side: smaller in the Mac's menu bar panel (320 points wide).
    #if os(macOS)
    static let unit: CGFloat = 30
    static let stick: CGFloat = 70
    static let margin: CGFloat = 2
    #else
    static let unit: CGFloat = 40
    static let stick: CGFloat = 92
    static let margin: CGFloat = 14
    #endif
    @ObservedObject private var gamepad = PlayStationGamepad.shared
    @State private var left = CGPoint.zero
    @State private var right = CGPoint.zero
    @State private var text = ""

    public init(name: String) {
        self.name = name
    }

    public var body: some View {
        VStack(spacing: 14) {
            header
            if gamepad.keyboard != nil {
                HStack(spacing: 6) {
                    TextField("Texto para o PS5", text: $text)
                        #if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .onSubmit { gamepad.type(text) }
                    Button("Enviar") { gamepad.type(text) }.buttonStyle(.borderedProminent)
                    Button("Cancelar") { gamepad.cancelKeyboard() }
                }
                .onAppear { text = gamepad.keyboard ?? "" }
            }
            controls
                .disabled(gamepad.phase != .ready)
                .opacity(gamepad.phase == .ready ? 1 : 0.45)
        }
        .padding(Self.margin)
        .onChange(of: left) { _, _ in gamepad.sticks(left: left, right: right) }
        .onChange(of: right) { _, _ in gamepad.sticks(left: left, right: right) }
        .onAppear { gamepad.check() }
        .onDisappear { gamepad.disconnect() }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                pad(.l2, "L2", width: Self.unit + 12)
                pad(.l1, "L1", width: Self.unit + 12)
                Spacer()
                pad(.r1, "R1", width: Self.unit + 12)
                pad(.r2, "R2", width: Self.unit + 12)
            }
            HStack(spacing: 10) {
                pad(.create, Image(systemName: "square.and.arrow.up"), width: Self.unit)
                pad(.touchpad, Text("Touchpad").font(.caption), width: nil)
                pad(.options, Image(systemName: "line.3.horizontal"), width: Self.unit)
            }
            HStack(alignment: .center) {
                cross(up: .up, down: .down, left: .left, right: .right) { button in
                    Image(systemName: "arrowtriangle.\(direction(button)).fill")
                }
                Spacer(minLength: 8)
                pad(.ps, Image(systemName: "playstation.logo").font(.title3), width: Self.unit + 6, round: true)
                Spacer(minLength: 8)
                cross(up: .triangle, down: .cross, left: .square, right: .circle) { button in
                    Image(systemName: faceSymbol(button)).foregroundStyle(faceColor(button))
                }
            }
            HStack {
                StickView(value: $left, size: Self.stick, onTap: { tap(.l3) })
                Spacer()
                StickView(value: $right, size: Self.stick, onTap: { tap(.r3) })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.footnote).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if case .failed = gamepad.phase {
                Button("Tentar de novo") { gamepad.connect() }.font(.footnote)
            } else if case .idle(let resting) = gamepad.phase {
                // Never on its own: opening the screen doesn't turn the console on or take it from another player.
                Button(resting == true ? "Ligar e conectar" : "Conectar") { gamepad.connect() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
            } else if gamepad.phase == .ready {
                Button("Desconectar") { gamepad.disconnect() }.font(.footnote)
            }
        }
        .allowsHitTesting(true)
    }

    private var statusText: String {
        switch gamepad.phase {
        case .idle(let resting): resting == true ? tr("\(name) em repouso") : resting == false ? tr("\(name) ligado") : tr("Desconectado")
        case .waking: tr("Ligando o \(name)…")
        case .connecting: tr("Conectando ao \(name)…")
        case .ready: tr("Controle conectado ao \(name)")
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch gamepad.phase {
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func tap(_ button: PlayStationRemotePlay.Button) {
        gamepad.set(button, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { gamepad.set(button, pressed: false) }
    }

    private func direction(_ button: PlayStationRemotePlay.Button) -> String {
        switch button {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        default: "right"
        }
    }

    private func faceSymbol(_ button: PlayStationRemotePlay.Button) -> String {
        switch button {
        case .triangle: "triangle"
        case .circle: "circle"
        case .square: "square"
        default: "xmark"
        }
    }

    private func faceColor(_ button: PlayStationRemotePlay.Button) -> Color {
        switch button {
        case .triangle: .green
        case .circle: .red
        case .square: .pink
        default: .blue
        }
    }

    /// Four buttons in a cross.
    private func cross(up: PlayStationRemotePlay.Button, down: PlayStationRemotePlay.Button, left: PlayStationRemotePlay.Button,
                       right: PlayStationRemotePlay.Button, @ViewBuilder label: @escaping (PlayStationRemotePlay.Button) -> some View) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: Self.unit, height: Self.unit)
                pad(up, label(up), width: Self.unit, round: true)
                Color.clear.frame(width: Self.unit, height: Self.unit)
            }
            GridRow {
                pad(left, label(left), width: Self.unit, round: true)
                Color.clear.frame(width: Self.unit, height: Self.unit)
                pad(right, label(right), width: Self.unit, round: true)
            }
            GridRow {
                Color.clear.frame(width: Self.unit, height: Self.unit)
                pad(down, label(down), width: Self.unit, round: true)
                Color.clear.frame(width: Self.unit, height: Self.unit)
            }
        }
    }

    private func pad(_ button: PlayStationRemotePlay.Button, _ title: String, width: CGFloat?) -> some View {
        pad(button, Text(title).font(.caption.weight(.semibold)), width: width)
    }

    private func pad(_ button: PlayStationRemotePlay.Button, _ label: some View, width: CGFloat?, round: Bool = false) -> some View {
        PadButton(label: label, width: width, round: round) { pressed in gamepad.set(button, pressed: pressed) }
    }
}

/// A button that holds while touched (or clicked), as a controller's does.
private struct PadButton<Label: View>: View {
    let label: Label
    let width: CGFloat?
    let round: Bool
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        label
            .frame(width: width, height: round ? width : PlayStationGamepadView.unit - 6)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: round ? (width ?? 40) / 2 : 9, style: .continuous)
                    .fill(Color.secondary.opacity(pressed ? 0.45 : 0.18))
            )
            .scaleEffect(pressed ? 0.94 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onChange(true)
                    }
                    .onEnded { _ in
                        pressed = false
                        onChange(false)
                    }
            )
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// A stick: dragged within its circle (−1…1 on each axis, up negative), back to the center when let go; a tap
/// without moving presses it (L3/R3).
private struct StickView: View {
    @Binding var value: CGPoint
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.15))
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: size * 0.42, height: size * 0.42)
                .offset(x: value.x * size * 0.29, y: value.y * size * 0.29)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let radius = size / 2
                    var x = drag.translation.width / radius
                    var y = drag.translation.height / radius
                    let length = (x * x + y * y).squareRoot()
                    if length > 1 { x /= length; y /= length }
                    value = CGPoint(x: x, y: y)
                }
                .onEnded { drag in
                    value = .zero
                    if abs(drag.translation.width) < 4, abs(drag.translation.height) < 4 { onTap() }
                }
        )
    }
}
#endif
