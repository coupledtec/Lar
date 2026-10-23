import LarCore
import SwiftUI

/// The popover: the device list, and the screens it opens (an air conditioner, a light, Settings).
struct HomeView: View {
    var model: AppModel
    /// Freezes the animation clock, for snapshots.
    var fixedDate: Date?
    /// Starts on another screen, for snapshots.
    var initialRoute: Route = .list

    enum Route: Equatable {
        case list, settings
        case airConditioner(rawID: String)
        case light(id: String)
        case tv(id: String)
        /// A scene's editor; nil makes a new one.
        case scene(id: UUID?)
        /// A device's name, room, favorite and visibility.
        case device(id: String)
        case diagnostics
    }

    @State private var route: Route?

    private var current: Route { route ?? (model.home.hasAccounts ? initialRoute : .settings) }
    private var home: HomeStore { model.home }

    var body: some View {
        Group {
            switch current {
            case .list:
                list.transition(.move(edge: .leading).combined(with: .opacity))
            case .settings:
                SettingsView(model: model, canGoBack: home.hasAccounts, onDiagnostics: { go(.diagnostics) }) { go(.list) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .airConditioner:
                if let store = model.airConditioner {
                    ACDetailView(store: store, onBack: { go(.list) }, fixedDate: fixedDate)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            case .light(let id):
                LightDetailView(home: home, deviceID: id) { go(.list) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .tv(let id):
                TVDetailView(home: home, deviceID: id) { go(.list) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .diagnostics:
                DiagnosticsView(model: model) { go(.settings) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .device(let id):
                DeviceSettingsView(home: home, deviceID: id) { go(.list) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .scene(let id):
                SceneEditorView(home: home, scenes: model.scenes, sceneID: id) { go(.list) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(width: Theme.popoverWidth)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.3), value: current)
    }

    private func go(_ next: Route) {
        if case .airConditioner = current, next == .list { model.closeAirConditioner() }
        if case .airConditioner(let rawID) = next { model.openAirConditioner(rawID: rawID) }
        route = next
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = problemLine {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            }
            Divider()
            if home.devices.isEmpty {
                emptyState
            } else {
                // Grows with the list, then scrolls.
                ViewThatFits(in: .vertical) {
                    sections
                    ScrollView { sections }
                        .scrollIndicators(.never)
                        .frame(height: Self.maxListHeight)
                }
            }
        }
    }

    private static let maxListHeight: CGFloat = 470

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: home.switchedOnCount > 0 ? "house.fill" : "house")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text("Lar")
                .font(.system(size: 15, weight: .semibold))
            if home.switchedOnCount > 0 {
                Text("· \(home.switchedOnCount) \(home.switchedOnCount == 1 ? "ligado" : "ligados")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
            }
            Spacer()
            if home.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            if home.devices.filter(\.hasLiveVideo).count > 1 {
                Button { CameraWindow.showAll(home: home) } label: {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Todas as câmeras ao vivo")
                .accessibilityLabel("Todas as câmeras")
            }
            Button {
                Task { if await SettingsLock.unlock() { go(.settings) } }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ajustes")
            .accessibilityLabel("Ajustes")
        }
    }

    /// A failed command, or the first account that isn't answering.
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

    private var emptyState: some View {
        VStack(spacing: 6) {
            if home.accounts.values.contains(.loading) {
                ProgressView().controlSize(.small)
                Text("Buscando seus aparelhos…")
            } else {
                Image(systemName: "house")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.secondaryText)
                Text("Nenhum aparelho nas contas conectadas.")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            SceneStrip(home: home, scenes: model.scenes) { go(.scene(id: $0)) }
            ForEach(home.sections(grouping: home.grouping)) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.bottom, 2)
                    ForEach(section.devices) { device in
                        DeviceRow(device: device, opens: opens(device)) { open(device) } onToggle: {
                            home.toggle(device.id)
                        }
                        .contextMenu { deviceMenu(device) }
                    }
                }
            }
        }
    }

    /// Right-click on a device: favorite, its settings (name, room), hide.
    @ViewBuilder
    private func deviceMenu(_ device: HomeDevice) -> some View {
        let custom = home.customization(of: device.id)
        Button(custom.isFavorite ? "Tirar dos favoritos" : "Adicionar aos favoritos") {
            home.customize(device.id) { $0.isFavorite.toggle() }
        }
        Button("Nome e cômodo…") { go(.device(id: device.id)) }
        Divider()
        Button("Ocultar da lista") { home.customize(device.id) { $0.isHidden = true } }
    }

    /// Whether clicking the row opens a screen (or a window) rather than just switching it.
    private func opens(_ device: HomeDevice) -> Bool {
        // An offline device has nothing to show: its screen would only be placeholders.
        guard device.isOnline else { return false }
        // The full remote is ADB's (Android TV); a Samsung TV from SmartThings only switches.
        return device.hasRemote || (device.kind == .airConditioner && device.provider == .lg) || device.canDim || device.hasColor || device.hasLiveVideo
    }

    private func open(_ device: HomeDevice) {
        guard device.isOnline else { return }
        if device.hasRemote {
            go(.tv(id: device.id))
        } else if device.kind == .airConditioner, device.provider == .lg {
            go(.airConditioner(rawID: device.rawID))
        } else if device.hasLiveVideo {
            CameraWindow.show(device: device, home: home)
        } else if device.canDim || device.hasColor {
            go(.light(id: device.id))
        } else if device.canSwitch {
            home.toggle(device.id)
        }
    }
}

/// A device in the list: a round button that switches it (Control Center style), its name and state, and a
/// chevron when it opens more.
struct DeviceRow: View {
    var device: HomeDevice
    var opens: Bool
    var onOpen: () -> Void
    var onToggle: () -> Void

    @State private var isHovered = false

    private var isOn: Bool { device.isOn == true && device.isOnline }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: Labels.icon(device.kind, on: isOn))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.white.opacity(device.isOnline ? 0.9 : 0.4))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Theme.onColor(device.kind)) : AnyShapeStyle(Color.white.opacity(0.1))))
            }
            .buttonStyle(.plain)
            .disabled(!device.canSwitch)
            .help(device.canSwitch ? (isOn ? "Desligar" : "Ligar") : "")
            .accessibilityLabel(isOn ? "Desligar \(device.name)" : "Ligar \(device.name)")

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(Labels.subtitle(device))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 4)
            if opens {
                Image(systemName: device.hasLiveVideo ? "play.rectangle" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(isHovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { opens ? onOpen() : (device.canSwitch ? onToggle() : ()) }
        .onHover { isHovered = $0 }
        .padding(.horizontal, -6)
        .opacity(device.isOnline ? 1 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityElement(children: .combine)
    }
}
