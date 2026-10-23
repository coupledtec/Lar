import LarCore
import SwiftUI

/// Colors shared by the iPhone and the watch (the Mac has its own Theme).
enum Palette {
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.30)

    /// Lit lights and plugs glow amber, like the Home app; climate and TVs follow the accent.
    static func on(_ kind: DeviceKind) -> Color {
        switch kind {
        case .light, .plug: amber
        case .airConditioner, .fan, .tv, .speaker: .accentColor
        default: Color(white: 0.92)
        }
    }

    static func mode(_ mode: String?) -> Color {
        switch mode {
        case ACMode.dry: Color(red: 0.49, green: 0.88, blue: 0.76)
        case ACMode.auto: Color(red: 0.73, green: 0.69, blue: 1.00)
        case ACMode.heat: Color(red: 1.00, green: 0.66, blue: 0.40)
        case ACMode.fan: Color(white: 0.92)
        default: .accentColor
        }
    }

    /// Saturated hues, then soft ones, like the Home app's swatches.
    static let swatches: [LightColor] = [0, 30, 55, 120, 190, 230, 275, 320].map { LightColor(hue: $0, saturation: 1) }
        + [0, 40, 60, 140, 200, 240, 280, 330].map { LightColor(hue: $0, saturation: 0.35) }

    static func swatch(_ color: LightColor) -> Color {
        Color(hue: color.hue / 360, saturation: color.saturation, brightness: 1)
    }

    /// The light reports its color rounded, so a swatch counts as selected when it's near.
    static func close(_ a: LightColor, _ b: LightColor) -> Bool {
        let hue = abs(a.hue - b.hue).truncatingRemainder(dividingBy: 360)
        return min(hue, 360 - hue) < 8 && abs(a.saturation - b.saturation) < 0.1
    }

    /// Opens a screen: LG air conditioners, and lights that dim or change color.
    static func opens(_ device: HomeDevice) -> Bool {
        guard device.isOnline else { return false }
        return (device.kind == .airConditioner && device.provider == .lg) || device.hasRemote
            || device.canDim || device.hasColor || device.hasLiveVideo
    }
}
