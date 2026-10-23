import AudioToolbox
import LarCore
import SwiftUI

/// The device list, grouped by kind, like the Mac's popover; tapping the round button switches a device, and LG air
/// conditioners and dimmable lights open their own screen.
struct HomeListView: View {
    var model: LarModel
    var link: WatchLink
    var phone: PhoneStore

    @State private var showingSettings = false
    @State private var showingDialer = false
    /// The scene being made (nil id) or changed.
    @State private var editingScene: SceneEditing?
    @State private var editingDevice: DeviceEditing?

    private var home: HomeStore { model.home }

    var body: some View {
        NavigationStack {
            List {
                if let problem = problemLine {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                scenesSection
                ForEach(home.sections(grouping: home.grouping)) { section in
                    Section(section.title) {
                        ForEach(section.devices) { device in
                            row(device)
                                .contextMenu { deviceMenu(device) }
                        }
                    }
                }
            }
            .overlay { emptyState }
            .refreshable { await home.refresh() }
            .navigationTitle(home.switchedOnCount > 0 ? "Lar · \(home.switchedOnCount) \(home.switchedOnCount == 1 ? "ligado" : "ligados")" : "Lar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { if await SettingsLock.unlock() { showingSettings = true } }
                    } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Ajustes")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingDialer = true } label: {
                        Image(systemName: "phone")
                            .foregroundStyle(!phone.isConfigured || phone.registration == .registered ? Color.accentColor : .orange)
                    }
                    .accessibilityLabel("Telefone")
                }
                if home.devices.filter(\.hasLiveVideo).count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink(value: "cameras") { Image(systemName: "rectangle.grid.2x2") }
                            .accessibilityLabel("Todas as câmeras")
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if id == "cameras" {
                    CameraGridView(home: home)
                } else if let device = home.device(id: id) {
                    if device.kind == .airConditioner {
                        ACControlView(model: model, device: device)
                    } else if device.hasRemote {
                        TVControlView(home: home, deviceID: id)
                    } else if device.hasLiveVideo {
                        CameraLiveView(home: home, deviceID: id)
                    } else {
                        LightControlView(home: home, deviceID: id)
                    }
                }
            }
            .sheet(item: $editingDevice) { editing in
                DeviceSettingsSheet(home: home, deviceID: editing.id)
            }
            .sheet(item: $editingScene) { editing in
                SceneEditorSheet(home: home, scenes: model.scenes, sceneID: editing.id) {
                    link.sendAccounts()
                    model.scheduleSync()
                }
            }
            .fullScreenCover(item: Binding(get: { phone.call }, set: { _ in })) { call in
                CallView(phone: phone, call: call)
                    .task(id: call.state == .incoming) { await ring(while: call) }
            }
            .sheet(isPresented: $showingDialer) {
                NavigationStack {
                    DialerView(phone: phone, onSettings: {
                        showingDialer = false
                        Task { if await SettingsLock.unlock() { showingSettings = true } }
                    }, onCall: { showingDialer = false })
                    .navigationTitle("Telefone")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { showingDialer = false } } }
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: model, link: link, phone: phone)
            }
            .onAppear { if !home.hasAccounts { showingSettings = true } }
        }
    }

    private var scenesSection: some View {
        Section {
            if model.scenes.scenes.isEmpty {
                Button("Criar uma cena") { editingScene = SceneEditing(id: nil) }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.scenes.scenes) { scene in
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            home.run(scene)
                        } label: {
                            Label(scene.name, systemImage: scene.symbol)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Editar", systemImage: "pencil") { editingScene = SceneEditing(id: scene.id) }
                            Button("Apagar", systemImage: "trash", role: .destructive) {
                                model.scenes.delete(scene.id)
                                link.sendAccounts()
                                model.scheduleSync()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("Cenas")
                Spacer()
                Button { editingScene = SceneEditing(id: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nova cena")
            }
        } footer: {
            if !model.scenes.scenes.isEmpty { Text("Toque para executar; toque e segure para editar.") }
        }
    }

    @ViewBuilder
    private func row(_ device: HomeDevice) -> some View {
        let content = DeviceRow(device: device, note: home.offTimerText(device.id)) { home.toggle(device.id) }
        if Palette.opens(device) {
            NavigationLink(value: device.id) { content }
        } else {
            content
        }
    }

    /// Touch and hold a device: favorite, its name and room, hide.
    @ViewBuilder
    private func deviceMenu(_ device: HomeDevice) -> some View {
        let custom = home.customization(of: device.id)
        Button(custom.isFavorite ? "Tirar dos favoritos" : "Adicionar aos favoritos",
               systemImage: custom.isFavorite ? "star.slash" : "star") {
            home.customize(device.id) { $0.isFavorite.toggle() }
        }
        Button("Nome e cômodo…", systemImage: "pencil") { editingDevice = DeviceEditing(id: device.id) }
        if device.canSwitch {
            Menu("Desligar em", systemImage: "timer") {
                ForEach([15, 30, 60, 90, 120], id: \.self) { minutes in
                    Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60) min")") {
                        model.setOffTimer(device.id, minutes: minutes)
                    }
                }
                if home.offTimers[device.id] != nil {
                    Button("Cancelar timer", role: .destructive) { model.setOffTimer(device.id, minutes: nil) }
                }
            }
        }
        Button("Ocultar da lista", systemImage: "eye.slash") { home.customize(device.id) { $0.isHidden = true } }
    }

    /// Rings and vibrates while the intercom calls (with the app open).
    private func ring(while call: PhoneCall) async {
        guard call.state == .incoming else { return }
        while phone.call?.state == .incoming, !Task.isCancelled {
            AudioServicesPlayAlertSound(SystemSoundID(1005))
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private var problemLine: String? {
        if let message = home.transientMessage { return message }
        for provider in Provider.allCases {
            switch home.accounts[provider] {
            case .unauthorized?: return "\(provider.name): a chave foi recusada. Veja os Ajustes."
            case .failed(let message)?: return "\(provider.name): \(message)"
            default: continue
            }
        }
        return nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if home.devices.isEmpty {
            if home.accounts.values.contains(.loading) {
                ProgressView("Buscando seus aparelhos…")
            } else if !home.hasAccounts {
                ContentUnavailableView("Nenhuma conta", systemImage: "house",
                                       description: Text("Toque na engrenagem e configure a LG, o Smart Life ou o SmartThings."))
            } else {
                ContentUnavailableView("Nenhum aparelho", systemImage: "house",
                                       description: Text("As contas conectadas não têm aparelhos."))
            }
        }
    }
}

/// A device: a round button that switches it, its name and its state with where it comes from.
struct DeviceRow: View {
    var device: HomeDevice
    var note: String? = nil
    var onToggle: () -> Void

    private var isOn: Bool { device.isOn == true && device.isOnline }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: Labels.icon(device.kind, on: isOn))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.primary.opacity(device.isOnline ? 0.9 : 0.4))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Palette.on(device.kind)) : AnyShapeStyle(Color.secondary.opacity(0.18))))
            }
            .buttonStyle(.plain)
            .disabled(!device.canSwitch)
            .accessibilityLabel(isOn ? "Desligar \(device.name)" : "Ligar \(device.name)")
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                Text([Labels.subtitle(device), note].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(device.isOnline ? 1 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }
}
