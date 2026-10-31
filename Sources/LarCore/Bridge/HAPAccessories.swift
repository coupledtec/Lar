import Foundation

/// How a Lar device shows in the Home app. Each accessory has the information service (instances 1–7) and one main
/// service (instance 8) whose characteristics follow from 9 in a fixed order, so instance numbers never move.
enum HAPRole: Equatable {
    case light(dims: Bool, color: Bool)
    case outlet
    case fan
    case `switch`
    /// Power and target temperature (the air conditioners).
    case thermostat
    case temperatureSensor(humidity: Bool)
    /// Live video and stills (the Mac re-encodes the camera's stream).
    case camera

    init?(_ device: HomeDevice) {
        switch device.kind {
        case .camera:
            #if os(macOS)
            guard device.hasLiveVideo else { return nil }
            self = .camera
            #else
            return nil
            #endif
        case .light where device.isOn != nil: self = .light(dims: device.brightness != nil, color: device.color != nil)
        case .plug where device.isOn != nil: self = .outlet
        case .fan where device.isOn != nil: self = .fan
        case .airConditioner where device.isOn != nil && device.acceptsTemperature: self = .thermostat
        case .climateSensor where device.controls["temperatureValue"] != nil:
            self = .temperatureSensor(humidity: device.controls["humidityValue"] != nil)
        default:
            guard device.isOn != nil else { return nil }
            self = .switch
        }
    }

    var category: Int {
        switch self {
        case .light: 5
        case .outlet: 7
        case .fan: 3
        case .switch: 8
        case .thermostat: 9
        case .temperatureSensor: 10
        case .camera: 17
        }
    }

    /// A short signature, for the configuration number.
    var signature: String {
        switch self {
        case .light(let dims, let color): "l\(dims ? 1 : 0)\(color ? 1 : 0)"
        case .outlet: "o"
        case .fan: "f"
        case .switch: "s"
        case .thermostat: "t"
        case .temperatureSensor(let humidity): "h\(humidity ? 1 : 0)"
        case .camera: "c"
        }
    }
}

/// One characteristic: its HomeKit type (Apple's short form), format and permissions.
struct HAPCharacteristic {
    let iid: Int
    let type: String
    let format: String
    var perms: [String] = ["pr", "ev"]
    var unit: String?
    var range: (min: Double, max: Double, step: Double)?
    var validValues: [Int]?

    static let readWrite = ["pr", "pw", "ev"]
}

enum HAPStatus: Int {
    case ok = 0
    case insufficientPrivileges = -70401
    case communicationFailure = -70402
    case readOnly = -70404
    case writeOnly = -70405
    case notification = -70406
    case notFound = -70409
    case invalidValue = -70410
}

/// The characteristics of each role, their values from a device and the commands their writes become.
enum HAPAccessories {
    static let manufacturer = HomeAppDuplicates.bridgeManufacturer
    static let mainService = 8

    static func information(name: String, model: String, serial: String) -> [(HAPCharacteristic, Any)] {
        [
            (HAPCharacteristic(iid: 2, type: "14", format: "bool", perms: ["pw"]), NSNull()),
            (HAPCharacteristic(iid: 3, type: "20", format: "string", perms: ["pr"]), manufacturer),
            (HAPCharacteristic(iid: 4, type: "21", format: "string", perms: ["pr"]), model),
            (HAPCharacteristic(iid: 5, type: "23", format: "string", perms: ["pr"]), name),
            (HAPCharacteristic(iid: 6, type: "30", format: "string", perms: ["pr"]), serial),
            (HAPCharacteristic(iid: 7, type: "52", format: "string", perms: ["pr"]), "1.0"),
        ]
    }

    static func serviceType(_ role: HAPRole) -> String {
        switch role {
        case .light: "43"
        case .outlet: "47"
        case .fan: "40"
        case .switch: "49"
        case .thermostat: "4A"
        case .temperatureSensor: "8A"
        case .camera: "110"
        }
    }

    static func characteristics(_ role: HAPRole) -> [HAPCharacteristic] {
        let on = HAPCharacteristic(iid: 9, type: "25", format: "bool", perms: HAPCharacteristic.readWrite)
        switch role {
        case .light(let dims, let color):
            var list = [on]
            if dims {
                list.append(HAPCharacteristic(iid: 10, type: "8", format: "int", perms: HAPCharacteristic.readWrite,
                                              unit: "percentage", range: (0, 100, 1)))
            }
            if color {
                list.append(HAPCharacteristic(iid: 11, type: "13", format: "float", perms: HAPCharacteristic.readWrite,
                                              unit: "arcdegrees", range: (0, 360, 1)))
                list.append(HAPCharacteristic(iid: 12, type: "2F", format: "float", perms: HAPCharacteristic.readWrite,
                                              unit: "percentage", range: (0, 100, 1)))
            }
            return list
        case .outlet:
            return [on, HAPCharacteristic(iid: 10, type: "26", format: "bool")]
        case .fan, .switch:
            return [on]
        case .thermostat:
            return [
                HAPCharacteristic(iid: 9, type: "F", format: "uint8", validValues: [0, 2]),
                HAPCharacteristic(iid: 10, type: "33", format: "uint8", perms: HAPCharacteristic.readWrite,
                                  validValues: [0, 2]),
                HAPCharacteristic(iid: 11, type: "11", format: "float", unit: "celsius", range: (-50, 100, 0.1)),
                HAPCharacteristic(iid: 12, type: "35", format: "float", perms: HAPCharacteristic.readWrite,
                                  unit: "celsius", range: (16, 30, 0.5)),
                HAPCharacteristic(iid: 13, type: "36", format: "uint8", perms: HAPCharacteristic.readWrite,
                                  validValues: [0, 1]),
            ]
        case .temperatureSensor:
            return [HAPCharacteristic(iid: 9, type: "11", format: "float", unit: "celsius", range: (-50, 100, 0.1))]
        case .camera:
            #if os(macOS)
            return HAPCameras.characteristics
            #else
            return []
            #endif
        }
    }

    /// The humidity sensor beside a thermometer that has one (service 20).
    static let humidityService = 20
    static let humidity = HAPCharacteristic(iid: 21, type: "10", format: "float", unit: "percentage", range: (0, 100, 1))

    static func value(_ iid: Int, of device: HomeDevice, role: HAPRole) -> Any? {
        switch (role, iid) {
        case (.thermostat, 9), (.thermostat, 10): return device.isOn == true ? 2 : 0
        case (.thermostat, 11): return device.roomTemperature ?? device.targetTemperature ?? 0
        case (.thermostat, 12): return min(30, max(16, device.targetTemperature ?? 24))
        case (.thermostat, 13): return 0
        case (.temperatureSensor, 9): return device.controls["temperatureValue"].flatMap(Double.init) ?? 0
        case (.temperatureSensor, 21): return device.controls["humidityValue"].flatMap(Double.init) ?? 0
        case (_, 9): return device.isOn == true
        case (.light, 10): return Int(((device.brightness ?? 1) * 100).rounded())
        case (.light, 11): return (device.color?.hue ?? 0).rounded()
        case (.light, 12): return ((device.color?.saturation ?? 0) * 100).rounded()
        case (.outlet, 10): return device.isOn == true
        default: return nil
        }
    }

    /// The command a write makes; `color` gathers a hue and a saturation written together.
    static func command(_ iid: Int, value: Any, device: HomeDevice, role: HAPRole, color: inout LightColor?) -> HomeCommand?? {
        let number = (value as? NSNumber)?.doubleValue ?? (value as? Bool).map { $0 ? 1 : 0 }
        switch (role, iid) {
        case (.thermostat, 10):
            guard let number else { return nil }
            return .some(.power(number != 0))
        case (.thermostat, 12):
            guard let number else { return nil }
            return .some(.temperature((number * 2).rounded() / 2))
        case (.thermostat, 13):
            return .some(nil)
        case (_, 9) where role != .thermostat:
            guard let number else { return nil }
            return .some(.power(number != 0))
        case (.light, 10):
            guard let number else { return nil }
            return .some(number <= 0 ? .power(false) : .brightness(min(1, max(0.01, number / 100))))
        case (.light, 11), (.light, 12):
            guard let number else { return nil }
            var next = color ?? device.color ?? LightColor(hue: 0, saturation: 1)
            if iid == 11 { next.hue = min(360, max(0, number)) } else { next.saturation = min(1, max(0, number / 100)) }
            color = next
            return .some(nil)
        default:
            return nil
        }
    }

    static func json(_ characteristic: HAPCharacteristic, value: Any?) -> [String: Any] {
        var out: [String: Any] = [
            "iid": characteristic.iid, "type": characteristic.type, "format": characteristic.format,
            "perms": characteristic.perms,
        ]
        if characteristic.perms.contains("pr") { out["value"] = value ?? NSNull() }
        if let unit = characteristic.unit { out["unit"] = unit }
        if let range = characteristic.range {
            out["minValue"] = range.min
            out["maxValue"] = range.max
            out["minStep"] = range.step
        }
        if let values = characteristic.validValues { out["valid-values"] = values }
        return out
    }

    /// The name the Home app accepts: letters, digits, spaces and a few marks, starting and ending with a letter or
    /// a digit.
    static func cleanName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " '-.,"))
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
        clean = clean.split(separator: " ").joined(separator: " ")
        while let first = clean.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) { clean.removeFirst() }
        while let last = clean.unicodeScalars.last, !CharacterSet.alphanumerics.contains(last) { clean.removeLast() }
        return clean.isEmpty ? "Lar" : String(clean.prefix(64))
    }
}
