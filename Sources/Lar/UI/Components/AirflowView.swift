import SwiftUI

/// How the air coming out of the unit looks, derived from fan speed and sleep.
struct AirflowStyle: Equatable {
    var cyclesPerSecond: Double
    var streakCount: Int

    static func make(fanSpeed: String?, sleeping: Bool) -> AirflowStyle {
        var style = switch fanSpeed {
        case "LOW": AirflowStyle(cyclesPerSecond: 0.42, streakCount: 8)
        case "MID": AirflowStyle(cyclesPerSecond: 0.62, streakCount: 11)
        case "HIGH": AirflowStyle(cyclesPerSecond: 0.9, streakCount: 15)
        default: AirflowStyle(cyclesPerSecond: 0.68, streakCount: 12)
        }
        if sleeping {
            style.cyclesPerSecond *= 0.6
            style.streakCount = max(5, style.streakCount - 4)
        }
        return style
    }
}

/// Keeps the flow phase continuous when the speed changes, so streaks don't jump.
struct FlowClock: Equatable {
    var anchorPhase: Double = 0
    var anchorTime = Date(timeIntervalSinceReferenceDate: 0)
    var speed: Double = 0.68

    func phase(at date: Date) -> Double {
        anchorPhase + date.timeIntervalSince(anchorTime) * speed
    }

    mutating func change(speed newSpeed: Double, at date: Date) {
        anchorPhase = phase(at: date)
        anchorTime = date
        speed = newSpeed
    }
}

/// Animated air streaks leaving the vent. Drawing is a pure function of time, so it can be
/// rendered at fixed instants for snapshots.
struct AirflowRenderer {
    static let maxStreaks = 16

    var date: Date
    var clock: FlowClock
    var style: AirflowStyle
    var color: Color
    var isOn: Bool
    /// When the unit was last switched on or off.
    var powerChangedAt: Date
    /// 0 = air thrown forward (short streaks), 1 = pointed down (long streaks).
    var reach: Double
    var intensity: Double
    /// The vent's horizontal extent, in the canvas's coordinates.
    var ventRange: ClosedRange<CGFloat>

    /// Streaks only start once the louver has opened.
    static let openDelay: TimeInterval = 0.45

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let phase = clock.phase(at: date)
        let centerX = (ventRange.lowerBound + ventRange.upperBound) / 2
        let ventWidth = ventRange.upperBound - ventRange.lowerBound
        let length = size.height * (0.6 + 0.38 * reach)

        context.addFilter(.blur(radius: 1.4))
        for index in 0..<min(style.streakCount, Self.maxStreaks) {
            // Golden-ratio spacing spreads any number of streaks evenly across the vent.
            let position = (Double(index) * 0.618034 + 0.13).truncatingRemainder(dividingBy: 1)
            let offset = Self.hash(Double(index) * 7.13 + 3.1)
            let wiggle = Self.hash(Double(index) * 3.97 + 9.4)
            let streakPhase = phase + offset
            let progress = streakPhase - streakPhase.rounded(.down)

            // A streak born while the unit was off (or before it opened) isn't drawn;
            // after switching off, streaks already in the air finish their path.
            let born = date.addingTimeInterval(-progress / max(clock.speed, 0.01))
            if isOn {
                guard born >= powerChangedAt.addingTimeInterval(Self.openDelay) else { continue }
            } else {
                guard born < powerChangedAt else { continue }
            }

            let startX = ventRange.lowerBound + ventWidth * (0.04 + 0.92 * position)
            // Air leaves the louver angled forward, then falls and fans out.
            func point(_ p: Double) -> CGPoint {
                let spread = (startX - centerX) * 0.7 * p * p
                let sway = sin(p * 4 + wiggle * 6.28 + phase * 0.8) * 5 * p
                return CGPoint(x: startX + spread + sway, y: 1 + length * (0.35 * p + 0.65 * p * p))
            }

            let head = progress
            let tail = max(0, head - 0.42)
            var path = Path()
            path.move(to: point(tail))
            for step in 1...12 {
                path.addLine(to: point(tail + (head - tail) * Double(step) / 12))
            }

            let fade = pow(sin(progress * .pi), 1.1)
            let opacity = fade * 0.8 * intensity
            guard opacity > 0.01 else { continue }
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0), color.opacity(opacity * 0.6), color.opacity(opacity)]),
                    startPoint: point(tail), endPoint: point(head)
                ),
                style: StrokeStyle(lineWidth: 1.4 + progress * 3, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Deterministic pseudo-random value in 0..<1.
    static func hash(_ value: Double) -> Double {
        let x = sin(value * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
}
