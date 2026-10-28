import AppKit
import LarCore
import SwiftUI

/// Menu bar item: a house (filled while something is on), with the device list in a popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var store: HomeStore { model.home }
    private var observers: [NSObjectProtocol] = []
    private lazy var hotKey = HotKey { [weak self] in self?.togglePopover() }

    init(model: AppModel) {
        self.model = model
        super.init()

        let hosting = NSHostingController(rootView: HomeView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        observeStore()
        closePopoverWhenFocusMovesAway()
    }

    /// Like a native menu bar popover, dismiss when the user moves on. A transient popover only closes on a
    /// click it can see, so switching to a full-screen app's Space left it stranded over that app's content.
    private func closePopoverWhenFocusMovesAway() {
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.popover.close()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: close))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: close))
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        store.isPopoverVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        store.isPopoverVisible = false
    }

    // MARK: Menu bar label

    private func observeStore() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let count = store.switchedOnCount
        let image = NSImage(systemSymbolName: count > 0 ? "house.fill" : "house", accessibilityDescription: "Lar")
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        // The first air conditioner's room temperature, when asked for in Settings.
        let temperature = model.showsTemperatureInMenuBar
            ? store.devices.first(where: { $0.kind == .airConditioner && $0.isOnline })?.controls["roomTemperature"]
            : nil
        button.title = temperature.map { " \($0)" } ?? ""
        model.usesHotKey ? hotKey.register() : hotKey.unregister()
        button.toolTip = switch count {
        case 0: String(localized: "Lar · tudo desligado")
        case 1: String(localized: "Lar · 1 aparelho ligado")
        default: String(localized: "Lar · \(count) aparelhos ligados")
        }
    }
}
