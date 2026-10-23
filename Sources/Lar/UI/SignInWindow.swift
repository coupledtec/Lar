import AppKit
import LarCore
import SwiftUI

/// The SmartThings sign-in in its own window (the popover hides as soon as the Mac goes to another window).
@MainActor
enum SignInWindow {
    private static var window: NSWindow?

    static func show(_ request: SmartThingsSignInRequest, onFinish: @escaping (Result<String, Error>?) -> Void) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "SmartThings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SmartThingsSignInView(clientID: request.clientID, secret: request.secret) { result in
            close()
            onFinish(result)
        })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() {
        window?.close()
        window = nil
    }
}
