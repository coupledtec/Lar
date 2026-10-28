import AppKit
import LarCore
import ServiceManagement

/// Lar starts with the Mac and comes back by itself when it stops unexpectedly (a crash, a forced quit): a launchd
/// agent inside the app (Contents/Library/LaunchAgents) with RunAtLoad and KeepAlive on a failed exit. "Sair do Lar"
/// exits normally, so it stays closed until the next login. Where the agent can't be registered (an unsigned build),
/// a plain login item. The Mac App Store version (LAR_APPSTORE, sandboxed) uses only the login item.
@MainActor
enum StartAtLogin {
    static let agent = SMAppService.agent(plistName: "com.coupled.lar.agent.plist")
    /// This copy was started by the agent (the plist sets it).
    static let launchedByAgent = ProcessInfo.processInfo.environment["LAR_AGENT"] == "1"
    private static let chosenKey = "startAtLoginChosen"

    #if LAR_APPSTORE
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    #else
    static var isEnabled: Bool { agent.status == .enabled || SMAppService.mainApp.status == .enabled }

    /// Waiting for the person to allow it in System Settings → General → Login Items.
    static var needsApproval: Bool { agent.status == .requiresApproval }
    #endif

    /// On by default: the first launch turns it on; after that it follows the setting. A login item of an older
    /// version moves to the agent. The Mac App Store version starts at login only after the person turns it on in
    /// Settings (App Review 2.4.5(iii): no launching at login without consent).
    static func applyDefault() {
        #if LAR_APPSTORE
        return
        #endif
        if Preferences.bool(forKey: chosenKey) == nil {
            Preferences.set(true, forKey: chosenKey)
            try? set(true)
        } else if SMAppService.mainApp.status == .enabled, agent.status != .enabled {
            try? set(true)
        } else if agent.status == .enabled, !launchedByAgent {
            #if !LAR_APPSTORE
            handOverToAgent()
            #endif
        }
    }

    /// Opened by hand (after "Sair do Lar", from the Finder): the agent starts its own copy, which takes over, so
    /// launchd watches the one that runs. A few seconds later, so a link this copy was opened for gets done first.
    #if !LAR_APPSTORE
    private static func handOverToAgent() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/com.coupled.lar.agent"]
            try? process.run()
        }
    }
    #endif

    static func set(_ on: Bool) throws {
        Preferences.set(true, forKey: chosenKey)
        #if LAR_APPSTORE
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return
        #endif
        if on {
            do {
                try agent.register()
                if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            } catch {
                try SMAppService.mainApp.register()
            }
        } else {
            try? agent.unregister()
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }

    /// Only one Lar. Registering the agent starts its own copy right away: that copy takes over from the one opened
    /// by hand. A copy opened while another runs (`open -n`) just quits. Returns whether this copy should run.
    static func takeOver() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }
        if launchedByAgent {
            for other in others { other.terminate() }
            return true
        }
        others.first?.activate()
        return false
    }
}
