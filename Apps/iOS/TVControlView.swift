import LarCore
import SwiftUI

/// An Android TV / Google TV: pairing with the code it shows (once), then power, the directional pad, back, home,
/// play/pause, volume and the apps.
struct TVControlView: View {
    var home: HomeStore
    var deviceID: String

    @State private var apps: [AndroidTVProvider.App] = []
    @State private var text = ""

    private var device: HomeDevice? { home.device(id: deviceID) }
    private var isOn: Bool { device?.isOn == true && device?.isOnline == true }
    private var needsPairing: Bool { device?.controls["pairable"] == "1" && device?.controls["link"] != "remote" }

    var body: some View {
        Form {
            if let device {
                if needsPairing {
                    TVPairingSection(home: home, deviceID: deviceID)
                } else {
                    Section {
                        powerButton(device)
                    } footer: {
                        Text("\(Labels.subtitle(device)). Desligar tira a TV da rede: se ela não ligar pelo Lar, use o controle.")
                    }
                    Section { remote }
                        .disabled(!isOn)
                    if device.canType { Section {
                        HStack {
                            TextField("Digitar na TV", text: $text)
                                .submitLabel(.send)
                                .onSubmit(sendText)
                            Button("Enviar", action: sendText)
                                .disabled(text.isEmpty)
                        }
                    } footer: {
                        Text("Abra a busca ou um campo de texto na TV e digite aqui.")
                    }
                    .disabled(!isOn) }
                    if !apps.isEmpty {
                        Section("Apps") { appGrid }
                            .disabled(!isOn)
                    }
                }
            }
        }
        .navigationTitle(device?.name ?? "TV")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: needsPairing) {
            guard !needsPairing else { return }
            apps = await home.tvApps(on: deviceID)
        }
    }

    /// The remote's power key: turns the TV off, or on while it's still on the network.
    private func powerButton(_ device: HomeDevice) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            home.perform(.power(!isOn), on: deviceID)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "power")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isOn ? Color.white : Color.red)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(isOn ? Color.red : Color.red.opacity(0.15)))
                Text(isOn ? "Desligar" : "Ligar")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.canSwitch)
        .accessibilityLabel(isOn ? "Desligar a TV" : "Ligar a TV")
    }

    private var remote: some View {
        VStack(spacing: 22) {
            if device?.hasDirectionalPad != false { dPad }
            HStack(spacing: 18) {
                round("arrow.uturn.backward", "Voltar", .back)
                round("house", "Início", .home)
                round("playpause.fill", "Tocar ou pausar", .playPause)
                round("rectangle.on.rectangle", "Entradas", .inputs)
            }
            HStack(spacing: 0) {
                volumeButton("speaker.minus.fill", "Diminuir volume", .volumeDown)
                volumeButton("speaker.slash.fill", "Sem som", .mute)
                volumeButton("speaker.plus.fill", "Aumentar volume", .volumeUp)
            }
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            if device?.hasChannels != false {
                HStack(spacing: 0) {
                    volumeButton("chevron.down", "Canal anterior", .channelDown)
                    Text("CH").font(.footnote.weight(.semibold)).frame(width: 40)
                    volumeButton("chevron.up", "Próximo canal", .channelUp)
                }
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if let level = device?.controls["volume"], let max = device?.controls["maxVolume"] {
                Text(level == "0" ? "Sem som" : "Volume \(level) de \(max)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .opacity(isOn ? 1 : 0.4)
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        home.typeOnTV(text, on: deviceID)
        text = ""
    }

    private var dPad: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.15)).frame(width: 210, height: 210)
            VStack(spacing: 0) {
                arrow("chevron.up", .up)
                HStack(spacing: 0) {
                    arrow("chevron.left", .left)
                    Button { press(.select) } label: {
                        Text("OK")
                            .font(.headline)
                            .frame(width: 78, height: 78)
                            .background(Circle().fill(Color.secondary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    arrow("chevron.right", .right)
                }
                arrow("chevron.down", .down)
            }
        }
    }

    private func press(_ key: AndroidTVProvider.Key) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        home.press(key, on: deviceID)
    }

    private func arrow(_ symbol: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func round(_ symbol: String, _ title: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func volumeButton(_ symbol: String, _ title: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol)
                .frame(width: 72, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var appGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(apps.prefix(12)) { app in
                Button { home.openApp(app.package, on: deviceID) } label: {
                    Text(app.name)
                        .font(.footnote)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(
                            device?.controls["app"] == app.package ? 0.3 : 0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pairing: the TV shows a 6-symbol code, typed here. Only once per TV.
struct TVPairingSection: View {
    var home: HomeStore
    var deviceID: String

    @State private var step = Step.idle
    @State private var code = ""
    @State private var message: String?
    @FocusState private var codeFocused: Bool

    enum Step { case idle, starting, waitingCode, sending }

    var body: some View {
        Section {
            switch step {
            case .idle, .starting:
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        Text("Parear com a TV")
                        if step == .starting { Spacer(); ProgressView() }
                    }
                }
                .disabled(step == .starting)
            case .waitingCode, .sending:
                TextField("Código da TV", text: $code)
                    .font(.title2.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($codeFocused)
                    .onChange(of: code) { _, new in code = String(new.uppercased().filter(\.isHexDigit).prefix(6)) }
                    .onSubmit { Task { await finish() } }
                Button {
                    Task { await finish() }
                } label: {
                    HStack {
                        Text("Confirmar")
                        if step == .sending { Spacer(); ProgressView() }
                    }
                }
                .disabled(code.count != 6 || step == .sending)
                Button("Mostrar outro código") { Task { await start() } }
                    .disabled(step == .sending)
            }
        } header: {
            Text("Parear")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let message { Text(message).foregroundStyle(.orange) }
                Text(step == .idle || step == .starting
                     ? "A TV precisa estar ligada. Ela vai mostrar um código de 6 letras e números: digite aqui. É só uma vez, e não precisa ligar nada nas configurações da TV."
                     : "Digite o código que apareceu na tela da TV.")
            }
        }
        .onDisappear { if step != .idle { home.cancelTVPairing(deviceID) } }
    }

    private func start() async {
        step = .starting
        message = nil
        code = ""
        if let error = await home.startTVPairing(deviceID) {
            message = error
            step = .idle
        } else {
            step = .waitingCode
            codeFocused = true
        }
    }

    private func finish() async {
        guard code.count == 6, step == .waitingCode else { return }
        step = .sending
        message = nil
        if let error = await home.finishTVPairing(deviceID, code: code) {
            message = error
            step = .waitingCode
        } else {
            step = .idle
        }
    }
}
