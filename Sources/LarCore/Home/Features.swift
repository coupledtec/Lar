import Foundation

/// What this build of Lar offers. The App Store versions leave the intercom out (they're built with
/// LAR_NO_INTERCOM and turn it off at launch); the Mac's GitHub version and personal builds keep it.
@MainActor
public enum Features {
    /// The building's intercom (SIP calls, opening the gate, the background audio that keeps it registered).
    public static var intercom = true
}
