import LarCore
import SwiftUI
import WatchKit

/// The device list on the wrist: tap the round button to switch, the row to open an air conditioner, a light, a
/// camera or a TV.
struct WatchHomeView: View {
    var model: LarModel
    var link: PhoneLink

    private var home: HomeStore { model.home }

    var body: some View {
        NavigationStack {
            List {
                if !home.hasAccounts {
                    Text("Abra o Lar no iPhone para configurar as contas.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let message = problemLine {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                if !model.scenes.scenes.isEmpty {
                    Section("Cenas") {
                        ForEach(model.scenes.scenes) { scene in
                            Button {
                                WKInterfaceDevice.current().play(.success)
                                home.run(scene)
                            } label: {
                                Label(scene.name, systemImage: scene.symbol)
                            }
                        }
                    }
                }
                ForEach(home.sections(grouping: home.grouping)) { section in
                    Section(section.title) {
                        ForEach(section.devices) { device in
                            if Palette.opens(device) {
                                NavigationLink(value: device.id) { WatchDeviceRow(device: device) { home.toggle(device.id) } }
                            } else {
                                WatchDeviceRow(device: device) { home.toggle(device.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lar")
            .navigationDestination(for: String.self) { id in
                if let device = home.device(id: id) {
                    if device.kind == .airConditioner {
                        WatchACView(model: model, device: device)
                    } else if device.hasLiveVideo {
                        CameraLiveView(home: home, deviceID: id)
                    } else if device.kind == .tv {
                        WatchTVView(home: home, deviceID: id)
                    } else {
                        WatchLightView(home: home, deviceID: id)
                    }
                }
            }
            .overlay {
                if home.devices.isEmpty, home.hasAccounts { ProgressView() }
            }
        }
    }

    /// A failed command, or the first account that isn't answering (like the iPhone's list).
    private var problemLine: String? {
        if let message = home.transientMessage { return message }
        for provider in Provider.allCases {
            switch home.accounts[provider] {
            case .unauthorized?: return "\(provider.name): chave recusada"
            case .failed(let message)?: return "\(provider.name): \(message)"
            default: continue
            }
        }
        return nil
    }

}

struct WatchDeviceRow: View {
    var device: HomeDevice
    var onToggle: () -> Void

    private var isOn: Bool { device.isOn == true && device.isOnline }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: Labels.icon(device.kind, on: isOn))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.white.opacity(device.isOnline ? 0.9 : 0.4))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Palette.on(device.kind)) : AnyShapeStyle(Color.white.opacity(0.15))))
            }
            .buttonStyle(.plain)
            .disabled(!device.canSwitch)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 15)).lineLimit(1)
                Text(Labels.subtitle(device)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .opacity(device.isOnline ? 1 : 0.6)
    }
}
