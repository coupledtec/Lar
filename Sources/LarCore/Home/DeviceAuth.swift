import Foundation
#if canImport(LocalAuthentication) && !os(tvOS)
import LocalAuthentication
#endif

/// The owner's confirmation before something that can't be left to anyone holding the device (unlocking a door).
public enum DeviceAuth {
    /// Face ID, Touch ID or the passcode; false where there's none (the Apple TV) or when refused.
    @MainActor
    public static func confirm(_ reason: String) async -> Bool {
        #if canImport(LocalAuthentication) && !os(tvOS)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        #else
        return false
        #endif
    }
}
