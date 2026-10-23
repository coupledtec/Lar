import LarCore
import SwiftUI
import WidgetKit

/// The watch face complications: how many devices are on, or the scenes; a tap opens the Lar.
/// They show what the watch app read last (complications can't reach the TVs, nor wait on the clouds for long).
@main
struct LarWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusComplication()
        ScenesComplication()
    }
}

struct WatchEntry: TimelineEntry {
    var date: Date
    var onCount: Int
    var scenes: [HomeScene]

    static let placeholder = WatchEntry(date: Date(), onCount: 2, scenes: [HomeScene(name: "Dormir", symbol: "moon.fill", actions: [])])
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(Self.saved())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        completion(Timeline(entries: [Self.saved()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    static func saved() -> WatchEntry {
        WatchEntry(date: Date(), onCount: WidgetSnapshot.load()?.onCount ?? 0, scenes: AppSettings().scenes)
    }
}

struct StatusComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.watch.status", provider: WatchProvider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Lar")
        .description("Quantos aparelhos estão ligados.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct StatusView: View {
    var entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(entry.onCount == 0 ? "Tudo desligado" : "\(entry.onCount) ligados", systemImage: "house")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("Lar", systemImage: entry.onCount > 0 ? "house.fill" : "house").font(.headline)
                Text(entry.onCount == 0 ? "Tudo desligado" : "\(entry.onCount) \(entry.onCount == 1 ? "ligado" : "ligados")")
            }
        case .accessoryCorner:
            Image(systemName: entry.onCount > 0 ? "house.fill" : "house")
                .widgetLabel("\(entry.onCount) ligados")
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: entry.onCount > 0 ? "house.fill" : "house")
                    Text("\(entry.onCount)").font(.headline)
                }
            }
        }
    }
}

struct ScenesComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.coupled.lar.watch.scenes", provider: WatchProvider()) { entry in
            VStack(alignment: .leading, spacing: 1) {
                if entry.scenes.isEmpty {
                    Text("Sem cenas")
                } else {
                    ForEach(entry.scenes.prefix(3)) { scene in
                        Label(scene.name, systemImage: scene.symbol).lineLimit(1)
                    }
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cenas do Lar")
        .description("Suas cenas; toque para abrir o Lar.")
        .supportedFamilies([.accessoryRectangular])
    }
}
