import LarCore
import SwiftUI

/// The wall unit illustration: body, display LED, louver and the air coming out.
///
/// Switching on lights the LED, swings the louver open and then starts the airflow; switching off
/// stops new air, lets the streaks in flight finish and closes the louver.
struct ACUnitView: View {
    var isOn: Bool
    var mode: String?
    var fanSpeed: String?
    var swing: Bool
    var sleeping: Bool
    var target: Double?
    /// The timeline only runs while the popover is on screen.
    var isVisible: Bool
    /// Freezes time, for snapshots.
    var fixedDate: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var powerChangedAt = Date.distantPast
    @State private var lingering = false
    @State private var clock = FlowClock()

    private let bodySize = CGSize(width: 206, height: 64)
    static let height: CGFloat = 168
    private static let lingerDuration: Duration = .seconds(2.6)

    private var style: AirflowStyle { .make(fanSpeed: fanSpeed, sleeping: sleeping) }
    private var accent: Color { Theme.modeColor(mode) }
    private var animatesAir: Bool { !reduceMotion && (isOn || lingering) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: fixedDate != nil || !isVisible || !animatesAir)) { context in
            let date = fixedDate ?? context.date
            ZStack(alignment: .top) {
                glow
                if !reduceMotion {
                    airflow(at: date)
                        .padding(.top, bodySize.height - 4)
                }
                unit(at: date)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: Self.height)
        .onChange(of: isOn) { _, on in
            powerChangedAt = Date()
            lingering = !on
        }
        // Keeps the timeline running while the last streaks leave the vent. Restarted (and the old
        // wait cancelled) on every power change, so a quick off → on → off doesn't cut the air short.
        .task(id: isOn) {
            guard lingering else { return }
            do {
                try await Task.sleep(for: Self.lingerDuration)
                lingering = false
            } catch {}
        }
        .onChange(of: style.cyclesPerSecond) { _, speed in
            clock.change(speed: speed, at: Date())
        }
        .onAppear { clock.speed = style.cyclesPerSecond }
        .accessibilityElement()
        .accessibilityLabel(isOn ? "Air conditioner running, \(Labels.mode(mode))" : "Air conditioner off")
    }

    // MARK: Parts

    private var glow: some View {
        Ellipse()
            .fill(RadialGradient(colors: [accent.opacity(reduceMotion ? 0.32 : 0.22), .clear], center: .center, startRadius: 4, endRadius: 140))
            .frame(width: 300, height: 90)
            .blur(radius: 18)
            .offset(y: bodySize.height + 10)
            .opacity(isOn ? 1 : 0)
            .animation(.easeInOut(duration: 0.9).delay(isOn ? 0.4 : 0), value: isOn)
    }

    private func airflow(at date: Date) -> some View {
        Canvas { context, size in
            let ventWidth = bodySize.width - 36
            let left = (size.width - ventWidth) / 2
            let renderer = AirflowRenderer(
                date: date,
                clock: clock,
                style: style,
                color: accent,
                isOn: isOn,
                powerChangedAt: powerChangedAt,
                reach: swing ? 0.5 + 0.5 * sin(date.timeIntervalSinceReferenceDate * 0.9) : 0.55,
                intensity: sleeping ? 0.6 : 1,
                ventRange: left...(left + ventWidth)
            )
            renderer.draw(&context, size: size)
        }
        .frame(height: Self.height - bodySize.height)
        .allowsHitTesting(false)
    }

    private func unit(at date: Date) -> some View {
        ZStack(alignment: .bottom) {
            // Body
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.99), Color(white: 0.93), Color(white: 0.82)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(alignment: .top) {
                    // Top edge highlight
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                }
                .shadow(color: .black.opacity(0.55), radius: 14, y: 8)

            // Display LED
            led
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 14)
                .padding(.trailing, 22)

            // Vent slot, revealed when the louver opens
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.05), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                .frame(width: bodySize.width - 24, height: 11)
                .padding(.bottom, 7)

            louver(at: date)
                .padding(.bottom, 7)
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .rotation3DEffect(.degrees(-10), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
    }

    private var led: some View {
        Text(Labels.temperature(target))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.accent)
            .shadow(color: Theme.accent.opacity(0.9), radius: 3)
            .opacity(isOn ? (sleeping ? 0.45 : 1) : 0)
            .animation(.easeOut(duration: 0.35), value: isOn)
            .contentTransition(.numericText())
            .animation(.snappy, value: target)
    }

    private func louver(at date: Date) -> some View {
        let swingAngle = isOn && swing && !reduceMotion
            ? sin(date.timeIntervalSinceReferenceDate * 0.9) * 14
            : 0
        let openAngle: Double = isOn ? 62 : 0
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.76)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .frame(width: bodySize.width - 22, height: 12)
            .rotation3DEffect(.degrees(openAngle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
            .offset(y: isOn ? 5 : 0)
            .animation(
                reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.62).delay(isOn ? 0.18 : 0.9),
                value: isOn
            )
            .rotation3DEffect(.degrees(swingAngle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
    }
}
