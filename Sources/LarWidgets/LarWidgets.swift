// The Mac's widgets for the version built here (scripts/build-app.sh puts them in Lar.app/Contents/PlugIns). They
// have no accounts: the menu bar app leaves them the list in a folder they share (WidgetRelay), and a tap opens a
// `lar://` link that the app runs (LarLink), so nothing waits for the widget's process.
#if os(macOS)
import LarCore
import SwiftUI
import WidgetKit

@main
struct LarWidgetBundle: WidgetBundle {
    var body: some Widget {
        FavoritesWidget()
        SummaryWidget()
        ScenesWidget()
        AirConditionerWidget()
        IntercomWidget()
    }
}

// MARK: Timeline

struct FeedEntry: TimelineEntry {
    var date: Date
    var feed: WidgetRelay.Feed?

    var devices: [HomeDevice] { feed?.devices ?? [] }

    /// The favorites; none chosen: the list's first devices.
    var favorites: [HomeDevice] {
        let favorites = Set(feed?.favorites ?? [])
        let chosen = devices.filter { favorites.contains($0.id) }
        return chosen.isEmpty ? devices.filter { $0.isOn != nil } : chosen
    }

    static let empty = FeedEntry(date: Date(), feed: nil)
}

struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry { .empty }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        completion(FeedEntry(date: Date(), feed: WidgetRelay.readFeed()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        // The app asks for a redraw when the list changes; this is only a fallback.
        completion(Timeline(entries: [FeedEntry(date: Date(), feed: WidgetRelay.readFeed())],
                            policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

/// What every widget says when the app hasn't left a list yet.
struct NoFeedView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "house").font(.title2).foregroundStyle(.secondary)
            Text("Abra o Lar na barra de menus.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension LarLink {
    /// The link as a URL (always valid for the cases the widgets use).
    var url: URL { LarLink.url(self) ?? URL(string: "lar://")! }
}

// MARK: Favorites

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.mac.favorites", provider: FeedProvider()) { entry in
            FavoritesView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Favoritos")
        .description("Seus favoritos (ou os primeiros aparelhos): clique para ligar ou desligar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct FavoritesView: View {
    var entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    private var limit: Int {
        switch family {
        case .systemSmall: 4
        case .systemMedium: 8
        case .systemLarge: 12
        default: 24
        }
    }

    var body: some View {
        if entry.feed == nil {
            NoFeedView()
        } else {
            let columns = family == .systemSmall ? 2 : 4
            VStack(alignment: .leading, spacing: 8) {
                Label("Favoritos", systemImage: "star.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    ForEach(entry.favorites.prefix(limit)) { DeviceTile(device: $0) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A device: its icon lit when on; a click switches it (through the app).
struct DeviceTile: View {
    var device: HomeDevice

    private var isOn: Bool { device.isOn == true && device.isOnline }

    var body: some View {
        Link(destination: LarLink.power(device: device.name, on: nil).url) {
            VStack(spacing: 4) {
                Image(systemName: Labels.icon(device.kind, on: isOn))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Color.secondary.opacity(0.2))))
                Text(device.name).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .opacity(device.isOnline ? 1 : 0.5)
        }
        .disabled(device.isOn == nil)
    }
}

// MARK: Summary

struct SummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.mac.summary", provider: FeedProvider()) { entry in
            SummaryView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Resumo")
        .description("Quantos aparelhos estão ligados e quais; clique em um para desligar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SummaryView: View {
    var entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.feed == nil {
            NoFeedView()
        } else {
            let on = entry.devices.filter(\.countsAsOn)
            VStack(alignment: .leading, spacing: 6) {
                Label("Lar", systemImage: "house.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(on.isEmpty ? String(localized: "Tudo desligado") : on.count == 1 ? String(localized: "1 ligado")
                     : String(localized: "\(on.count) ligados"))
                    .font(.title2.weight(.semibold))
                ForEach(on.prefix(family == .systemSmall ? 2 : family == .systemMedium ? 3 : 9)) { device in
                    Link(destination: LarLink.power(device: device.name, on: false).url) {
                        HStack(spacing: 6) {
                            Image(systemName: Labels.icon(device.kind, on: true)).foregroundStyle(.yellow).frame(width: 18)
                            Text(device.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if family != .systemSmall { Image(systemName: "power").foregroundStyle(.red) }
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Scenes

struct ScenesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.mac.scenes", provider: FeedProvider()) { entry in
            ScenesView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cenas")
        .description("Clique numa cena para executá-la.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ScenesView: View {
    var entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let scenes = entry.feed?.scenes ?? []
        if scenes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                Text(entry.feed == nil ? "Abra o Lar na barra de menus." : "Crie cenas no Lar.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let columns = family == .systemSmall ? 1 : 2
            let limit = family == .systemSmall ? 3 : family == .systemMedium ? 4 : 10
            VStack(alignment: .leading, spacing: 6) {
                Label("Cenas", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(scenes.prefix(limit)) { scene in
                        Link(destination: LarLink.scene(scene.name).url) {
                            Label(scene.name, systemImage: scene.symbol)
                                .font(.caption.weight(.medium)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: Air conditioner

struct AirConditionerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.mac.ac", provider: FeedProvider()) { entry in
            AirConditionerView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Ar-condicionado")
        .description("O primeiro ar-condicionado: ambiente, ajustado, − / + e ligar ou desligar.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AirConditionerView: View {
    var entry: FeedEntry

    var body: some View {
        if let ac = entry.devices.first(where: { $0.acceptsTemperature }) {
            let on = ac.isOn == true && ac.isOnline
            let target = ac.targetTemperature ?? 23
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(ac.name, systemImage: "air.conditioner.horizontal.fill").font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Link(destination: LarLink.power(device: ac.name, on: !on).url) {
                        Image(systemName: "power").foregroundStyle(on ? .red : .green)
                    }
                }
                if let room = ac.roomTemperature {
                    Text("Ambiente \(HomeText.degrees(room))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack {
                    Link(destination: LarLink.temperature(device: ac.name, value: target - 1).url) {
                        Image(systemName: "minus.circle.fill").font(.title2)
                    }
                    Spacer()
                    Text(on ? HomeText.degrees(target) : String(localized: "Desligado"))
                        .font(on ? .title.weight(.semibold).monospacedDigit() : .headline)
                    Spacer()
                    Link(destination: LarLink.temperature(device: ac.name, value: target + 1).url) {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
        } else if entry.feed == nil {
            NoFeedView()
        } else {
            Text("Nenhum ar-condicionado no Lar.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Intercom

struct IntercomWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.mac.intercom", provider: FeedProvider()) { _ in
            IntercomView().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Porteiro")
        .description("Abrir o portão com um clique (o Lar liga para o porteiro, manda as teclas e desliga), ou ligar.")
        .supportedFamilies([.systemSmall])
    }
}

struct IntercomView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Porteiro", systemImage: "phone.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Link(destination: LarLink.openGate.url) {
                Label("Abrir o portão", systemImage: "door.left.hand.open")
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.3)))
            }
            Link(destination: LarLink.call(nil).url) {
                Label("Ligar", systemImage: "phone.arrow.up.right")
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2)))
            }
        }
        .font(.caption.weight(.semibold))
    }
}
#else
@main
enum LarWidgetsUnavailable {
    static func main() {}
}
#endif
