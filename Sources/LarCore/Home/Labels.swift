import Foundation

/// Words and SF Symbols for devices and API values, shared by the Mac, iPhone and Watch apps.
public enum Labels {
    public static func mode(_ mode: String?) -> String {
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

    public static func modeIcon(_ mode: String?) -> String {
        switch mode {
        case ACMode.cool: "snowflake"
        case ACMode.dry: "drop"
        case ACMode.fan: "fan"
        case ACMode.auto: "a.circle"
        case ACMode.heat: "sun.max"
        default: "snowflake"
        }
    }

    public static func fan(_ speed: String?) -> String {
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
    public static func activity(_ status: ACStatus?, target: Double?) -> String {
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
    public static func deviceName(_ device: ThinQDevice, among devices: [ThinQDevice]) -> String {
        let name = device.displayName
        let twins = devices.filter { $0.displayName == name }
        guard twins.count > 1, let model = device.deviceInfo.modelName else { return name }
        return "\(name) (\(model))"
    }

    public static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
    public static func kindTitle(_ kind: DeviceKind) -> String {
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

    public static func icon(_ kind: DeviceKind, on: Bool) -> String {
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
    public static func subtitle(_ device: HomeDevice) -> String {
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
