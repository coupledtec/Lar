import Foundation
import Observation
#if canImport(StoreKit) && !os(tvOS) && !os(watchOS)
import StoreKit
import SwiftUI
#endif

/// When to ask for a rating on the App Store (the João's rule, 19/11/2026): three times at most, each needing more
/// use than the one before, and never again once the person rated:
/// 1. the second time Lar is opened;
/// 2. after more than 4 openings, with 2 commands sent since the first ask;
/// 3. after more than 10 openings, with 3 commands since the second.
/// Never right after a command failed. Apple's own prompt doesn't tell whether the person rated (the three asks end
/// it); the GitHub version's card does ("Avaliar", "Estrela"). The apps watch `isDue` and ask.
@MainActor
@Observable
public final class ReviewPrompt {
    public static let shared = ReviewPrompt()

    /// It's time: the app asks now (then calls `asked()`).
    public private(set) var isDue = false

    /// Openings and commands since the last ask needed for each ask.
    static let steps: [(opens: Int, commands: Int)] = [(2, 0), (5, 2), (11, 3)]

    init() {}

    private var opens: Int { Preferences.object(forKey: "reviewOpens") as? Int ?? 0 }
    private var commands: Int { Preferences.object(forKey: "reviewCommands") as? Int ?? 0 }
    private var asks: Int { Preferences.object(forKey: "reviewAsks") as? Int ?? 0 }
    private var rated: Bool { Preferences.bool(forKey: "reviewRated") == true }
    private var lastFailed = false

    /// Lar came to the front (the menu bar's window shown, the iPhone app active).
    public func noteOpen() {
        Preferences.set(opens + 1, forKey: "reviewOpens")
        check()
    }

    /// A command went out.
    public func noteSuccess() {
        lastFailed = false
        Preferences.set(commands + 1, forKey: "reviewCommands")
        check()
    }

    /// A command failed: not now.
    public func noteFailure() {
        lastFailed = true
        isDue = false
    }

    /// The ask was shown (or handed to the system, which may not show it).
    public func asked() {
        Preferences.set(asks + 1, forKey: "reviewAsks")
        Preferences.set(0, forKey: "reviewCommands")
        isDue = false
    }

    /// The person went to rate (or star): never again.
    public func rated(_ yes: Bool = true) {
        Preferences.set(yes, forKey: "reviewRated")
        if yes { asked() }
    }

    private func check() {
        // Never on the store's screenshots.
        if UserDefaults.standard.bool(forKey: "LarScreenshots") { isDue = false; return }
        guard !rated, !lastFailed, asks < Self.steps.count else { isDue = false; return }
        let step = Self.steps[asks]
        isDue = opens >= step.opens && commands >= step.commands
    }
}

#if canImport(StoreKit) && !os(tvOS) && !os(watchOS)
/// Shows the system's rating prompt when `ReviewPrompt` says it's time (a couple of seconds later, so it doesn't
/// cover what just happened).
struct ReviewPromptModifier: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    private var prompt = ReviewPrompt.shared

    func body(content: Content) -> some View {
        content.onChange(of: prompt.isDue) { _, due in
            guard due else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard prompt.isDue else { return }
                prompt.asked()
                requestReview()
            }
        }
    }
}

extension View {
    /// The App Store's rating prompt, at a good moment (the App Store apps' main screen).
    public func reviewPromptWhenDue() -> some View { modifier(ReviewPromptModifier()) }
}
#endif
