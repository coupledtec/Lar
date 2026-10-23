import LarCore
import SwiftUI

/// An LG air conditioner with every control (the Mac's screen, in iPhone controls). Its store polls only while this
/// screen is open.
struct ACControlView: View {
    var model: LarModel
    var device: HomeDevice

    @State private var dragging: Double?

    private var store: ACStore? { model.airConditioner }
    private var status: ACStatus? { store?.status }
    private var isOn: Bool { status?.isOn ?? false }

    var body: some View {
        Form {
            if let store {
                Section {
                    // The Mac's animated unit: louver, display and the air coming out in the mode's color.
                    ACUnitView(
                        isOn: isOn, mode: status?.mode, fanSpeed: status?.fanSpeed, swing: status?.swing ?? false,
                        sleeping: status?.sleepMinutesLeft != nil, target: dragging ?? status?.targetTemperature,
                        isVisible: true
                    )
                    .frame(width: 240, height: ACUnitView.height)
                    .frame(maxWidth: .infinity)
                    .environment(\.colorScheme, .dark)
                    .listRowBackground(Color(white: 0.11))
                }
                Section {
                    Toggle(isOn: Binding(get: { isOn }, set: { store.perform(.power($0)) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Labels.activity(status, target: dragging ?? status?.targetTemperature))
                            Text("Ambiente \(Labels.temperature(status?.currentTemperature)) °C")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(status == nil)
                }
                Section("Temperatura") {
                    temperature(store)
                }
                .disabled(!isOn || !ACMode.acceptsTargetTemperature(status?.mode))
                Section {
                    Picker("Modo", selection: Binding(get: { status?.mode ?? "" }, set: { store.perform(.mode($0)) })) {
                        ForEach(store.capabilities.modes, id: \.self) { Text(Labels.mode($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Ventilação", selection: Binding(get: { status?.fanSpeed ?? "" }, set: { store.perform(.fanSpeed($0)) })) {
                        ForEach(store.capabilities.fanSpeeds, id: \.self) { Text(Labels.fan($0)).tag($0) }
                    }
                    if store.capabilities.supportsSwing {
                        Toggle("Oscilar", isOn: Binding(get: { status?.swing ?? false }, set: { store.perform(.swing($0)) }))
                    }
                    if store.capabilities.supportsEco {
                        Toggle("Modo Eco", isOn: Binding(get: { status?.eco ?? false }, set: { store.perform(.eco($0)) }))
                    }
                }
                .disabled(!isOn)
                if store.connection != .connected || store.transientMessage != nil {
                    Section { Text(statusLine(store)).font(.footnote).foregroundStyle(.orange) }
                }
            } else {
                ProgressView()
            }
        }
        .redacted(reason: status == nil ? .placeholder : [])
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.openAirConditioner(rawID: device.rawID) }
        .onDisappear { model.closeAirConditioner() }
    }

    private func temperature(_ store: ACStore) -> some View {
        let caps = store.capabilities
        let value = dragging ?? status?.targetTemperature ?? caps.minTemperature
        return VStack(spacing: 12) {
            HStack {
                Button { store.setTargetTemperature(value - caps.temperatureStep, debounced: true) } label: {
                    Image(systemName: "minus.circle.fill").font(.title)
                }
                .accessibilityLabel("Diminuir")
                Spacer()
                Text("\(Labels.temperature(value))°")
                    .font(.system(size: 56, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                Spacer()
                Button { store.setTargetTemperature(value + caps.temperatureStep, debounced: true) } label: {
                    Image(systemName: "plus.circle.fill").font(.title)
                }
                .accessibilityLabel("Aumentar")
            }
            .buttonStyle(.borderless)
            Slider(
                value: Binding(get: { value }, set: { dragging = $0 }),
                in: caps.minTemperature...max(caps.maxTemperature, caps.minTemperature + 1),
                step: caps.temperatureStep,
                onEditingChanged: { editing in
                    guard !editing, let final = dragging else { return }
                    store.setTargetTemperature(final, debounced: false)
                    dragging = nil
                }
            )
            .tint(Palette.mode(status?.mode))
        }
        .animation(.snappy, value: value)
    }

    private func statusLine(_ store: ACStore) -> String {
        if let message = store.transientMessage { return message }
        return switch store.connection {
        case .offline(let message): message
        case .unauthorized: "O token da LG foi recusado"
        case .deviceError: "O aparelho indica um erro"
        case .loading: "Conectando…"
        default: ""
        }
    }
}
