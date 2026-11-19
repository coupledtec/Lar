import LarCore
import SwiftUI

/// The scenes on top of the list: a tap runs one; right-click to change or delete it; "+" makes a new one.
struct SceneStrip: View {
    var home: HomeStore
    var scenes: SceneStore
    var onEdit: (UUID?) -> Void
    /// Eight a page (with many imported Alexa routines the list would push the devices off the screen).
    @State private var page = 0

    var body: some View {
        let paged = Paged(scenes.scenes, page: page, size: 8)
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
                    ForEach(paged.items) { scene in
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
                PageControl(paged: paged, page: $page)
            }
            SuggestionStrip(home: home, scenes: scenes)
        }
    }
}

/// A small ✕ for the cards under the scenes.
private func closeButton(_ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
    }
    .buttonStyle(.plain)
    .foregroundStyle(Theme.secondaryText)
    .help(help)
    .accessibilityLabel(help)
}

/// The GitHub version's own rating ask (Apple's prompt shows only in apps from the App Store), at the same good
/// moment: "Avaliar na App Store", a star on GitHub, or not now.
struct ReviewAskCard: View {
    private var prompt = ReviewPrompt.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if prompt.isDue {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text("Está gostando do Lar?").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    closeButton("Fechar") { prompt.asked() }
                }
                Text("Uma avaliação na App Store ou uma estrela no GitHub ajuda outras pessoas a encontrar o Lar.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Avaliar na App Store") { prompt.rated(); openURL(LarAbout.writeReview) }
                    Button("Estrela no GitHub") { prompt.rated(); openURL(LarAbout.repository) }
                    Button("Agora não") { prompt.asked() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .card(cornerRadius: 9)
        }
    }
}

/// The suggested routines under the scenes, one at a time: "Criar" makes it, "Agora não" hides it for good.
private struct SuggestionStrip: View {
    var home: HomeStore
    var scenes: SceneStore
    @State private var habits: [Habit] = []
    @State private var index = 0

    var body: some View {
        let list = RoutineSuggestions.make(devices: home.devices, scenes: scenes.scenes, watches: scenes.watches,
                                           dismissed: scenes.dismissedSuggestions,
                                           names: home.customizations.compactMapValues(\.name),
                                           rooms: home.customizations.compactMapValues(\.room), habits: habits)
        Group {
            if !list.isEmpty, !scenes.suggestionsHidden {
                let suggestion = list[min(index, list.count - 1)]
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: suggestion.symbol).foregroundStyle(Theme.accent)
                        Text("Sugestão: \(suggestion.title)").font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        if list.count > 1 {
                            Button { index = (index + 1) % list.count } label: {
                                Text("\(min(index, list.count - 1) + 1) de \(list.count) ›").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondaryText)
                            .help("Próxima sugestão")
                        }
                        closeButton("Fechar as sugestões (voltam nos Ajustes)") { scenes.suggestionsHidden = true }
                    }
                    Text(suggestion.detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if suggestion.needsHome {
                        Text("Chegar e sair usam a localização do iPhone (Ajustes → Casa no Lar do iPhone).")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                    }
                    HStack {
                        Button("Criar") { scenes.accept(suggestion) }
                        Button("Agora não") { scenes.dismiss(suggestion) }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .card(cornerRadius: 9)
            }
        }
        .task { habits = await HistoryStore.shared.habits() }
    }
}

/// When the scene runs by itself: at a time (the Mac runs it), on arriving or leaving (the iPhone does).
private struct SceneAutomationEditor: View {
    @Binding var draft: SceneDraft

    private static let days = [(1, "D"), (2, "S"), (3, "T"), (4, "Q"), (5, "Q"), (6, "S"), (7, "S")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("No horário", isOn: Binding(
                    get: { draft.schedule != nil },
                    set: { draft.schedule = $0 ? SceneSchedule(hour: 23, minute: 0) : nil }
                ))
                .toggleStyle(.checkbox)
                if let schedule = draft.schedule {
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date() },
                        set: { date in
                            draft.schedule?.hour = Calendar.current.component(.hour, from: date)
                            draft.schedule?.minute = Calendar.current.component(.minute, from: date)
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Picker("", selection: $draft.presence) {
                    Text("Sem localização").tag(ScenePresence?.none)
                    ForEach(ScenePresence.allCases, id: \.self) { Text($0.text).tag(ScenePresence?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let schedule = draft.schedule {
                HStack(spacing: 4) {
                    ForEach(Self.days, id: \.0) { day, letter in
                        let on = schedule.weekdays.isEmpty || schedule.weekdays.contains(day)
                        Button(letter) {
                            var days = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
                            if days.contains(day) { days.remove(day) } else { days.insert(day) }
                            draft.schedule?.weekdays = days.count == 7 ? [] : days
                        }
                        .buttonStyle(.plain)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(on ? 0.22 : 0.05)))
                    }
                    Text(schedule.text).font(.system(size: 10)).foregroundStyle(Theme.secondaryText).padding(.leading, 4)
                }
            }
            HStack(spacing: 10) {
                if draft.presence == .arrive {
                    Picker("", selection: $draft.approachDistance) {
                        Text("Na porta").tag(Double?.none)
                        ForEach([500.0, 1000, 1500, 2000, 3000], id: \.self) { meters in
                            Text("Chegando (a \(Coordinate.distanceText(meters)))").tag(Double?.some(meters))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if draft.schedule != nil || draft.presence != nil {
                    Toggle("Só acima de", isOn: Binding(
                        get: { draft.condition?.warmerThan != nil },
                        set: { on in
                            var condition = draft.condition ?? SceneCondition()
                            condition.warmerThan = on ? 26 : nil
                            draft.condition = condition
                        }
                    ))
                    .toggleStyle(.checkbox)
                    if let warmer = draft.condition?.warmerThan {
                        Stepper("\(Int(warmer)) °C", value: Binding(
                            get: { warmer },
                            set: { draft.condition?.warmerThan = $0 }
                        ), in: 18...35)
                        .fixedSize()
                    }
                    Toggle("Só à noite", isOn: Binding(
                        get: { draft.condition?.atNight == true },
                        set: { on in
                            var condition = draft.condition ?? SceneCondition()
                            condition.atNight = on ? true : nil
                            draft.condition = condition
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            Text("O horário roda no Mac (com o Lar aberto); chegar e sair, no iPhone.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 11))
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
                    .accessibilityLabel(Labels.sceneSymbol(symbol))
                    .accessibilityAddTraits(draft.symbol == symbol ? .isSelected : [])
                }
            }
            SceneAutomationEditor(draft: $draft)
            if draft.hasAlexaSteps, !home.echos.isEmpty {
                HStack {
                    Text("Parte da Alexa em").font(.system(size: 11))
                    Spacer()
                    Picker("Parte da Alexa em", selection: $draft.alexaEcho) {
                        Text("Primeiro Echo no ar").tag(String?.none)
                        ForEach(home.devices.filter { $0.echo != nil }) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .font(.system(size: 11))
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
            PagedScroll(maxHeight: 360) {
                VStack(spacing: 6) {
                    ForEach(draft.rows(home.devices), id: \.id) { row in
                        HStack {
                            Image(systemName: Labels.icon(row.device?.kind ?? .other, on: false))
                                .font(.system(size: 11))
                                .frame(width: 16)
                                .foregroundStyle(Theme.secondaryText)
                            Text(row.device == nil ? String(localized: "\(row.name) · fora do ar") : row.name)
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
