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

    /// The Xbox sign-in (a code typed at microsoft.com/link), in a window so it stays while the browser is in front.
    static func showXbox(onFinish: @escaping (Result<XboxAccount, Error>?) -> Void) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Xbox"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: XboxSignInView { result in
            close()
            onFinish(result)
        })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Amazon's sign-in, for the Echos.
    static func showAlexa(onFinish: @escaping (Result<AlexaAccount, Error>?) -> Void) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 680), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Alexa"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AlexaSignInView { result in
            close()
            onFinish(result)
        })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// SmartThings set up by itself: the Samsung sign-in and one "Authorize"; the Mac's integration made and filled.
    static func showAutoSetup(onFinish: @escaping ([SmartThingsAutoSetup.Result]) -> Void) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "SmartThings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SmartThingsAutoSetupView(devices: ["Mac"]) { results in
            close()
            onFinish(results)
        } onCancel: {
            close()
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
