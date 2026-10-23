import Charts
import LarCore
import SwiftUI

/// An air conditioner's last 24 hours: the room temperature, and how long it ran today with what that costs.
/// The same file in the Mac and iPhone apps.
struct ACHistoryView: View {
    var deviceID: String
    var compact = false

    @State private var samples: [HistorySample] = []

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let points = samples.filter { $0.room != nil }
            if points.count < 2 {
                Text("O histórico aparece depois de algumas leituras (o Lar guarda uma a cada 5 min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points, id: \.date) { sample in
                    LineMark(x: .value("Hora", sample.date), y: .value("°C", sample.room ?? 0))
                        .interpolationMethod(.monotone)
                    if sample.isOn == true {
                        PointMark(x: .value("Hora", sample.date), y: .value("°C", sample.room ?? 0))
                            .symbolSize(8)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: compact ? 90 : 140)
            }
            Text("Ligado hoje: " + EnergyEstimate.text(running: HistoryStore.onTime(samples, from: today, to: Date())))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            samples = await HistoryStore.shared.samples(of: deviceID, since: Date().addingTimeInterval(-86_400))
        }
    }
}
