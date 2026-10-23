import AppIntents
import Foundation
import LarCore

/// The app's model for Siri and Shortcuts, which may run with no window (the app launched in the background).
@MainActor
enum IntentContext {
    static var model: LarModel?
    /// Makes the model where there's no app around it (the widgets' process).
    static var makeModel: (@MainActor () -> LarModel)?

    /// The model with the devices read at least once.
    static func ready() async throws -> LarModel {
        if model == nil { model = makeModel?() }
        guard let model else { throw IntentError.message("Abra o Lar uma vez e tente de novo.") }
        if model.home.devices.isEmpty { await model.home.refresh() }
        return model
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        }
    }
}

// MARK: Scenes

struct SceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cena"
    static let defaultQuery = SceneQuery()

    var id: UUID
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    init(_ scene: HomeScene) {
        id = scene.id
        name = scene.name
        symbol = scene.symbol
    }
}

struct SceneQuery: EntityQuery {
    @MainActor
    private func scenes() -> [HomeScene] {
        if IntentContext.model == nil { IntentContext.model = IntentContext.makeModel?() }
        IntentContext.model?.scenes.reload()
        return IntentContext.model?.scenes.scenes ?? []
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SceneEntity] {
        scenes().filter { identifiers.contains($0.id) }.map(SceneEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SceneEntity] {
        scenes().map(SceneEntity.init)
    }
}

struct RunSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Executar cena"
    static let description = IntentDescription("Executa uma cena do Lar: vários aparelhos de uma vez.")

    @Parameter(title: "Cena")
    var scene: SceneEntity

    init() {}

    init(scene: SceneEntity) {
        self.scene = scene
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentContext.ready()
        guard let saved = model.scenes.scene(id: scene.id) else { throw IntentError.message("Essa cena não existe mais.") }
        let problem = model.home.run(saved)
        await model.home.waitUntilSent()
        return .result(dialog: "\(problem ?? "\(saved.name): pronto.")")
    }
}

// MARK: Devices

struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Aparelho"
    static let defaultQuery = DeviceQuery()

    var id: String
    var name: String
    var detail: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: .init(systemName: symbol))
    }

    init(_ device: HomeDevice) {
        id = device.id
        name = device.name
        detail = Labels.subtitle(device)
        symbol = Labels.icon(device.kind, on: false)
    }
}

struct DeviceQuery: EntityStringQuery {
    @MainActor
    private func switchable() async -> [HomeDevice] {
        guard let model = try? await IntentContext.ready() else { return [] }
        return model.home.devices.filter { $0.isOn != nil && $0.kind != .camera }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        await switchable().filter { identifiers.contains($0.id) }.map(DeviceEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [DeviceEntity] {
        await switchable().filter { $0.name.localizedStandardContains(string) }.map(DeviceEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [DeviceEntity] {
        await switchable().map(DeviceEntity.init)
    }
}

/// Shared by "Ligar", "Desligar" and the widgets.
@MainActor
func switchDevice(_ entity: DeviceEntity, on: Bool) async throws -> String {
    let model = try await IntentContext.ready()
    guard let device = model.home.device(id: entity.id) else { throw IntentError.message("\(entity.name) não foi encontrado.") }
    guard device.canSwitch else { throw IntentError.message("\(device.name) está fora do ar.") }
    model.home.perform(.power(on), on: device.id)
    await model.home.waitUntilSent()
    if let problem = model.home.transientMessage { throw IntentError.message(problem) }
    return "\(device.name): \(on ? "ligando" : "desligando")."
}

struct TurnOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Ligar aparelho"
    @Parameter(title: "Aparelho") var device: DeviceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await switchDevice(device, on: true))")
    }
}

struct TurnOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Desligar aparelho"
    @Parameter(title: "Aparelho") var device: DeviceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await switchDevice(device, on: false))")
    }
}

// MARK: Air conditioner

/// Sets an air conditioner's target, switching it on first when it's off.
@MainActor
func setTemperature(_ entity: DeviceEntity, to target: Double) async throws -> String {
    let model = try await IntentContext.ready()
    guard let device = model.home.device(id: entity.id), device.acceptsTemperature else {
        throw IntentError.message("\(entity.name) não aceita temperatura.")
    }
    let value = min(max(target, 16), 30)
    if device.isOn != true { model.home.perform(.power(true), on: device.id) }
    model.home.perform(.temperature(value), on: device.id)
    await model.home.waitUntilSent()
    return "\(device.name) em \(HomeText.degrees(value))."
}

struct SetACTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Ajustar temperatura do ar"
    static let description = IntentDescription("Liga o ar-condicionado, se preciso, e ajusta a temperatura.")

    @Parameter(title: "Ar-condicionado") var device: DeviceEntity
    @Parameter(title: "Temperatura", inclusiveRange: (16, 30)) var temperature: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await setTemperature(device, to: Double(temperature)))")
    }
}

/// The widget's − and + on an air conditioner.
struct AdjustACIntent: AppIntent {
    static let title: LocalizedStringResource = "Mudar temperatura do ar"
    static let isDiscoverable = false

    @Parameter(title: "Ar-condicionado") var device: DeviceEntity
    @Parameter(title: "Graus") var delta: Int

    init() {}

    init(device: DeviceEntity, delta: Int) {
        self.device = device
        self.delta = delta
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentContext.ready()
        let current = model.home.device(id: device.id)?.targetTemperature ?? 23
        _ = try await setTemperature(device, to: current + Double(delta))
        return .result()
    }
}

/// A widget's or Control Center's tap on a device: switches it to the other state.
struct ToggleDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Alternar aparelho"
    static let isDiscoverable = false

    @Parameter(title: "Aparelho") var device: DeviceEntity

    init() {}

    init(device: DeviceEntity) {
        self.device = device
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentContext.ready()
        guard let current = model.home.device(id: device.id), let on = current.isOn else {
            throw IntentError.message("\(device.name) não foi encontrado.")
        }
        _ = try await switchDevice(device, on: !on)
        return .result()
    }
}

// MARK: Control Center

#if os(iOS)

/// Control Center's scene button: which scene it runs is chosen when the control is added.
struct SceneControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Cena do Lar"
    static let isDiscoverable = false

    @Parameter(title: "Cena") var scene: SceneEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let scene else { throw IntentError.message("Escolha a cena do controle.") }
        _ = try await RunSceneIntent(scene: scene).perform()
        return .result()
    }
}

/// Which device a Control Center switch controls, chosen when the control is added.
struct DeviceControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Aparelho do Lar"
    static let isDiscoverable = false

    @Parameter(title: "Aparelho") var device: DeviceEntity?

    init() {}
}

/// Control Center's switch for a device: the system sets `value` to the new state.
struct DevicePowerControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Ligar ou desligar aparelho"
    static let isDiscoverable = false

    @Parameter(title: "Aparelho") var device: DeviceEntity?
    @Parameter(title: "Ligado") var value: Bool

    init() {}

    init(device: DeviceEntity?) {
        self.device = device
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let device else { throw IntentError.message("Escolha o aparelho do controle.") }
        _ = try await switchDevice(device, on: value)
        return .result()
    }
}
#endif
