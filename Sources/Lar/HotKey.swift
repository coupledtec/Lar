import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut (⌃⌥L) that opens the popover from any app. Carbon's hot keys need no Accessibility
/// permission, unlike watching every key press.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    static let display = "⌃⌥L"

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func register() {
        guard reference == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &type, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x4C41_5221), id: 1) // "LAR!"
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
