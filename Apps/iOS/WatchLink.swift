import Foundation
import LarCore
import Observation
import UIKit
import WatchConnectivity

/// The iPhone's side of the link with the watch: hands it the accounts (WatchPayload) whenever they change, answers
/// when the watch asks for a fresh SmartThings access token (the refresh token never leaves the iPhone), and runs the
/// watch's TV requests (TVRelay), since only the iPhone can reach the TVs.
@MainActor
@Observable
final class WatchLink: NSObject {
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var lastSent: Date?
    @ObservationIgnored private weak var model: LarModel?

    func start(model: LarModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the current accounts as the watch's application context (it gets the latest even if it was asleep).
    func sendAccounts() {
        Task {
            guard let payload = await makePayload(), let data = try? payload.encoded() else { return }
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            try? session.updateApplicationContext(["payload": data])
            lastSent = Date()
        }
    }

    /// Nil while the keychain can't be read (locked since the iPhone started): an empty payload would wipe the
    /// watch's accounts.
    private func makePayload() async -> WatchPayload? {
        guard let model, UIApplication.shared.isProtectedDataAvailable else { return nil }
        let smartThings = model.home.provider(.smartThings) as? SmartThingsClient
        let access = try? await smartThings?.currentAccessToken()
        return WatchPayload.from(model.settings, smartThingsAccessToken: access)
    }

    fileprivate func refreshState() {
        let session = WCSession.default
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
    }

    fileprivate func replyTV(_ data: Data, _ handler: @escaping @Sendable ([String: Any]) -> Void) {
        Task {
            guard let model, let request = try? JSONDecoder().decode(TVRelay.Request.self, from: data) else {
                handler([:])
                return
            }
            let reply = await TVRelay.handle(request, tv: model.home.tv, known: model.home.devices)
            if case .devices = request {} else { model.home.refreshSoon() }
            handler((try? JSONEncoder().encode(reply)).map { [TVRelay.messageKey: $0] } ?? [:])
        }
    }

    fileprivate func reply(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        Task {
            let data = try? await makePayload()?.encoded()
            handler(data.map { ["payload": $0] } ?? [:])
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.refreshState()
            self.sendAccounts()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshState()
            self.sendAccounts()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The watch asks for the accounts (on launch, or when its SmartThings token is about to expire).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let handler = replyHandler
        let tv = message[TVRelay.messageKey] as? Data
        Task { @MainActor in
            if let tv {
                self.replyTV(tv) { handler($0) }
            } else {
                self.reply { handler($0) }
            }
        }
    }
}
