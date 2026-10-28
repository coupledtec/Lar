import AppKit
import LarCore
import SwiftUI

/// The call in a small window over everything (the popover would hide when the Mac is in another app), with a
/// ringtone while an incoming call rings.
@MainActor
enum CallWindow {
    private static var window: NSPanel?
    private static var ring: NSSound?

    static func show(_ phone: PhoneStore) {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Porteiro"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.titlebarAppearsTransparent = true
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: CallWindowContent(phone: phone))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func startRinging() {
        let sound = NSSound(named: "Submarine")
        sound?.loops = true
        sound?.play()
        ring = sound
    }

    static func stopRinging() {
        ring?.stop()
        ring = nil
    }

    /// Closes shortly after the call ends, so its reason can be read.
    static func closeSoon() {
        stopRinging()
        Task {
            try? await Task.sleep(for: .seconds(2))
            window?.close()
            window = nil
        }
    }
}

private struct CallWindowContent: View {
    var phone: PhoneStore
    @State private var last: PhoneCall?

    var body: some View {
        Group {
            if let call = phone.call ?? last {
                CallView(phone: phone, call: call)
            } else {
                Text("Sem chamada").foregroundStyle(.secondary).frame(width: 280, height: 360)
            }
        }
        .onChange(of: phone.call) { _, call in
            if let call { last = call }
            if case .active = call?.state { CallWindow.stopRinging() }
        }
    }
}
