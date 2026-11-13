#if !os(watchOS)
import SwiftUI

/// A device's options (an air conditioner's mode, fan and swing; a robot's suction; a light's effect) as pickers,
/// and the robot's pause: the same block on every screen that shows the device.
public struct DeviceOptionsView: View {
    let home: HomeStore
    let device: HomeDevice
    @State private var white: Double?

    public init(home: HomeStore, device: HomeDevice) {
        self.home = home
        self.device = device
    }

    /// Whether there's anything to show.
    public static func shows(_ device: HomeDevice) -> Bool {
        !device.options.isEmpty || device.canPause || device.whiteTemperature != nil
    }

    public var body: some View {
        if let current = device.whiteTemperature {
            VStack(alignment: .leading, spacing: 4) {
                Text("Branco")
                HStack {
                    Image(systemName: "sun.max").foregroundStyle(.orange)
                    #if os(tvOS)
                    Text("\(Int(((white ?? current) * 100).rounded()))%")
                    #else
                    Slider(value: Binding(get: { white ?? current }, set: { white = $0 }), in: 0...1) { editing in
                        // Sent once, when the finger lets go.
                        if !editing, let white { home.perform(.whiteTemperature(white), on: device.id) }
                    }
                    #endif
                    Image(systemName: "snowflake").foregroundStyle(.cyan)
                }
            }
            .disabled(!device.isOnline)
        }
        if device.canPause, device.isOn == true {
            Button {
                home.perform(.pause, on: device.id)
            } label: {
                Label("Pausar", systemImage: "pause.fill")
            }
        }
        ForEach(device.options) { option in
            Picker(option.title, selection: Binding(
                get: { option.current ?? "" },
                set: { home.perform(.option(option.name, $0), on: device.id) }
            )) {
                if option.current == nil { Text("—").tag("") }
                ForEach(option.values, id: \.self) { value in
                    Text(option.label(value)).tag(value)
                }
            }
            .disabled(!device.isOnline)
        }
    }
}
#endif
