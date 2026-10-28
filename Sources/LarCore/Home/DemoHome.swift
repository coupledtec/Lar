import Foundation

/// A made-up home, to try the app without any account (and for App Review and screenshots): a few devices of each
/// kind that answer the commands as real ones would, kept in memory until the app quits.
public enum DemoHome {
    /// On while the owner chose to try it (or the app was launched with `-LarDemo YES`).
    public static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "LarDemo") || (Preferences.bool(forKey: "demoMode") ?? false) }
        set {
            Preferences.set(newValue ? true : nil, forKey: "demoMode")
            if !newValue { UserDefaults.standard.removeObject(forKey: "LarDemo") }
        }
    }

    /// One provider per account kind, sharing the same home.
    public static func providers() -> [any DeviceProvider] {
        let state = State()
        return Provider.allCases.map { DemoProvider(provider: $0, state: state) }
    }

    static let devices: [HomeDevice] = [
        HomeDevice(provider: .lg, rawID: "ac", name: tr("Ar da sala"), kind: .airConditioner, isOn: true,
                   detail: tr("Ambiente 26° · ajustado em 22°")),
        HomeDevice(provider: .lg, rawID: "washer", name: tr("Lavadora"), kind: .laundry, isOn: true,
                   detail: tr("Enxaguando · faltam 0:12")),
        HomeDevice(provider: .tuya, rawID: "lamp", name: tr("Luminária"), kind: .light, isOn: true, brightness: 0.6,
                   color: LightColor(hue: 30, saturation: 0.8)),
        HomeDevice(provider: .tuya, rawID: "porch", name: tr("Luz da varanda"), kind: .light, isOn: false, brightness: 1),
        HomeDevice(provider: .tuya, rawID: "plug", name: tr("Cafeteira"), kind: .plug, isOn: false),
        HomeDevice(provider: .smartThings, rawID: "soundbar", name: "Soundbar", kind: .speaker, isOn: false),
        HomeDevice(provider: .smartThings, rawID: "fan", name: tr("Ventilador"), kind: .fan, isOn: false),
        HomeDevice(provider: .androidTV, rawID: "tv", name: "TV", kind: .tv, isOn: true, detail: "YouTube"),
        HomeDevice(provider: .xbox, rawID: "console", name: "Xbox", kind: .gameConsole, isOn: true, detail: "Minecraft"),
    ]

    /// The sample home's LG air conditioner: its full panel, answering in memory.
    @MainActor
    public static func airConditioner() -> ACStore {
        let caps = ACCapabilities(
            modes: [ACMode.fan, ACMode.dry, ACMode.auto, ACMode.cool], fanSpeeds: ["LOW", "MID", "HIGH", "AUTO"],
            minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        let status = ACStatus(isOn: true, mode: ACMode.cool, currentTemperature: 26, targetTemperature: 22,
                              fanSpeed: "AUTO", swing: false, eco: false)
        return ACStore(previewStatus: status, capabilities: caps)
    }

    /// Scenes to try with the sample home (shown while it's on and there are none; saved only if one is edited).
    public static var scenes: [HomeScene] {
        func action(_ id: String, _ name: String, _ command: HomeCommand) -> HomeScene.Action {
            .init(deviceID: id, deviceName: name, command: command)
        }
        return [
            HomeScene(name: tr("Bom dia"), symbol: "sun.max.fill", actions: [
                action("tuya:plug", tr("Cafeteira"), .power(true)), action("tuya:lamp", tr("Luminária"), .power(true)),
            ]),
            HomeScene(name: tr("Cinema"), symbol: "film", actions: [
                action("androidTV:tv", "TV", .power(true)), action("tuya:lamp", tr("Luminária"), .brightness(0.2)),
                action("smartThings:soundbar", "Soundbar", .power(true)),
            ]),
            HomeScene(name: tr("Dormir"), symbol: "moon.fill", actions: [
                action("androidTV:tv", "TV", .power(false)), action("tuya:lamp", tr("Luminária"), .power(false)),
                action("lg:ac", tr("Ar da sala"), .temperature(24)),
            ]),
            HomeScene(name: tr("Sair de casa"), symbol: "door.left.hand.open", actions: [
                action("lg:ac", tr("Ar da sala"), .power(false)), action("tuya:lamp", tr("Luminária"), .power(false)),
                action("tuya:porch", tr("Luz da varanda"), .power(true)),
            ]),
        ]
    }

    actor State {
        var devices = DemoHome.devices

        func list(_ provider: Provider) -> [HomeDevice] { devices.filter { $0.provider == provider } }

        func apply(_ command: HomeCommand, to id: String) {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            switch command {
            case .power(let on): devices[index].isOn = on
            case .brightness(let value):
                devices[index].brightness = value
                devices[index].isOn = value > 0
            case .color(let color): devices[index].color = color
            case .temperature(let value):
                devices[index].detail = tr("Ambiente 26° · ajustado em \(Int(value.rounded()))°")
            }
        }
    }
}

struct DemoProvider: TVRemoteProvider {
    let provider: Provider
    let state: DemoHome.State

    func devices() async throws -> [HomeDevice] { await state.list(provider) }

    func send(_ command: HomeCommand, to device: HomeDevice) async throws {
        await state.apply(command, to: device.id)
    }

    func press(_ key: AndroidTVProvider.Key, on device: HomeDevice) async throws {}

    /// The usual apps, so the remote's grid isn't empty.
    func apps(on device: HomeDevice) async throws -> [AndroidTVProvider.App] { AndroidTVProvider.commonApps(current: nil) }
    func openApp(_ package: String, on device: HomeDevice) async throws {}
    func type(_ text: String, on device: HomeDevice) async throws {}
}
