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
                    return Self.device(robot, status: status)
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
        return HomeDevice(provider: .roborock, rawID: robot.duid, name: robot.name, kind: .vacuum,
                          isOnline: robot.online, isOn: status.map { RoborockClient.isCleaning($0.state) },
                          detail: parts.joined(separator: " · "))
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command,
              let robot = try await client.robots().first(where: { $0.duid == device.rawID }) else {
            throw ProviderError.unsupported
        }
        try await client.command(on ? "app_start" : "app_charge", on: robot)
    }
}
