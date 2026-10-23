import Foundation

/// Words for API values that the core puts in a device's detail line.
public enum HomeText {
    /// A washer's, dryer's or robot's cycle, in words.
    public static func cycle(_ state: String) -> String {
        switch state.uppercased() {
        case "POWER_OFF": "Desligada"
        case "INITIAL", "READY": "Pronta"
        case "RUNNING", "RUN": "Funcionando"
        case "WASHING": "Lavando"
        case "RINSING": "Enxaguando"
        case "SPINNING": "Centrifugando"
        case "DRYING": "Secando"
        case "COOLING": "Resfriando"
        case "PAUSE", "PAUSED": "Pausada"
        case "END", "COMPLETE": "Terminou"
        case "RESERVED": "Agendada"
        case "ERROR": "Erro"
        case "STOP": "Parada"
        default:
            state.lowercased().replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }

    /// "faltam 1:05" from hours and minutes left; nil when nothing is left.
    public static func timeLeft(hours: Int, minutes: Int) -> String? {
        guard hours > 0 || minutes > 0 else { return nil }
        return "faltam \(hours):" + String(format: "%02d", minutes)
    }

    public static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
    /// A number as stored in a device's controls: "23" or "23.5".
    public static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
