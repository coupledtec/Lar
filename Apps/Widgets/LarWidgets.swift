import AppIntents
import LarCore
import SwiftUI
import WidgetKit

@main
struct LarWidgetBundle: WidgetBundle {
    init() {
        // The widgets' own process: the same accounts, read from the shared keychain group.
        IntentContext.makeModel = { LarModel(settings: AppSettings(), includeTVs: true) }
    }

    var body: some Widget {
        ScenesWidget()
        FavoritesWidget()
        SceneControl()
        DeviceControl()
        LaundryLiveActivity()
    }
}

// MARK: Timeline

struct HomeEntry: TimelineEntry {
    var date: Date
    var scenes: [HomeScene]
    var devices: [HomeDevice]
    var favorites: Set<String>

    /// The favorites, or the first devices that switch when there are none.
    var shortcuts: [HomeDevice] {
        let switchable = devices.filter { $0.isOn != nil && $0.kind != .camera }
        let favorite = switchable.filter { favorites.contains($0.id) }
        return favorite.isEmpty ? switchable : favorite
    }

    static let placeholder = HomeEntry(
        date: Date(),
        scenes: [HomeScene(name: "Dormir", symbol: "moon.fill", actions: []), HomeScene(name: "Cinema", symbol: "film", actions: [])],
        devices: [HomeDevice(provider: .tuya, rawID: "1", name: "Luz da sala", kind: .light, isOn: true),
                  HomeDevice(provider: .androidTV, rawID: "2", name: "TV", kind: .tv, isOn: false)],
        favorites: []
    )
}

struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(Self.saved() ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task { @MainActor in
            let entry = await Self.live() ?? Self.saved() ?? .placeholder
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }

    /// What the app saved last.
    static func saved() -> HomeEntry? {
        let scenes = AppSettings().scenes
        guard let snapshot = WidgetSnapshot.load() else {
            return scenes.isEmpty ? nil : HomeEntry(date: Date(), scenes: scenes, devices: [], favorites: [])
        }
        return HomeEntry(date: snapshot.date, scenes: scenes, devices: snapshot.devices, favorites: snapshot.favorites)
    }

    /// A fresh read of the accounts, when it answers in time.
    @MainActor
    static func live() async -> HomeEntry? {
        guard let model = try? await IntentContext.ready() else { return nil }
        await model.home.refresh()
        let devices = model.home.sections(grouping: .kind).flatMap(\.devices)
        guard !devices.isEmpty else { return nil }
        WidgetSnapshot.save(from: model.home)
        return HomeEntry(date: Date(), scenes: model.scenes.scenes, devices: devices,
                         favorites: Set(model.home.customizations.filter { $0.value.isFavorite }.keys))
    }
}

// MARK: Scenes

struct ScenesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.scenes", provider: HomeProvider()) { entry in
            ScenesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cenas")
        .description("Execute as cenas do Lar com um toque.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct ScenesView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.scenes.isEmpty {
            Text("Crie cenas no app Lar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            switch family {
            case .accessoryCircular:
                let scene = entry.scenes[0]
                Button(intent: RunSceneIntent(scene: SceneEntity(scene))) {
                    VStack(spacing: 1) {
                        Image(systemName: scene.symbol).font(.title3)
                        Text(scene.name).font(.system(size: 9)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.scenes.prefix(2)) { scene in
                        Button(intent: RunSceneIntent(scene: SceneEntity(scene))) {
                            Label(scene.name, systemImage: scene.symbol).font(.headline).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            default:
                let count = family == .systemSmall ? 4 : 6
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: family == .systemSmall ? 2 : 3), spacing: 6) {
                    ForEach(entry.scenes.prefix(count)) { scene in
                        Button(intent: RunSceneIntent(scene: SceneEntity(scene))) {
                            VStack(spacing: 4) {
                                Image(systemName: scene.symbol).font(.title3).foregroundStyle(Color.accentColor)
                                Text(scene.name).font(.caption).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: Favorites

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.favorites", provider: HomeProvider()) { entry in
            FavoritesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Favoritos")
        .description("Ligue e desligue os aparelhos favoritos sem abrir o app.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline])
    }
}

struct FavoritesView: View {
    var entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            let on = entry.devices.filter { $0.isOn == true && $0.isOnline && $0.kind != .camera }.count
            Label(on == 0 ? "Tudo desligado" : "\(on) \(on == 1 ? "ligado" : "ligados")", systemImage: "house")
        default:
            let limit = family == .systemSmall ? 4 : family == .systemMedium ? 8 : 16
            let columns = family == .systemSmall ? 2 : 4
            if entry.shortcuts.isEmpty {
                Text("Abra o Lar para carregar os aparelhos.").font(.footnote).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 8) {
                    ForEach(entry.shortcuts.prefix(limit)) { device in
                        DeviceButton(device: device)
                    }
                }
            }
        }
    }
}

struct DeviceButton: View {
    var device: HomeDevice

    private var isOn: Bool { device.isOn == true && device.isOnline }

    var body: some View {
        Button(intent: ToggleDeviceIntent(device: DeviceEntity(device))) {
            VStack(spacing: 3) {
                Image(systemName: Labels.icon(device.kind, on: isOn))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Palette.on(device.kind)) : AnyShapeStyle(Color.secondary.opacity(0.2))))
                Text(device.name).font(.system(size: 10)).lineLimit(1)
            }
            .opacity(device.isOnline ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!device.canSwitch)
    }
}

// MARK: Control Center

struct SceneControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.coupled.lar.control.scene", intent: SceneControlIntent.self) { configuration in
            ControlWidgetButton(action: configuration) {
                Label(configuration.scene?.name ?? "Cena", systemImage: configuration.scene?.symbol ?? "sparkles")
            }
        }
        .displayName("Cena do Lar")
        .description("Executa uma cena.")
    }
}

struct DeviceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.coupled.lar.control.device", provider: DeviceControlProvider()) { value in
            ControlWidgetToggle(value.name, isOn: value.isOn, action: value.intent) { on in
                Label(on ? "Ligado" : "Desligado", systemImage: value.symbol)
            }
        }
        .displayName("Aparelho do Lar")
        .description("Liga e desliga um aparelho.")
    }
}

struct DeviceControlValue {
    var name: String
    var symbol: String
    var isOn: Bool
    /// Without a device until one is chosen.
    var intent: DevicePowerControlIntent
}

struct DeviceControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: DeviceControlConfiguration) -> DeviceControlValue {
        DeviceControlValue(name: configuration.device?.name ?? "Aparelho", symbol: configuration.device?.symbol ?? "power",
                           isOn: false, intent: DevicePowerControlIntent(device: configuration.device))
    }

    func currentValue(configuration: DeviceControlConfiguration) async throws -> DeviceControlValue {
        var value = previewValue(configuration: configuration)
        if let id = configuration.device?.id {
            let snapshot = WidgetSnapshot.load()?.devices.first { $0.id == id }
            let live = await MainActor.run { IntentContext.model?.home.device(id: id) }
            value.isOn = (live ?? snapshot)?.isOn == true
        }
        return value
    }
}

// MARK: Live Activity

struct LaundryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LaundryActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "washer.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.name).font(.headline)
                    Text(context.state.stage).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: Date()...max(Date(), context.state.ends), countsDown: true)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.name, systemImage: "washer.fill").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...max(Date(), context.state.ends), countsDown: true)
                        .monospacedDigit()
                        .frame(width: 70)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.stage).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "washer.fill")
            } compactTrailing: {
                Text(timerInterval: Date()...max(Date(), context.state.ends), countsDown: true)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "washer.fill")
            }
        }
    }
}
