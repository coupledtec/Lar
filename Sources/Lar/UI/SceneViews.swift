import LarCore
import SwiftUI

/// The scenes on top of the list: a tap runs one; right-click to change or delete it; "+" makes a new one.
struct SceneStrip: View {
    var home: HomeStore
    var scenes: SceneStore
    var onEdit: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CENAS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button { onEdit(nil) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Nova cena")
                .accessibilityLabel("Nova cena")
            }
            if scenes.scenes.isEmpty {
                Button { onEdit(nil) } label: {
                    Text("Crie uma cena para ligar e desligar vários aparelhos de uma vez.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(scenes.scenes) { scene in
                        Button { home.run(scene) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: scene.symbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accent)
                                Text(scene.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .card(cornerRadius: 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Editar…") { onEdit(scene.id) }
                            Button("Apagar", role: .destructive) { scenes.delete(scene.id) }
                        }
                        .help("Clique para executar; botão direito para editar")
                    }
                }
            }
        }
    }
}

/// An air conditioner the scene turns on: keep its target, or set one.
private struct SceneTemperatureRow: View {
    @Binding var draft: SceneDraft
    var id: String
    var current: Double?

    var body: some View {
        HStack {
            Toggle("Temperatura", isOn: Binding(
                get: { draft.temperatures[id] != nil },
                set: { draft.temperatures[id] = $0 ? (current ?? 23) : nil }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            Spacer()
            if let value = draft.temperatures[id] {
                Stepper("\(HomeText.degrees(value))C", value: Binding(
                    get: { value }, set: { draft.temperatures[id] = min(max($0, 16), 30) }
                ), step: 1)
                .font(.system(size: 11))
            }
        }
        .padding(.leading, 22)
    }
}

/// Makes or changes a scene: name, symbol and, per device, turn on / turn off / leave alone.
struct SceneEditorView: View {
    var home: HomeStore
    var scenes: SceneStore
    var sceneID: UUID?
    var onBack: () -> Void

    @State private var draft = SceneDraft()

    private func temperatureRow(_ id: String, current: Double?) -> some View {
        SceneTemperatureRow(draft: $draft, id: id, current: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BackButton(action: onBack)
                Text(sceneID == nil ? "Nova cena" : "Editar cena")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Salvar") {
                    scenes.save(draft.build(with: home.devices))
                    onBack()
                }
                .disabled(!draft.canSave)
                .keyboardShortcut(.defaultAction)
            }
            Divider()
            TextField("Nome (ex.: Dormir)", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(HomeScene.symbols, id: \.self) { symbol in
                    Button { draft.symbol = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                            .frame(width: 34, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(draft.symbol == symbol ? 0.22 : 0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("APARELHOS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Usar o estado atual") { draft.useCurrentState(of: home.devices) }
                    .font(.system(size: 11))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(draft.rows(home.devices), id: \.id) { row in
                        HStack {
                            Image(systemName: Labels.icon(row.device?.kind ?? .other, on: false))
                                .font(.system(size: 11))
                                .frame(width: 16)
                                .foregroundStyle(Theme.secondaryText)
                            Text(row.device == nil ? "\(row.name) · fora do ar" : row.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { draft.choices[row.id].map { $0 ? 1 : 0 } ?? -1 },
                                set: { draft.choices[row.id] = $0 < 0 ? nil : $0 == 1 }
                            )) {
                                Text("—").tag(-1)
                                Text("Ligar").tag(1)
                                Text("Desligar").tag(0)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        if draft.choices[row.id] == true, row.device?.acceptsTemperature == true {
                            temperatureRow(row.id, current: row.device?.targetTemperature)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            if sceneID != nil {
                Button("Apagar cena", role: .destructive) {
                    if let sceneID { scenes.delete(sceneID) }
                    onBack()
                }
                .font(.system(size: 11))
            }
        }
        .onAppear { draft = SceneDraft(editing: sceneID.flatMap(scenes.scene(id:))) }
    }
}
