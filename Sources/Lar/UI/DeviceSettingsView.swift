import LarCore
import SwiftUI

/// A device's name in the Lar, its room, favorite and visibility (the accounts keep their own names).
struct DeviceSettingsView: View {
    var home: HomeStore
    var deviceID: String
    var onBack: () -> Void

    @State private var name = ""
    @State private var room = ""

    private var device: HomeDevice? { home.device(id: deviceID) }
    private var custom: DeviceCustomization { home.customization(of: deviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BackButton(action: onBack)
                Text(device?.name ?? "Aparelho")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Salvar") {
                    home.customize(deviceID) { $0.name = name; $0.room = room }
                    onBack()
                }
                .keyboardShortcut(.defaultAction)
            }
            Divider()
            label("Nome no Lar")
            TextField("Nome", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            label("Cômodo")
            HStack(spacing: 6) {
                TextField("Ex.: Quarto", text: $room)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if !home.rooms.isEmpty {
                    Menu("Usados") {
                        ForEach(home.rooms, id: \.self) { existing in Button(existing) { room = existing } }
                    }
                    .fixedSize()
                }
            }
            Toggle("Favorito (no topo da lista)", isOn: Binding(
                get: { custom.isFavorite }, set: { on in home.customize(deviceID) { $0.isFavorite = on } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            Toggle("Ocultar da lista", isOn: Binding(
                get: { custom.isHidden }, set: { on in home.customize(deviceID) { $0.isHidden = on } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            Text("Deixe o nome em branco para usar o da conta. Os aparelhos ocultos ficam nos Ajustes → Lista.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .onAppear {
            name = custom.name ?? ""
            room = custom.room ?? ""
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.secondaryText)
    }
}
