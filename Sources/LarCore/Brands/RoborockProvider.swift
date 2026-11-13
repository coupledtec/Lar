import Foundation

/// Roborock's robot vacuums in the list: on is cleaning, off is back to the dock; the state and the battery in the
/// detail. A robot that doesn't answer keeps what the home's data last said.
public struct RoborockProvider: DeviceProvider {
    public let provider = Provider.roborock
    let client: RoborockClient

    public func devices() async throws -> [HomeDevice] {
        let robots = try await client.robots()
        return await withTaskGroup(of: HomeDevice.self) { group in
            for robot in robots {
                group.addTask {
                    var status = robot.state.map { RoborockClient.Status(state: $0, battery: robot.battery) }
                    if robot.online, let live = try? await client.status(of: robot) { status = live }
                    var device = Self.device(robot, status: status)
                    // The rooms it can clean one by one.
                    if robot.version == "1.0", robot.online {
                        let segments = await client.segments(of: robot)
                        device.setOption("room", values: segments, current: nil)
                    }
                    return device
                }
            }
            var out: [HomeDevice] = []
            for await device in group { out.append(device) }
            return out.sorted { $0.name < $1.name }
        }
    }

    static func device(_ robot: RoborockClient.Robot, status: RoborockClient.Status?) -> HomeDevice {
        var parts: [String] = []
        if let status {
            parts.append(RoborockClient.stateText(status.state))
            if let battery = status.battery { parts.append(tr("bateria \(battery)%")) }
        }
        if robot.version != "1.0" { parts.append(tr("só o estado (modelo sem controle no Lar)")) }
        var device = HomeDevice(provider: .roborock, rawID: robot.duid, name: robot.name, kind: .vacuum,
                                isOnline: robot.online, isOn: status.map { RoborockClient.isCleaning($0.state) },
                                detail: parts.joined(separator: " · "), controls: robot.version == "1.0" ? ["pausable": "1"] : [:])
        if let status, let problem = RoborockClient.errorText(status.error) { device.controls["problem"] = problem }
        if robot.version == "1.0", let power = status?.fanPower {
            device.setOption("suction", values: ["101", "102", "103", "104"], current: String(power))
        }
        return device
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard let robot = try await client.robots().first(where: { $0.duid == device.rawID }) else { throw ProviderError.unsupported }
        switch command {
        case .power(let on): try await client.command(on ? "app_start" : "app_charge", on: robot)
        case .pause: try await client.command("app_pause", on: robot)
        case .option("room", let value):
            guard let segment = Int(value.split(separator: "=").first ?? "") else { throw ProviderError.unsupported }
            try await client.command("app_segment_clean", params: [["segments": [segment], "repeat": 1]], on: robot)
        case .option("suction", let value):
            guard let power = Int(value) else { throw ProviderError.unsupported }
            try await client.command("set_custom_mode", params: [power], on: robot)
        default: throw ProviderError.unsupported
        }
    }
}
