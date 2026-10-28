import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Face ID, Touch ID or the device's password before Settings opens: that's where the accounts' keys are.
public enum SettingsLock {
    /// On unless turned off.
    public static var isEnabled: Bool {
        get { Preferences.bool(forKey: "lockSettings") ?? true }
        set { Preferences.set(newValue, forKey: "lockSettings") }
    }

    /// True when the owner proved it's them, or when there's nothing to check with (no password set at all).
    @MainActor
    public static func unlock() async -> Bool {
        #if canImport(LocalAuthentication) && !os(watchOS) && !os(tvOS)
        guard isEnabled else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: tr("abrir os Ajustes do Lar"))) ?? false
        #else
        return true
        #endif
    }
}
