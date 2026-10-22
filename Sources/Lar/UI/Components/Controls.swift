import AppKit
import SwiftUI

/// A Control Center–style row: a round icon that fills with the accent color when on, and a title.
struct CircleToggleRow: View {
    var systemImage: String
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12))))
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A full-width row that reads like a menu item, highlighted on hover (e.g. "Settings…").
struct MenuRow: View {
    var title: String
    /// Shows a small accent dot, e.g. when an update is waiting behind this row.
    var showsBadge = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 0)
                if showsBadge {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Update available")
                }
            }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { isHovered = $0 }
    }
}

/// A native pop-up button that takes the width it's given. SwiftUI's menu `Picker` sizes itself to its
/// longest option, so two of them side by side never line up.
struct PopUpButton<Value: Hashable>: NSViewRepresentable {
    var options: [(title: String, value: Value)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? button.intrinsicContentSize.width, height: button.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PopUpButton

        init(parent: PopUpButton) { self.parent = parent }

        @objc func changed(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

/// A native segmented control that fills the width it's given, with equal segments. SwiftUI's
/// segmented `Picker` keeps its intrinsic width and just centers itself in extra space.
struct SegmentedControl<Value: Hashable>: NSViewRepresentable {
    var options: [(title: String, value: Value)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if (0..<control.segmentCount).map({ control.label(forSegment: $0) ?? "" }) != titles {
            control.segmentCount = titles.count
            for (index, title) in titles.enumerated() {
                control.setLabel(title, forSegment: index)
            }
        }
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? control.intrinsicContentSize.width, height: control.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SegmentedControl

        init(parent: SegmentedControl) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

/// The chevron that goes back to the list, at the top left of a detail screen.
struct BackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voltar")
        .keyboardShortcut(.cancelAction)
    }
}
