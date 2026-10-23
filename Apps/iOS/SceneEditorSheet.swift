import LarCore
import SwiftUI

/// Which scene the editor opens: nil makes a new one.
struct SceneEditing: Identifiable {
    var id: UUID?
}

/// Makes or changes a scene: name, symbol and, per device, turn on / turn off / leave alone (the Mac's editor).
struct SceneEditorSheet: View {
    var home: HomeStore
    var scenes: SceneStore
    var sceneID: UUID?
    /// After saving or deleting (the watch gets the new list).
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = SceneDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome (ex.: Dormir)", text: $draft.name)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(HomeScene.symbols, id: \.self) { symbol in
                            Button { draft.symbol = symbol } label: {
                                Image(systemName: symbol)
                                    .frame(width: 40, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(draft.symbol == symbol ? 0.3 : 0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    ForEach(draft.rows(home.devices), id: \.id) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(row.device == nil ? "\(row.name) · fora do ar" : row.name,
                                  systemImage: Labels.icon(row.device?.kind ?? .other, on: false))
                            Picker(row.name, selection: Binding(
                                get: { draft.choices[row.id].map { $0 ? 1 : 0 } ?? -1 },
                                set: { draft.choices[row.id] = $0 < 0 ? nil : $0 == 1 }
                            )) {
                                Text("Não mexer").tag(-1)
                                Text("Ligar").tag(1)
                                Text("Desligar").tag(0)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                } header: {
                    HStack {
                        Text("Aparelhos")
                        Spacer()
                        Button("Usar o estado atual") { draft.useCurrentState(of: home.devices) }
                            .font(.footnote)
                    }
                } footer: {
                    Text("Uma luz ligada guarda o brilho que tem agora.")
                }
                if let sceneID {
                    Section {
                        Button("Apagar cena", role: .destructive) {
                            scenes.delete(sceneID)
                            onChange()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(sceneID == nil ? "Nova cena" : "Editar cena")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        scenes.save(draft.build(with: home.devices))
                        onChange()
                        dismiss()
                    }
                    .disabled(!draft.canSave)
                }
            }
            .onAppear { draft = SceneDraft(editing: sceneID.flatMap(scenes.scene(id:))) }
        }
    }
}
