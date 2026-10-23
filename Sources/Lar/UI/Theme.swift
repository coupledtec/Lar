import LarCore
import SwiftUI

enum Theme {
    static let popoverWidth: CGFloat = 320
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.07)
    static let cardRadius: CGFloat = 14
    static let secondaryText = Color.white.opacity(0.55)
    static let disabledOpacity = 0.4

    /// The accent color chosen in System Settings (or an ancestor's `.tint`), like native controls use.
    static let accent = Color.accentColor
    static let warning = Color.orange

    /// Accent for the power button, slider, airflow and glow, per job mode. Cooling, the default,
    /// follows the system accent; the other modes keep their own hue so they stay recognizable.
    static func modeColor(_ mode: String?) -> Color {
        switch mode {
        case ACMode.cool: accent
        case ACMode.dry: Color(red: 0.49, green: 0.88, blue: 0.76)
        case ACMode.auto: Color(red: 0.73, green: 0.69, blue: 1.00)
        case ACMode.heat: Color(red: 1.00, green: 0.66, blue: 0.40)
        default: Color(white: 0.92)
        }
    }
}

extension View {
    /// The translucent rounded card used for tiles and settings sections.
    func card(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Theme.cardFill))
            .overlay(shape.strokeBorder(Theme.cardStroke))
    }
}

// MARK: - The device list

extension Theme {
    /// Lit lights and plugs glow amber, like the Home app; climate follows the accent.
    static func onColor(_ kind: DeviceKind) -> Color {
        switch kind {
        case .light, .plug: Color(red: 1.0, green: 0.78, blue: 0.30)
        case .airConditioner, .fan, .tv, .speaker: accent
        default: Color(white: 0.92)
        }
    }
}

