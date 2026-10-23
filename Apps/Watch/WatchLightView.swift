import LarCore
import SwiftUI

/// A light on the wrist: power, brightness on the Digital Crown (sent once it settles) and the color swatches.
struct WatchLightView: View {
    var home: HomeStore
    var deviceID: String

    @State private var crown = 1.0
    @State private var sendTask: Task<Void, Never>?

    private var device: HomeDevice? { home.device(id: deviceID) }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let device {
                    Toggle("Ligada", isOn: Binding(get: { device.isOn == true }, set: { home.perform(.power($0), on: deviceID) }))
                        .disabled(!device.canSwitch)
                    if device.brightness != nil {
                        Gauge(value: crown) { Image(systemName: "sun.max.fill") } currentValueLabel: {
                            Text("\(Int((crown * 100).rounded()))%")
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(Palette.amber)
                        .focusable()
                        .digitalCrownRotation($crown, from: 0.01, through: 1, by: 0.05, sensitivity: .medium, isContinuous: false)
                        .onChange(of: crown) { _, value in send(.brightness(value)) }
                    }
                    if device.color != nil {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                            ForEach(Array(Palette.swatches.prefix(8).enumerated()), id: \.offset) { _, swatch in
                                Button { home.perform(.color(swatch), on: deviceID) } label: {
                                    Circle().fill(Palette.swatch(swatch)).frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(device?.name ?? "Luz")
        .onAppear { crown = device?.brightness ?? 1 }
    }

    /// The crown sends many values while it turns: only the last one, once it rests.
    private func send(_ command: HomeCommand) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            home.perform(command, on: deviceID)
        }
    }
}
