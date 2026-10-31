import Foundation

/// Mi Home's robot vacuums and locks in the list (the other Mi Home devices stay out: lights and plugs come from the
/// accounts Lar already has). A robot: on is cleaning, off is back to the dock.
public struct XiaomiProvider: DeviceProvider {
    public let provider = Provider.xiaomi
    let client: XiaomiClient

    public func devices() async throws -> [HomeDevice] {
        let devices = try await client.devices()
        let maps = try await client.maps(for: Set(devices.map(\.model)))
        return await withTaskGroup(of: HomeDevice?.self) { group in
            for device in devices {
                guard let map = maps[device.model] else { continue }
                group.addTask {
                    let values = device.online ? ((try? await client.read(map.properties, of: device)) ?? [:]) : [:]
                    return map.device(provider: .xiaomi, id: device.did, name: device.name, online: device.online, values: values)
                }
            }
            var out: [HomeDevice] = []
            for await device in group { if let device { out.append(device) } }
            return out.sorted { $0.name < $1.name }
        }
    }

    public func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        guard case .power(let on) = command, device.kind == .vacuum,
              let target = try await client.devices().first(where: { $0.did == device.rawID }),
              let map = try await client.maps(for: [target.model])[target.model],
              let action = on ? map.start : map.dock else { throw ProviderError.unsupported }
        try await client.run(action, on: target)
    }
}
