import LarCore
import SwiftUI

/// One LG air conditioner with every control (Celsius's popover), opened from the list.
struct ACDetailView: View {
    var store: ACStore
    /// The list's id of this unit ("lg:<id>"), for its history.
    var deviceID = ""
    var onBack: () -> Void
    /// Freezes the animation clock, for snapshots.
    var fixedDate: Date?

    @State private var draggingTarget: Double?

    var body: some View {
        controls
    }

    // MARK: Main screen

    private var status: ACStatus? { store.status }
    private var isOn: Bool { status?.isOn ?? false }
    private var caps: ACCapabilities { store.capabilities }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The way back and what's wrong stay readable while the rest waits for data.
            header.unredacted()
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        bigTemperature
                        Text(Labels.activity(status, target: draggingTarget ?? status?.targetTemperature))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.interpolate)
                    }
                    Spacer()
                    miniUnit
                }
                temperatureSlider
            }
            Divider()
            settingsRows
            Divider()
            if caps.hasToggles {
                toggleRows
            }
            Divider()
            ACHistoryView(deviceID: deviceID, compact: true)
        }
        .redacted(reason: status == nil ? .placeholder : [])
    }

    /// Device name and power, with the room temperature below (or what's wrong, when something is).
    private var header: some View {
        HStack(spacing: 10) {
            BackButton(action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                deviceTitle
                if store.transientMessage != nil || store.isReconnecting || store.connection != .connected {
                    FooterStatus(store: store)
                } else {
                    Text("Ambiente · \(Labels.temperature(status?.currentTemperature)) °C")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
            Spacer()
            Toggle("Ligar", isOn: Binding(get: { isOn }, set: { store.perform(.power($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(status == nil)
        }
    }

    /// The unit name, which becomes a menu to switch units when the account has several.
    @ViewBuilder
    private var deviceTitle: some View {
        let name = store.device?.displayName ?? "Ar-condicionado"
        let title = Text(name).font(.system(size: 13, weight: .semibold))
        if store.devices.count > 1 {
            Menu {
                ForEach(store.devices) { device in
                    Button {
                        Task { await store.selectDevice(id: device.id) }
                    } label: {
                        let label = Labels.deviceName(device, among: store.devices)
                        if device.id == store.device?.id {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    title
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Aparelho")
            .accessibilityValue(name)
        } else {
            title
        }
    }

    private var bigTemperature: some View {
        let value = draggingTarget ?? status?.targetTemperature
        let whole = value.map { String(Int($0.rounded(.down))) } ?? "—"
        let half = value.map { $0.rounded(.down) != $0 } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(whole)
                .font(.system(size: 44, weight: .medium))
                .contentTransition(.numericText(value: value ?? 0))
            if half {
                Text(".5")
                    .font(.system(size: 22, weight: .medium))
            }
            Text("°C")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
        }
        .monospacedDigit()
        .animation(.snappy(duration: 0.25), value: value)
        .opacity(isOn && temperatureEditable ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperatura ajustada em \(Labels.temperature(value)) graus")
    }

    /// The animated unit, drawn at full size and scaled down to sit beside the temperature.
    private var miniUnit: some View {
        ACUnitView(
            isOn: isOn,
            mode: status?.mode,
            fanSpeed: status?.fanSpeed,
            swing: status?.swing ?? false,
            sleeping: status?.sleepMinutesLeft != nil,
            target: draggingTarget ?? status?.targetTemperature,
            isVisible: store.isPopoverVisible || fixedDate != nil,
            fixedDate: fixedDate
        )
        .frame(width: 240)
        .scaleEffect(Self.miniUnitScale, anchor: .topLeading)
        .frame(width: 240 * Self.miniUnitScale, height: ACUnitView.height * Self.miniUnitScale, alignment: .topLeading)
    }

    private static let miniUnitScale: CGFloat = 0.55
    /// Shared by every pop-up button so they line up regardless of the selected value.
    private static let popUpWidth: CGFloat = 96

    private var temperatureEditable: Bool { ACMode.acceptsTargetTemperature(status?.mode) }

    private var temperatureSlider: some View {
        let enabled = isOn && temperatureEditable
        return TemperatureSlider(
            value: status?.targetTemperature ?? caps.minTemperature,
            range: caps.minTemperature...caps.maxTemperature,
            step: caps.temperatureStep,
            accent: Theme.modeColor(status?.mode),
            onChange: { draggingTarget = $0 },
            onCommit: { value in
                draggingTarget = nil
                store.setTargetTemperature(value, debounced: false)
            },
            onStep: { delta in
                let current = status?.targetTemperature ?? caps.minTemperature
                store.setTargetTemperature(current + delta, debounced: true)
            }
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledOpacity)
    }

    /// Mode as a segmented control, then fan speed and airflow as native pop-up buttons.
    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            SegmentedControl(
                options: caps.modes.map { (Labels.mode($0), $0) },
                selection: Binding(get: { status?.mode ?? "" }, set: { store.perform(.mode($0)) })
            )
            .accessibilityLabel("Modo")
            .padding(.bottom, 2)

            pickerRow(
                "Ventilação",
                options: caps.fanSpeeds.map { (Labels.fan($0), $0) },
                selection: Binding(get: { status?.fanSpeed ?? "" }, set: { store.perform(.fanSpeed($0)) })
            )
            if caps.supportsSwing {
                pickerRow(
                    "Direção do ar",
                    options: [(String(localized: "Fixa"), false), (String(localized: "Oscilar"), true)],
                    selection: Binding(get: { status?.swing ?? false }, set: { store.perform(.swing($0)) })
                )
            }
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }

    private func pickerRow<Value: Hashable>(
        _ title: LocalizedStringKey, options: [(title: String, value: Value)], selection: Binding<Value>
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            PopUpButton(options: options, selection: selection)
                .frame(width: Self.popUpWidth)
                .accessibilityLabel(title)
        }
    }

    private var toggleRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if caps.supportsEco {
                CircleToggleRow(systemImage: "leaf", title: "Modo Eco", isOn: status?.eco == true) {
                    store.perform(.eco(status?.eco != true))
                }
            }
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }
}
