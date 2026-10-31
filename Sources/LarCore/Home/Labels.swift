import Foundation

/// Words and SF Symbols for devices and API values, shared by the Mac, iPhone and Watch apps.
public enum Labels {
    public static func mode(_ mode: String?) -> String {
        switch mode {
        case ACMode.cool: tr("Frio")
        case ACMode.dry: tr("Seco")
        case ACMode.fan: tr("Ventilar")
        case ACMode.auto: tr("Auto")
        case ACMode.heat: tr("Calor")
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
        case "LOW": tr("Baixa")
        case "MID": tr("Média")
        case "HIGH": tr("Alta")
        case "AUTO": tr("Auto")
        case let other?: other.capitalized
        case nil: "—"
        }
    }

    /// What the unit is doing, e.g. "Resfriando até 18 °C".
    public static func activity(_ status: ACStatus?, target: Double?) -> String {
        guard let status else { return "—" }
        guard status.isOn else { return tr("Desligado") }
        let goal = "\(temperature(target)) °C"
        return switch status.mode {
        case ACMode.cool: tr("Resfriando até \(goal)")
        case ACMode.heat: tr("Aquecendo até \(goal)")
        case ACMode.auto: "Auto · \(goal)"
        case ACMode.dry: tr("Desumidificando")
        case ACMode.fan: tr("Só ventilação")
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
        case .tv: tr("TVs")
        case .gameConsole: tr("Jogos")
        case .vacuum: tr("Limpeza")
        case .lock: tr("Fechaduras")
        case .speaker: tr("Som")
        case .airConditioner: tr("Ar-condicionado")
        case .light: tr("Luzes")
        case .plug: tr("Tomadas e interruptores")
        case .fan: tr("Ventilação")
        case .camera: tr("Câmeras")
        case .laundry: tr("Lavanderia")
        case .kitchen: tr("Cozinha")
        case .climateSensor: tr("Sensores")
        case .other: tr("Outros")
        }
    }

    /// What VoiceOver says for a remote's arrow.
    public static func direction(_ key: AndroidTVProvider.Key) -> String {
        switch key {
        case .up: tr("Para cima")
        case .down: tr("Para baixo")
        case .left: tr("Para a esquerda")
        case .right: tr("Para a direita")
        default: "Tecla"
        }
    }

    /// What VoiceOver says for a scene's symbol.
    public static func sceneSymbol(_ symbol: String) -> String {
        [
            "sparkles": tr("Brilhos"), "moon.fill": tr("Lua"), "sun.max.fill": tr("Sol"), "house.fill": tr("Casa"),
            "door.left.hand.open": tr("Porta"), "bed.double.fill": tr("Cama"), "tv": tr("TV"), "film": tr("Filme"),
            "fork.knife": tr("Refeição"), "book.fill": tr("Livro"), "figure.walk": tr("Caminhada"), "snowflake": tr("Frio"),
        ][symbol] ?? symbol
    }

    public static func icon(_ kind: DeviceKind, on: Bool) -> String {
        switch kind {
        case .tv: on ? "tv.fill" : "tv"
        case .gameConsole: on ? "gamecontroller.fill" : "gamecontroller"
        case .vacuum: on ? "robotic.vacuum.fill" : "robotic.vacuum"
        case .lock: "lock.fill"
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
            let why = [DeviceKind.tv, .gameConsole].contains(device.kind) && !device.detail.isEmpty ? device.detail : tr("Offline")
            return "\(why) · \(device.provider.name)"
        }
        var parts: [String] = []
        // A cycle or a temperature already says what's going on; on/off is for what only switches.
        if let on = device.isOn, device.detail.isEmpty || [DeviceKind.light, .plug, .fan].contains(device.kind) {
            let female = [DeviceKind.light, .plug, .laundry, .tv].contains(device.kind)
            parts.append(on ? (female ? tr("Ligada") : tr("Ligado")) : (female ? tr("Desligada") : tr("Desligado")))
            if on, let brightness = device.brightness { parts.append("\(Int((brightness * 100).rounded()))%") }
        }
        if !device.detail.isEmpty { parts.append(device.detail) }
        if device.kind == .camera { parts.append(tr("Ao vivo")) }
        parts.append(device.provider.name)
        return parts.joined(separator: " · ")
    }
}
