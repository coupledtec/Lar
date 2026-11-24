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
        // Several houses (screenshots): "Casa" first and current, so the sample home's devices are in it.
        if withHouses, HomePlaces.all != demoPlaces {
            HomePlaces.all = demoPlaces
            HomePlaces.currentID = demoPlaces.first?.id
        }
        let state = State()
        return Provider.allCases.map { DemoProvider(provider: $0, state: state) }
    }

    static let devices: [HomeDevice] = [
        HomeDevice(provider: .lg, rawID: "ac", name: tr("Ar da sala"), kind: .airConditioner, isOn: true,
                   detail: tr("Ambiente 26° · ajustado em 22°"),
                   controls: ["targetTemperature": "22", "roomTemperatureValue": "26", "room": tr("Sala")]),
        HomeDevice(provider: .lg, rawID: "washer", name: tr("Lavadora"), kind: .laundry, isOn: true,
                   detail: tr("Enxaguando · faltam 0:12"),
                   controls: ["opt:run": "START|STOP", "optv:run": "START", "room": tr("Lavanderia")]),
        HomeDevice(provider: .tuya, rawID: "lamp", name: tr("Luminária"), kind: .light, isOn: true, brightness: 0.6,
                   color: LightColor(hue: 30, saturation: 0.8), controls: ["room": tr("Sala")]),
        HomeDevice(provider: .tuya, rawID: "porch", name: tr("Luz da varanda"), kind: .light, isOn: false, brightness: 1,
                   controls: ["room": tr("Varanda")]),
        HomeDevice(provider: .tuya, rawID: "plug", name: tr("Cafeteira"), kind: .plug, isOn: false, controls: ["room": tr("Cozinha")]),
        HomeDevice(provider: .smartThings, rawID: "soundbar", name: "Soundbar", kind: .speaker, isOn: false, controls: ["room": tr("Sala")]),
        HomeDevice(provider: .smartThings, rawID: "fan", name: tr("Ventilador"), kind: .fan, isOn: false, controls: ["room": tr("Quarto")]),
        HomeDevice(provider: .androidTV, rawID: "tv", name: "TV", kind: .tv, isOn: true, detail: "YouTube", controls: ["room": tr("Sala")]),
        HomeDevice(provider: .xbox, rawID: "console", name: "Xbox", kind: .gameConsole, isOn: true, detail: "Minecraft", controls: ["room": tr("Sala")]),
        HomeDevice(provider: .tuya, rawID: "robot", name: tr("Robô aspirador"), kind: .vacuum, isOn: false,
                   detail: tr("Carregado") + " · " + tr("bateria \(100)%"), controls: ["pausable": "1", "room": tr("Sala")]),
        HomeDevice(provider: .tuya, rawID: "door", name: tr("Porta da frente"), kind: .lock, isOn: true,
                   detail: tr("Trancada") + " · " + tr("Porta fechada") + " · " + tr("bateria \(88)%"),
                   controls: ["locked": "1", "lockable": "1", "room": tr("Entrada")]),
    ]

    /// Testing several houses (launched with `-LarDemoHouses YES`): two more air conditioners, each in a house of
    /// its own (their accounts say where), besides the sample home's.
    static var withHouses: Bool { UserDefaults.standard.bool(forKey: "LarDemoHouses") }

    static var demoPlaces: [HomePlace] { [
        HomePlace(id: "demo-casa", name: tr("Casa"), coordinate: Coordinate(latitude: -23.5614, longitude: -46.6559)),
        HomePlace(id: "demo-praia", name: tr("Praia"), coordinate: Coordinate(latitude: -23.9608, longitude: -46.3336)),
        HomePlace(id: "demo-sitio", name: tr("Sítio"), coordinate: Coordinate(latitude: -22.9056, longitude: -47.0608)),
    ] }

    static let houses: [HomeDevice] = [
        HomeDevice(provider: .smartThings, rawID: "sensor-casa", name: tr("Sensor da sala"), kind: .climateSensor,
                   controls: ["roomTemperatureValue": "27", "geo": "-23.5614,-46.6559", "placeName": tr("Casa"), "room": tr("Sala")]),
        HomeDevice(provider: .smartThings, rawID: "ac-praia", name: tr("Ar da praia"), kind: .airConditioner, isOn: true,
                   detail: tr("Ambiente 24° · ajustado em 21°"),
                   controls: ["targetTemperature": "21", "roomTemperatureValue": "24", "geo": "-23.9608,-46.3336", "placeName": tr("Praia")]),
        HomeDevice(provider: .tuya, rawID: "ac-sitio", name: tr("Ar do sítio"), kind: .airConditioner, isOn: false,
                   detail: tr("Ambiente 18°"),
                   controls: ["targetTemperature": "23", "roomTemperatureValue": "18", "geo": "-22.9056,-47.0608", "placeName": tr("Sítio")]),
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
        var devices = DemoHome.withHouses
            ? DemoHome.devices.map { device in
                var device = device
                // The sample home's devices are at "Casa".
                if device.geo == nil, device.kind == .airConditioner { device.controls["geo"] = "-23.5614,-46.6559" }
                return device
            } + DemoHome.houses
            : DemoHome.devices

        func list(_ provider: Provider) -> [HomeDevice] { devices.filter { $0.provider == provider } }

        func apply(_ command: HomeCommand, to id: String) {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            switch command {
            case .power(let on):
                devices[index].isOn = on
                if devices[index].kind == .lock {
                    devices[index].controls["locked"] = on ? "1" : "0"
                    devices[index].detail = (on ? tr("Trancada") : tr("Destrancada")) + " · " + tr("Porta fechada") + " · " + tr("bateria \(88)%")
                }
                if devices[index].kind == .vacuum {
                    devices[index].detail = (on ? tr("Limpando") : tr("Voltando à base")) + " · " + tr("bateria \(100)%")
                }
            case .brightness(let value):
                devices[index].brightness = value
                devices[index].isOn = value > 0
            case .color(let color): devices[index].color = color
            case .option(let name, let value):
                devices[index].controls["optv:" + name] = value
            case .whiteTemperature(let value):
                devices[index].controls["ct"] = String(value)
            case .pause:
                devices[index].isOn = false
                devices[index].detail = tr("Pausado") + " · " + tr("bateria \(100)%")
            case .temperature(let value):
                devices[index].controls["targetTemperature"] = String(Int(value.rounded()))
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
