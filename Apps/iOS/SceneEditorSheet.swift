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
                    Toggle("No horário", isOn: Binding(
                        get: { draft.schedule != nil },
                        set: { draft.schedule = $0 ? SceneSchedule(hour: 23, minute: 0) : nil }
                    ))
                    if let schedule = draft.schedule {
                        DatePicker("Hora", selection: Binding(
                            get: { Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date() },
                            set: { date in
                                draft.schedule?.hour = Calendar.current.component(.hour, from: date)
                                draft.schedule?.minute = Calendar.current.component(.minute, from: date)
                            }
                        ), displayedComponents: .hourAndMinute)
                        HStack {
                            ForEach([(1, "D"), (2, "S"), (3, "T"), (4, "Q"), (5, "Q"), (6, "S"), (7, "S")], id: \.0) { day, letter in
                                let on = schedule.weekdays.isEmpty || schedule.weekdays.contains(day)
                                Button(letter) {
                                    var days = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
                                    if days.contains(day) { days.remove(day) } else { days.insert(day) }
                                    draft.schedule?.weekdays = days.count == 7 ? [] : days
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(Circle().fill(Color.secondary.opacity(on ? 0.3 : 0.08)))
                            }
                        }
                    }
                    Picker("Localização", selection: $draft.presence) {
                        Text("Não usar").tag(ScenePresence?.none)
                        ForEach(ScenePresence.allCases, id: \.self) { Text($0.text).tag(ScenePresence?.some($0)) }
                    }
                } header: {
                    Text("Executar sozinha")
                } footer: {
                    Text("O horário é executado pelo Mac (pareado em Ajustes → Mac, com o Lar aberto). Chegar e sair usam a localização deste iPhone; marque a casa em Ajustes → Casa.")
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
                            if draft.choices[row.id] == true, row.device?.acceptsTemperature == true {
                                Toggle("Definir temperatura", isOn: Binding(
                                    get: { draft.temperatures[row.id] != nil },
                                    set: { draft.temperatures[row.id] = $0 ? (row.device?.targetTemperature ?? 23) : nil }
                                ))
                                if let value = draft.temperatures[row.id] {
                                    Stepper("\(HomeText.degrees(value))C", value: Binding(
                                        get: { value }, set: { draft.temperatures[row.id] = min(max($0, 16), 30) }
                                    ), step: 1)
                                }
                            }
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
