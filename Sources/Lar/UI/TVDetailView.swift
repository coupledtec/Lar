import LarCore
import SwiftUI

/// The TV's remote: power, the directional pad (also the Mac's arrow keys and Return), back, home, play/pause,
/// volume and the TV's apps.
struct TVDetailView: View {
    var home: HomeStore
    var deviceID: String
    var onBack: () -> Void

    @State private var apps: [AndroidTVProvider.App] = []
    @State private var text = ""
    @FocusState private var focused: Bool

    private var device: HomeDevice? { home.device(id: deviceID) }
    private var isOn: Bool { device?.isOn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if device?.controls["pairable"] == "1", device?.controls["link"] != "remote" {
                TVPairingRow(home: home, deviceID: deviceID, required: device?.isOn == nil)
                Divider()
            }
            HStack(alignment: .center, spacing: 18) {
                if device?.hasDirectionalPad != false {
                    dPad
                        .disabled(!isOn)
                        .opacity(isOn ? 1 : Theme.disabledOpacity)
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        powerButton
                        round("arrow.uturn.backward", "Voltar", .back)
                        round("house", "Início", .home)
                    }
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 38, height: 38)
                        round("playpause.fill", "Tocar ou pausar", .playPause)
                        round("rectangle.on.rectangle", "Entradas", .inputs)
                    }
                    volume
                    if device?.hasChannels != false { channel }
                    if let level = device?.controls["volume"], let max = device?.controls["maxVolume"] {
                        Text(level == "0" ? "Sem som" : "Volume \(level) de \(max)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if device?.canType != false { HStack(spacing: 6) {
                TextField("Digitar na TV (busca aberta)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(sendText)
                Button("Enviar", action: sendText)
                    .disabled(text.isEmpty)
            }
            .disabled(!isOn)
            .opacity(isOn ? 1 : Theme.disabledOpacity) }
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

    /// The remote's power key, the one control that works with the TV off (while it's still on the network).
    private var powerButton: some View {
        Button { home.perform(.power(!isOn), on: deviceID) } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.red)
                .frame(width: 38, height: 38)
                .background(Circle().fill(isOn ? Color.red.opacity(0.85) : Color.red.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(device?.canSwitch != true)
        .help(isOn ? "Desligar" : "Ligar")
        .accessibilityLabel(isOn ? "Desligar a TV" : "Ligar a TV")
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
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }

    private var volume: some View {
        HStack(spacing: 0) {
            volumeButton("speaker.minus.fill", "Diminuir volume", .volumeDown)
            volumeButton("speaker.slash.fill", "Sem som", .mute)
            volumeButton("speaker.plus.fill", "Aumentar volume", .volumeUp)
        }
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        home.typeOnTV(text, on: deviceID)
        text = ""
        focused = true
    }

    private var channel: some View {
        HStack(spacing: 0) {
            volumeButton("chevron.down", "Canal anterior", .channelDown)
            Text("CH")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 29)
            volumeButton("chevron.up", "Próximo canal", .channelUp)
        }
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
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

/// Pairing by the code the TV shows (Google TV remote protocol): the way in without debugging on the TV. Offered on
/// every TV not paired yet; the main way when ADB doesn't answer.
private struct TVPairingRow: View {
    var home: HomeStore
    var deviceID: String
    var required: Bool

    @State private var waitingCode = false
    @State private var busy = false
    @State private var code = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if waitingCode {
                HStack(spacing: 8) {
                    TextField("Código da TV", text: $code)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onChange(of: code) { _, new in code = String(new.uppercased().filter(\.isHexDigit).prefix(6)) }
                        .onSubmit { Task { await finish() } }
                    Button("Confirmar") { Task { await finish() } }
                        .disabled(code.count != 6 || busy)
                    Button("Cancelar") {
                        home.cancelTVPairing(deviceID)
                        waitingCode = false
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                Text("Digite o código de 6 letras e números que apareceu na TV.")
            } else {
                HStack(spacing: 8) {
                    Button(required ? "Parear com a TV" : "Parear sem depuração") { Task { await start() } }
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(required
                     ? "A TV não respondeu pelo ADB (depuração desligada ou não aprovada). Pareando, ela mostra um código e o Lar passa a usar o controle do Google TV, sem depuração."
                     : "Pareando com o código que a TV mostra, o Lar usa o controle do Google TV e a depuração pode ser desligada.")
            }
            if let message { Text(message).foregroundStyle(.orange) }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondaryText)
    }

    private func start() async {
        busy = true
        message = nil
        code = ""
        message = await home.startTVPairing(deviceID)
        waitingCode = message == nil
        busy = false
    }

    private func finish() async {
        guard code.count == 6, !busy else { return }
        busy = true
        message = await home.finishTVPairing(deviceID, code: code)
        if message == nil { waitingCode = false }
        busy = false
    }
}
