import Foundation

/// A setting with a few choices that a device's brand takes (an air conditioner's mode, fan and swing; a robot's
/// suction; a light's effect), kept in the device's controls so every brand adds its own without new fields:
/// "opt:<name>" lists the choices ("cool|heat|auto"), "optv:<name>" is the current one. Changed with
/// `HomeCommand.option`.
public struct DeviceOption: Identifiable, Sendable, Equatable {
    public var name: String
    public var values: [String]
    public var current: String?
    public var id: String { name }

    public var title: String { OptionText.title(name) }
    public func label(_ value: String) -> String { OptionText.value(name, value) }
}

extension HomeDevice {
    public var options: [DeviceOption] {
        controls.keys.filter { $0.hasPrefix("opt:") }.sorted().compactMap { key in
            let name = String(key.dropFirst(4))
            let values = (controls[key] ?? "").split(separator: "|").map(String.init)
            guard values.count > 1 else { return nil }
            return DeviceOption(name: name, values: values, current: controls["optv:" + name])
        }
    }

    /// Declares an option (its choices and the current one).
    public mutating func setOption(_ name: String, values: [String], current: String?) {
        let values = values.filter { !$0.isEmpty }
        guard values.count > 1 else { return }
        controls["opt:" + name] = values.joined(separator: "|")
        if let current { controls["optv:" + name] = current }
    }

    public func option(_ name: String) -> String? { controls["optv:" + name] }
}

/// The options' names and choices in words. Brands name them their own way ("cold", "cool", "COOL"): the known ones
/// get a common word, anything else shows as the brand sends it.
public enum OptionText {
    public static func title(_ name: String) -> String {
        switch name {
        case "mode", "airConditionerMode", "work_mode": tr("Modo")
        case "fan", "fanMode", "windspeed", "fan_speed_enum", "fan_speed": tr("Ventilação")
        case "swing", "fanOscillationMode", "switch_horizontal", "switch_vertical": tr("Direção do ar")
        case "suction", "turbo", "robotCleanerTurboMode": tr("Potência")
        case "cleaningMode", "robotCleanerCleaningMode": tr("Limpeza")
        case "cistern", "water": tr("Água do pano")
        case "effect", "scene": tr("Efeito")
        case "run": tr("Ciclo")
        case "room": tr("Limpar cômodo")
        default: name
        }
    }

    public static func value(_ name: String, _ value: String) -> String {
        if name == "run" { return value == "START" ? tr("Rodando") : tr("Pausado") }
        // "17=Sala": the room's name.
        if name == "room" { return String(value.split(separator: "=", maxSplits: 1).last ?? Substring(value)) }
        return switch value.lowercased() {
        case "cool", "cold", "cooling": tr("Frio")
        case "heat", "hot", "heating": tr("Quente")
        case "auto", "smart": tr("Automático")
        case "dry", "wet", "dehumidify", "dehumidification": tr("Desumidificar")
        case "fan", "wind", "fanonly", "fan_only": tr("Ventilar")
        case "eco", "energysaving": tr("Econômico")
        case "low", "quiet", "silence", "gentle", "101": tr("Baixa")
        case "medium", "mid", "normal", "standard", "102", "balanced": tr("Média")
        case "high", "strong", "turbo", "103": tr("Alta")
        case "max", "104", "maximum": tr("Máxima")
        case "on": tr("Ligado")
        case "off": tr("Desligado")
        case "fixed", "stop": tr("Parado")
        case "all", "swing": tr("Oscilando")
        case "vertical": tr("Vertical")
        case "horizontal": tr("Horizontal")
        case "part": tr("Área")
        case "repeat": tr("Repetir")
        case "manual": tr("Manual")
        case "map": tr("Mapa")
        case "white": tr("Branco")
        case "colour", "color": tr("Cor")
        case "music": tr("Música")
        case "true": tr("Sim")
        case "false": tr("Não")
        default: value
        }
    }
}
