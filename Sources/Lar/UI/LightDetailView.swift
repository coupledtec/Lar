import LarCore
import SwiftUI

/// A light's screen: power, brightness and, when it has one, its color.
struct LightDetailView: View {
    var home: HomeStore
    var deviceID: String
    var onBack: () -> Void

    /// The slider's value while it's being dragged; sent on release.
    @State private var dragging: Double?

    private var device: HomeDevice? { home.device(id: deviceID) }

    /// Saturated hues, then soft ones, like the Home app's swatches.
    static let swatches: [LightColor] = [0, 30, 55, 120, 190, 230, 275, 320].map { LightColor(hue: $0, saturation: 1) }
        + [0, 40, 60, 140, 200, 240, 280, 330].map { LightColor(hue: $0, saturation: 0.35) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if let device {
                if device.brightness != nil { brightness(device) }
                if device.color != nil { colors(device) }
                Text(device.isOnline ? device.provider.name : "Offline · \(device.provider.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text(device?.name ?? "Luz")
                    .font(.system(size: 13, weight: .semibold))
                if let device {
                    Text(Labels.subtitle(device))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.interpolate)
                }
            }
            Spacer()
            Toggle("Ligar", isOn: Binding(
                get: { device?.isOn == true },
                set: { home.perform(.power($0), on: deviceID) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(device?.canSwitch != true)
        }
    }

    private func brightness(_ device: HomeDevice) -> some View {
        let value = dragging ?? device.brightness ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brilho")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .foregroundStyle(Theme.secondaryText)
                Slider(
                    value: Binding(get: { value }, set: { dragging = $0 }),
                    in: 0.01...1,
                    onEditingChanged: { editing in
                        guard !editing, let final = dragging else { return }
                        home.perform(.brightness(final), on: deviceID)
                        dragging = nil
                    }
                )
                .tint(Theme.onColor(.light))
                .accessibilityLabel("Brilho")
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 12))
        }
        .disabled(!device.canDim)
    }

    private func colors(_ device: HomeDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                    let selected = device.color.map { Self.close($0, swatch) } ?? false
                    Button { home.perform(.color(swatch), on: deviceID) } label: {
                        Circle()
                            .fill(Color(hue: swatch.hue / 360, saturation: swatch.saturation, brightness: 1))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 2 : 0))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cor \(Int(swatch.hue))°")
                }
            }
        }
        .disabled(!device.hasColor)
        .opacity(device.hasColor ? 1 : Theme.disabledOpacity)
    }

    /// The light reports its color rounded, so a swatch counts as selected when it's near.
    static func close(_ a: LightColor, _ b: LightColor) -> Bool {
        let hue = abs(a.hue - b.hue).truncatingRemainder(dividingBy: 360)
        return min(hue, 360 - hue) < 8 && abs(a.saturation - b.saturation) < 0.1
    }
}
