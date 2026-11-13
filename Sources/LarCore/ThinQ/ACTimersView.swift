#if !os(watchOS)
import SwiftUI

/// An LG air conditioner's timers and filter: turn off in (the sleep timer, while on), turn on in (while off) and the
/// filter's life left, when the unit has them.
public struct ACTimersView: View {
    var store: ACStore
    static let hours = [1, 2, 3, 4, 6, 8, 12]

    public init(store: ACStore) {
        self.store = store
    }

    public static func shows(_ store: ACStore) -> Bool {
        store.capabilities.supportsSleep || store.capabilities.supportsStart || store.status?.filterPercentLeft != nil
    }

    public var body: some View {
        let status = store.status
        let isOn = status?.isOn ?? false
        if store.capabilities.supportsSleep, isOn {
            Picker("Desligar em", selection: Binding(get: { status?.sleepTimerHours ?? 0 }, set: { store.perform(.sleep(hours: $0)) })) {
                Text("Nunca").tag(0)
                ForEach(Self.hours, id: \.self) { Text("\($0) h").tag($0) }
            }
        }
        if store.capabilities.supportsStart, !isOn {
            Picker("Ligar em", selection: Binding(get: { status?.startMinutesLeft.map { ($0 + 59) / 60 } ?? 0 },
                                                  set: { store.perform(.start(hours: $0)) })) {
                Text("Nunca").tag(0)
                ForEach(Self.hours, id: \.self) { Text("\($0) h").tag($0) }
            }
        }
        if let filter = status?.filterPercentLeft {
            LabeledContent("Filtro", value: filter <= 10 ? String(localized: "\(filter)% · hora de limpar") : "\(filter)%")
                .foregroundStyle(filter <= 10 ? Color.orange : Color.primary)
        }
    }
}
#endif
