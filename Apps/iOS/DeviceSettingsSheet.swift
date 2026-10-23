import LarCore
import SwiftUI

/// Which device's settings are open.
struct DeviceEditing: Identifiable {
    var id: String
}

/// A device's name in the Lar, its room, favorite and visibility (the Mac's screen; the accounts keep their names).
struct DeviceSettingsSheet: View {
    var home: HomeStore
    var deviceID: String

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var room = ""
    @State private var isFavorite = false
    @State private var isHidden = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome no Lar") {
                    TextField(home.device(id: deviceID)?.name ?? "Nome", text: $name)
                }
                Section {
                    TextField("Ex.: Quarto", text: $room)
                    if !home.rooms.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(home.rooms, id: \.self) { existing in
                                    Button(existing) { room = existing }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Cômodo")
                }
                Section {
                    Toggle("Favorito (no topo da lista)", isOn: $isFavorite)
                    Toggle("Ocultar da lista", isOn: $isHidden)
                } footer: {
                    Text("Deixe o nome em branco para usar o da conta. Os aparelhos ocultos ficam em Ajustes → Lista.")
                }
            }
            .navigationTitle("Aparelho")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        home.customize(deviceID) {
                            $0.name = name
                            $0.room = room
                            $0.isFavorite = isFavorite
                            $0.isHidden = isHidden
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                let custom = home.customization(of: deviceID)
                name = custom.name ?? ""
                room = custom.room ?? ""
                isFavorite = custom.isFavorite
                isHidden = custom.isHidden
            }
        }
    }
}
