import LarCore
import SwiftUI

/// An LG air conditioner on the wrist: the Digital Crown sets the temperature (sent once it settles), with power and
/// mode below.
struct WatchACView: View {
    var model: LarModel
    var device: HomeDevice

    @State private var crown = 22.0

    private var store: ACStore? { model.airConditioner }
    private var status: ACStatus? { store?.status }
    private var isOn: Bool { status?.isOn ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let store {
                    let caps = store.capabilities
                    Text("\(Labels.temperature(crown))°")
                        .font(.system(size: 44, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Palette.mode(status?.mode) : .secondary)
                        .focusable()
                        .digitalCrownRotation($crown, from: caps.minTemperature, through: caps.maxTemperature,
                                              by: caps.temperatureStep, sensitivity: .low, isContinuous: false)
                        .onChange(of: crown) { _, value in
                            guard isOn, value != status?.targetTemperature else { return }
                            store.setTargetTemperature(value, debounced: true)
                        }
                    Text(Labels.activity(status, target: crown))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Ligado", isOn: Binding(get: { isOn }, set: { store.perform(.power($0)) }))
                        .disabled(status == nil)
                    Picker("Modo", selection: Binding(get: { status?.mode ?? "" }, set: { store.perform(.mode($0)) })) {
                        ForEach(caps.modes, id: \.self) { Text(Labels.mode($0)).tag($0) }
                    }
                    .disabled(!isOn)
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(device.name)
        .onAppear { model.openAirConditioner(rawID: device.rawID) }
        .onDisappear { model.closeAirConditioner() }
        .onChange(of: status?.targetTemperature) { _, target in
            if let target { crown = target }
        }
    }
}
