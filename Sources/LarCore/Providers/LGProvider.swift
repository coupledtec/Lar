import Foundation

/// Every device on the LG ThinQ account, through ThinQ Connect. Air conditioners are listed here too; their full
/// controls stay in ACStore, which the detail view drives.
public struct LGProvider: DeviceProvider {
    public let provider = Provider.lg
    let client: ThinQClient

    public init(client: ThinQClient) {
        self.client = client
    }

    public func devices() async throws -> [HomeDevice] {
        let listed: [ThinQDevice]
        do {
            listed = try await client.devices()
        } catch let error as ThinQError {
            throw Self.providerError(error)
        }
        var out: [HomeDevice] = []
        for item in listed {
            var device = HomeDevice(
                provider: .lg, rawID: item.deviceId, name: item.displayName, kind: Self.kind(item.deviceInfo.deviceType)
            )
            do {
                device = Self.applyState(try await client.rawState(deviceID: item.deviceId), to: device)
            } catch ThinQError.unauthorized {
                throw ProviderError.unauthorized
            } catch {
                device.isOnline = false
            }
            out.append(device)
        }
        return out
    }

    static func kind(_ type: String) -> DeviceKind {
        if type.contains("AIR_CONDITIONER") { return .airConditioner }
        if type.contains("WASH") || type.contains("DRYER") || type.contains("STYLER") { return .laundry }
        if type.contains("REFRIGERATOR") || type.contains("WINE") || type.contains("OVEN") || type.contains("COOKTOP")
            || type.contains("DISH") || type.contains("MICROWAVE") { return .kitchen }
        if type.contains("PURIFIER") || type.contains("FAN") || type.contains("VENTILATOR")
            || type.contains("HUMIDIFIER") { return .fan }
        return .other
    }

    /// Power from any "…OperationMode" that is POWER_ON/OFF; the detail is the cycle and time left, or the
    /// room's temperature.
    static func applyState(_ state: JSONValue, to device: HomeDevice) -> HomeDevice {
        var device = device
        // Washers report one state per drum: the first one.
        let state = state.array?.first ?? state
        if case .object(let operation)? = state["operation"] {
            for key in operation.keys.sorted() where key.hasSuffix("OperationMode") {
                let value = operation[key]?.string
                if value == "POWER_ON" || value == "POWER_OFF" {
                    device.controls["operation"] = key
                    device.isOn = value == "POWER_ON"
                    break
                }
            }
        }
        var parts: [String] = []
        if let run = state["runState"]?["currentState"]?.string, device.kind != .airConditioner {
            parts.append(HomeText.cycle(run))
            let timer = state["timer"]
            if let left = HomeText.timeLeft(hours: Int(timer?["remainHour"]?.double ?? 0),
                                            minutes: Int(timer?["remainMinute"]?.double ?? 0)) {
                parts.append(left)
            }
        }
        let status = ACStatus(json: state)
        if device.kind == .airConditioner {
            if let room = status.currentTemperature { parts.append("Ambiente \(HomeText.degrees(room))") }
            if status.isOn, let target = status.targetTemperature { parts.append("ajustado em \(HomeText.degrees(target))") }
        } else if parts.isEmpty, let room = status.currentTemperature {
            parts.append(HomeText.degrees(room))
        }
        device.detail = parts.joined(separator: " · ")
        return device
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command, let key = device.controls["operation"] else {
            throw ProviderError.unsupported
        }
        do {
            try await client.control(deviceID: device.rawID, payload: ["operation": [key: .string(on ? "POWER_ON" : "POWER_OFF")]])
        } catch let error as ThinQError {
            throw Self.providerError(error)
        }
    }

    static func providerError(_ error: ThinQError) -> ProviderError {
        switch error {
        case .unauthorized: .unauthorized
        case .network(let message): .network(message)
        default: .api(error.message)
        }
    }
}
