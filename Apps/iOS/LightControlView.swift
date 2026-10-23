import LarCore
import SwiftUI

/// A light: power, brightness (sent when the slider is released) and, when it has one, its color.
struct LightControlView: View {
    var home: HomeStore
    var deviceID: String

    @State private var dragging: Double?

    private var device: HomeDevice? { home.device(id: deviceID) }

    var body: some View {
        Form {
            if let device {
                Section {
                    Toggle("Ligada", isOn: Binding(get: { device.isOn == true }, set: { home.perform(.power($0), on: deviceID) }))
                        .disabled(!device.canSwitch)
                }
                if device.brightness != nil {
                    Section("Brilho · \(Int(((dragging ?? device.brightness ?? 1) * 100).rounded()))%") {
                        Slider(
                            value: Binding(get: { dragging ?? device.brightness ?? 1 }, set: { dragging = $0 }),
                            in: 0.01...1,
                            onEditingChanged: { editing in
                                guard !editing, let final = dragging else { return }
                                home.perform(.brightness(final), on: deviceID)
                                dragging = nil
                            },
                            minimumValueLabel: Image(systemName: "sun.min"),
                            maximumValueLabel: Image(systemName: "sun.max.fill"),
                            label: { Text("Brilho") }
                        )
                        .tint(Palette.amber)
                        .disabled(!device.canDim)
                    }
                }
                if device.color != nil {
                    Section("Cor") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                            ForEach(Array(Palette.swatches.enumerated()), id: \.offset) { _, swatch in
                                let selected = device.color.map { Palette.close($0, swatch) } ?? false
                                Button { home.perform(.color(swatch), on: deviceID) } label: {
                                    Circle()
                                        .fill(Palette.swatch(swatch))
                                        .frame(width: 32, height: 32)
                                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: selected ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        .disabled(!device.hasColor)
                    }
                }
                Section { Text(Labels.subtitle(device)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(device?.name ?? "Luz")
        .navigationBarTitleDisplayMode(.inline)
    }
}
