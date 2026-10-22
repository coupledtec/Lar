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

/// Display names and icons for API values.
enum Labels {
    static func mode(_ mode: String?) -> String {
        switch mode {
        case ACMode.cool: "Frio"
        case ACMode.dry: "Seco"
        case ACMode.fan: "Ventilar"
        case ACMode.auto: "Auto"
        case ACMode.heat: "Calor"
        case let other?: other.capitalized
        case nil: "—"
        }
    }

    static func modeIcon(_ mode: String?) -> String {
        switch mode {
        case ACMode.cool: "snowflake"
        case ACMode.dry: "drop"
        case ACMode.fan: "fan"
        case ACMode.auto: "a.circle"
        case ACMode.heat: "sun.max"
        default: "snowflake"
        }
    }

    static func fan(_ speed: String?) -> String {
        switch speed {
        case "LOW": "Baixa"
        case "MID": "Média"
        case "HIGH": "Alta"
        case "AUTO": "Auto"
        case let other?: other.capitalized
        case nil: "—"
        }
    }

    /// What the unit is doing, e.g. "Resfriando até 18 °C".
    static func activity(_ status: ACStatus?, target: Double?) -> String {
        guard let status else { return "—" }
        guard status.isOn else { return "Desligado" }
        let goal = "\(temperature(target)) °C"
        return switch status.mode {
        case ACMode.cool: "Resfriando até \(goal)"
        case ACMode.heat: "Aquecendo até \(goal)"
        case ACMode.auto: "Auto · \(goal)"
        case ACMode.dry: "Desumidificando"
        case ACMode.fan: "Só ventilação"
        default: mode(status.mode)
        }
    }

    /// The unit's name, with the model added when two units share the same name.
    static func deviceName(_ device: ThinQDevice, among devices: [ThinQDevice]) -> String {
        let name = device.displayName
        let twins = devices.filter { $0.displayName == name }
        guard twins.count > 1, let model = device.deviceInfo.modelName else { return name }
        return "\(name) (\(model))"
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
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

extension Labels {
    static func kindTitle(_ kind: DeviceKind) -> String {
        switch kind {
        case .tv: "TVs"
        case .speaker: "Som"
        case .airConditioner: "Ar-condicionado"
        case .light: "Luzes"
        case .plug: "Tomadas e interruptores"
        case .fan: "Ventilação"
        case .camera: "Câmeras"
        case .laundry: "Lavanderia"
        case .kitchen: "Cozinha"
        case .climateSensor: "Sensores"
        case .other: "Outros"
        }
    }

    static func icon(_ kind: DeviceKind, on: Bool) -> String {
        switch kind {
        case .tv: on ? "tv.fill" : "tv"
        case .speaker: on ? "hifispeaker.fill" : "hifispeaker"
        case .airConditioner: on ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal"
        case .light: on ? "lightbulb.fill" : "lightbulb"
        case .plug: on ? "powerplug.fill" : "powerplug"
        case .fan: on ? "fan.fill" : "fan"
        case .camera: "video"
        case .laundry: "washer"
        case .kitchen: "refrigerator"
        case .climateSensor: "thermometer.medium"
        case .other: "square.grid.2x2"
        }
    }

    /// "Ligada · 60%", "Ambiente 26° · ajustado em 22°", "Offline · Smart Life".
    /// Always ends with where the data comes from ("… · SmartThings").
    static func subtitle(_ device: HomeDevice) -> String {
        // A TV says why it's out of reach (debugging off, waiting for approval…).
        guard device.isOnline else {
            let why = device.kind == .tv && !device.detail.isEmpty ? device.detail : "Offline"
            return "\(why) · \(device.provider.name)"
        }
        var parts: [String] = []
        // A cycle or a temperature already says what's going on; on/off is for what only switches.
        if let on = device.isOn, device.detail.isEmpty || [DeviceKind.light, .plug, .fan].contains(device.kind) {
            let female = [DeviceKind.light, .plug, .laundry, .tv].contains(device.kind)
            parts.append(on ? (female ? "Ligada" : "Ligado") : (female ? "Desligada" : "Desligado"))
            if on, let brightness = device.brightness { parts.append("\(Int((brightness * 100).rounded()))%") }
        }
        if !device.detail.isEmpty { parts.append(device.detail) }
        if device.kind == .camera { parts.append("Ao vivo") }
        parts.append(device.provider.name)
        return parts.joined(separator: " · ")
    }
}
