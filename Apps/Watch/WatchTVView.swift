import LarCore
import SwiftUI
import WatchKit

/// A TV on the wrist, through the iPhone: power, the directional pad, back, home, play/pause and volume, and the apps.
struct WatchTVView: View {
    var home: HomeStore
    var deviceID: String

    @State private var apps: [AndroidTVProvider.App] = []
    @State private var text = ""

    private var device: HomeDevice? { home.device(id: deviceID) }
    private var isOn: Bool { device?.isOn == true && device?.isOnline == true }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button {
                    home.perform(.power(!isOn), on: deviceID)
                } label: {
                    Label(isOn ? "Desligar" : "Ligar", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(device?.canSwitch != true)
                if let device {
                    Text(Labels.subtitle(device))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Group {
                    if device?.hasDirectionalPad != false { dPad }
                    HStack {
                        key("arrow.uturn.backward", "Voltar", .back)
                        key("house", "Início", .home)
                        key("playpause.fill", "Tocar ou pausar", .playPause)
                    }
                    HStack {
                        key("speaker.minus.fill", "Diminuir volume", .volumeDown)
                        key("speaker.slash.fill", "Sem som", .mute)
                        key("speaker.plus.fill", "Aumentar volume", .volumeUp)
                    }
                    if let level = device?.controls["volume"], let max = device?.controls["maxVolume"] {
                        Text(level == "0" ? "Sem som" : "Volume \(level) de \(max)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if device?.hasChannels != false {
                        HStack {
                            key("chevron.down", "Canal anterior", .channelDown)
                            Text("CH").font(.footnote)
                            key("chevron.up", "Próximo canal", .channelUp)
                        }
                    }
                    if device?.canType != false {
                        // Dictation or the keyboard, into the TV's search.
                        TextField("Digitar na TV", text: $text)
                            .onSubmit {
                                guard !text.isEmpty else { return }
                                home.typeOnTV(text, on: deviceID)
                                text = ""
                            }
                    }
                    ForEach(apps.prefix(8)) { app in
                        Button(app.name) { home.openApp(app.package, on: deviceID) }
                    }
                }
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.4)
            }
        }
        .navigationTitle(device?.name ?? "TV")
        .task { apps = await home.tvApps(on: deviceID) }
    }

    private var dPad: some View {
        VStack(spacing: 2) {
            key("chevron.up", "Para cima", .up)
            HStack(spacing: 2) {
                key("chevron.left", "Para a esquerda", .left)
                Button("OK") { press(.select) }
                    .font(.headline)
                key("chevron.right", "Para a direita", .right)
            }
            key("chevron.down", "Para baixo", .down)
        }
    }

    private func key(_ symbol: String, _ title: String, _ key: AndroidTVProvider.Key) -> some View {
        Button { press(key) } label: { Image(systemName: symbol) }
            .accessibilityLabel(title)
    }

    private func press(_ key: AndroidTVProvider.Key) {
        WKInterfaceDevice.current().play(.click)
        home.press(key, on: deviceID)
    }
}
