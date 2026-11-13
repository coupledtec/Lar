import LarCore
import SwiftUI

/// An Echo: volume, Do Not Disturb, the music, speaking or announcing a text, asking Alexa anything (which reaches
/// whatever Alexa controls) and the account's routines. The same on the Mac and the iPhone.
struct EchoControlView: View {
    var home: HomeStore
    var deviceID: String

    @State private var say = ""
    @State private var ask = ""
    @State private var routines: [AlexaRoutine] = []
    @State private var routinePage = 0
    @State private var routineSearch = ""
    @State private var status: String?
    @State private var notifications: [AlexaNotification] = []
    @State private var timer = ""
    @State private var item = ""
    @State private var working = false

    private var device: HomeDevice? { home.device(id: deviceID) }

    var body: some View {
        Form {
            if let device, let echo = device.echo, let alexa = home.alexa {
                Section {
                    let volume = Int(device.controls["volume"] ?? "") ?? 0
                    Stepper("Volume \(volume)", value: Binding(get: { volume }, set: { value in
                        act(alexa) { try await $0.setVolume(value, on: echo) }
                    }), in: 0...100, step: 10)
                    Toggle("Não perturbe", isOn: Binding(get: { device.controls["dnd"] == "1" }, set: { on in
                        act(alexa) { try await $0.setDoNotDisturb(on, on: echo) }
                    }))
                    HStack(spacing: 24) {
                        mediaButton("backward.fill", "Anterior") { act(alexa) { try await $0.media(.previous, on: echo) } }
                        mediaButton("play.fill", "Tocar") { act(alexa) { try await $0.media(.play, on: echo) } }
                        mediaButton("pause.fill", "Pausar") { act(alexa) { try await $0.media(.pause, on: echo) } }
                        mediaButton("forward.fill", "Próxima") { act(alexa) { try await $0.media(.next, on: echo) } }
                    }
                    .frame(maxWidth: .infinity)
                }
                Section("Falar") {
                    TextField("O que dizer", text: $say)
                    HStack {
                        Button("Falar neste Echo") {
                            let text = say
                            act(alexa) { try await $0.speak(text, on: echo) }
                        }
                        Spacer()
                        Button("Anunciar em todos") {
                            let text = say, all = home.echos
                            act(alexa) { try await $0.announce(text, on: all.isEmpty ? [echo] : all) }
                        }
                    }
                    .disabled(say.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    #if os(iOS) || os(visionOS)
                    .buttonStyle(.borderless)
                    #endif
                }
                Section {
                    ForEach(notifications.filter { $0.serial == echo.serial }) { note in
                        Label(note.text, systemImage: note.kind == .timer ? "timer" : note.kind == .alarm ? "alarm" : "bell")
                    }
                    TextField("Ex.: 10 minutos, 7 da manhã", text: $timer)
                    HStack {
                        Button("Timer") {
                            let text = String(localized: "timer de \(timer)")
                            act(alexa) { try await $0.command(text, on: echo) }
                            timer = ""
                        }
                        Spacer()
                        Button("Alarme") {
                            let text = String(localized: "alarme para \(timer)")
                            act(alexa) { try await $0.command(text, on: echo) }
                            timer = ""
                        }
                        Spacer()
                        Button("Cancelar timers") {
                            act(alexa) { try await $0.command(String(localized: "cancele todos os timers"), on: echo) }
                        }
                    }
                    .disabled(working)
                    #if os(iOS) || os(visionOS)
                    .buttonStyle(.borderless)
                    #endif
                } header: {
                    Text("Timers e alarmes")
                }
                Section {
                    TextField("Ex.: café", text: $item)
                    HStack {
                        Button("Lista de compras") {
                            let text = String(localized: "adicione \(item) à lista de compras")
                            act(alexa) { try await $0.command(text, on: echo) }
                            item = ""
                        }
                        Spacer()
                        Button("Lista de tarefas") {
                            let text = String(localized: "adicione \(item) à lista de tarefas")
                            act(alexa) { try await $0.command(text, on: echo) }
                            item = ""
                        }
                    }
                    .disabled(item.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    #if os(iOS) || os(visionOS)
                    .buttonStyle(.borderless)
                    #endif
                } header: {
                    Text("Listas da Alexa")
                }
                Section {
                    TextField("Ex.: apague a luz da sala", text: $ask)
                    Button("Pedir à Alexa") {
                        let text = ask
                        act(alexa) { try await $0.command(text, on: echo) }
                    }
                    .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty || working)
                } header: {
                    Text("Pedir à Alexa")
                } footer: {
                    Text("Como se fosse dito a este Echo: vale para tudo o que a Alexa controla.")
                }
                if !routines.isEmpty {
                    // Many routines: a search and eight a page.
                    let found = routineSearch.isEmpty ? routines
                        : routines.filter { $0.name.localizedStandardContains(routineSearch) }
                    let paged = Paged(found, page: routinePage, size: 8)
                    Section("Rotinas da Alexa (\(routines.count))") {
                        if routines.count > 8 {
                            TextField("Buscar rotina", text: $routineSearch)
                                .onChange(of: routineSearch) { _, _ in routinePage = 0 }
                        }
                        ForEach(paged.items, id: \.id) { routine in
                            Button(routine.name) { act(alexa) { try await $0.run(routine, on: echo) } }
                        }
                        PageControl(paged: paged, page: $routinePage)
                    }
                }
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Echo fora do ar ou conta da Alexa desconectada.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device?.name ?? "Echo")
        .task {
            guard let alexa = home.alexa else { return }
            routines = (try? await alexa.routines()) ?? []
            notifications = (try? await alexa.notifications()) ?? []
        }
    }

    private func mediaButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3) }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
            .disabled(working)
    }

    /// One call to the account, then a fresh read (volume and Do Not Disturb show what the Echo now has). The
    /// result shows for a moment (an error a bit longer), unless another one replaced it.
    private func act(_ alexa: AlexaClient, _ call: @escaping @Sendable (AlexaClient) async throws -> Void) {
        working = true
        status = nil
        Task {
            var shown: Duration = .seconds(3)
            do {
                try await call(alexa)
                status = "Enviado."
                home.refreshSoon()
                // A new timer or alarm shows once Alexa has it.
                try? await Task.sleep(for: .seconds(2))
                notifications = (try? await alexa.notifications()) ?? notifications
            } catch {
                status = (error as? ProviderError)?.message ?? error.localizedDescription
                shown = .seconds(8)
            }
            working = false
            let message = status
            try? await Task.sleep(for: shown)
            if status == message { status = nil }
        }
    }
}
