import SwiftUI

/// Thin track filled in the mode color up to a round thumb, with a tick at every whole degree.
/// Dragging (or clicking anywhere on the track) updates the value live; `onCommit` fires on release.
/// `onStep` serves the accessibility increment/decrement actions.
struct TemperatureSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var accent: Color
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void
    var onStep: (Double) -> Void

    @State private var dragValue: Double?

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 18
    /// Taller than the track so it's easy to grab.
    private let hitHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            track
            ticks
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            let usable = proxy.size.width - thumbSize
            let thumbX = thumbSize / 2 + usable * fraction(of: dragValue ?? value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.35), accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: thumbX, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .scaleEffect(dragValue == nil ? 1 : 1.15)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let newValue = snapped(at: gesture.location.x, usable: usable)
                        if newValue != dragValue {
                            dragValue = newValue
                            onChange(newValue)
                        }
                    }
                    .onEnded { gesture in
                        let newValue = snapped(at: gesture.location.x, usable: usable)
                        dragValue = nil
                        onCommit(newValue)
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragValue == nil)
            .animation(dragValue == nil ? .snappy(duration: 0.25) : nil, value: value)
        }
        .frame(height: hitHeight)
        .accessibilityElement()
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(Labels.temperature(value)) degrees")
        .accessibilityAdjustableAction { direction in
            onStep(direction == .increment ? step : -step)
        }
    }

    /// A dot per whole degree, aligned with the thumb's travel, with the ends labelled.
    private var ticks: some View {
        let degrees = Array(stride(from: range.lowerBound.rounded(.up), through: range.upperBound, by: 1))
        return GeometryReader { proxy in
            let usable = proxy.size.width - thumbSize
            ForEach(degrees, id: \.self) { degree in
                Circle()
                    .fill(Theme.secondaryText.opacity(degree == degrees.first || degree == degrees.last ? 0 : 0.6))
                    .frame(width: 2.5, height: 2.5)
                    .position(x: thumbSize / 2 + usable * fraction(of: degree), y: proxy.size.height / 2)
            }
            Text("\(Labels.temperature(range.lowerBound))°")
                .position(x: thumbSize / 2, y: proxy.size.height / 2)
            Text("\(Labels.temperature(range.upperBound))°")
                .position(x: proxy.size.width - thumbSize / 2, y: proxy.size.height / 2)
        }
        .frame(height: 12)
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Theme.secondaryText)
        .accessibilityHidden(true)
    }

    private func fraction(of value: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private func snapped(at x: CGFloat, usable: CGFloat) -> Double {
        let fraction = min(max((x - thumbSize / 2) / usable, 0), 1)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        let steps = ((raw - range.lowerBound) / step).rounded()
        return min(range.lowerBound + steps * step, range.upperBound)
    }
}
