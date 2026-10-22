import LarCore
import SwiftUI

/// The TV's remote: power, the directional pad (also the Mac's arrow keys and Return), back, home, play/pause,
/// volume and the TV's apps.
struct TVDetailView: View {
    var home: HomeStore
    var deviceID: String
    var onBack: () -> Void

    @State private var apps: [AndroidTVProvider.App] = []
    @FocusState private var focused: Bool

    private var device: HomeDevice? { home.device(id: deviceID) }
    private var isOn: Bool { device?.isOn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            HStack(alignment: .center, spacing: 18) {
                dPad
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        round("arrow.uturn.backward", "Voltar", .back)
                        round("house", "Início", .home)
                    }
                    HStack(spacing: 10) {
                        round("playpause.fill", "Tocar ou pausar", .playPause)
                        round("rectangle.on.rectangle", "Entradas", .inputs)
                    }
                    volume
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!isOn)
            .opacity(isOn ? 1 : Theme.disabledOpacity)
            if !apps.isEmpty {
                Divider()
                appGrid
            }
            Text("As setas e o Enter do teclado também funcionam aqui. Desligar tira a TV da rede: se ela não ligar pelo Lar, use o controle.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { press(.up) }
        .onKeyPress(.downArrow) { press(.down) }
        .onKeyPress(.leftArrow) { press(.left) }
        .onKeyPress(.rightArrow) { press(.right) }
        .onKeyPress(.return) { press(.select) }
        .onKeyPress(.space) { press(.playPause) }
        .onKeyPress(.delete) { press(.back) }
        .task {
            focused = true
            apps = await home.tvApps(on: deviceID)
        }
    }

    private func press(_ key: AndroidTVProvider.Key) -> KeyPress.Result {
        guard isOn else { return .ignored }
        home.press(key, on: deviceID)
        return .handled
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text(device?.name ?? "TV")
                    .font(.system(size: 13, weight: .semibold))
                if let device {
                    Text(Labels.subtitle(device))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.interpolate)
                }
            }
            Spacer()
            Toggle("Ligar", isOn: Binding(get: { isOn }, set: { home.perform(.power($0), on: deviceID) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(device?.canSwitch != true)
        }
    }

    private var dPad: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08)).frame(width: 132, height: 132)
            VStack(spacing: 0) {
                arrow("chevron.up", .up)
                HStack(spacing: 0) {
                    arrow("chevron.left", .left)
                    Button { home.press(.select, on: deviceID) } label: {
                        Text("OK")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 50, height: 50)
                            .background(Circle().fill(Color.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("OK")
                    arrow("chevron.right", .right)
                }
                arrow("chevron.down", .down)
            }
        }
    }

    private func arrow(_ symbol: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { home.press(key, on: deviceID) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func round(_ symbol: String, _ title: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { home.press(key, on: deviceID) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var volume: some View {
        HStack(spacing: 0) {
            volumeButton("speaker.minus.fill", "Diminuir volume", .volumeDown)
            volumeButton("speaker.slash.fill", "Sem som", .mute)
            volumeButton("speaker.plus.fill", "Aumentar volume", .volumeUp)
        }
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private func volumeButton(_ symbol: String, _ title: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { home.press(key, on: deviceID) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 29, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var appGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(apps.prefix(12)) { app in
                    Button { home.openApp(app.package, on: deviceID) } label: {
                        Text(app.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(
                                device?.controls["app"] == app.package ? 0.22 : 0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }
}
