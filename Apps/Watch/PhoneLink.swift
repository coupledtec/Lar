import Foundation
import LarCore
import Observation
import WatchConnectivity

/// The watch's side of the link: takes the accounts the iPhone sends (WatchPayload) into its own keychain, asks
/// for them again when the SmartThings access token is about to expire, and carries the TV requests (TVRelay).
@MainActor
@Observable
final class PhoneLink: NSObject {
    private(set) var lastReceived: Date?
    @ObservationIgnored private weak var model: LarModel?
    @ObservationIgnored private var expires: Date?

    func start(model: LarModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the iPhone for the accounts when the watch has none yet or SmartThings' token is close to expiring.
    func askIfStale() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        let settings = model?.settings
        let hasKeys = settings?.token != nil || settings?.tuya != nil || settings?.smartThings != nil
        let stale = !hasKeys || (expires.map { $0 < Date().addingTimeInterval(3600) } ?? false)
        guard stale else { return }
        // Sendable: WatchConnectivity answers on its own queue, never the main one.
        session.sendMessage(["want": "payload"], replyHandler: { @Sendable reply in
            guard let data = reply["payload"] as? Data else { return }
            Task { @MainActor in self.take(data) }
        }, errorHandler: nil)
    }

    /// One TV request to the iPhone and its reply; fails when the iPhone isn't reachable.
    nonisolated static func sendTV(_ request: Data) async throws -> Data {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { throw URLError(.notConnectedToInternet) }
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage([TVRelay.messageKey: request], replyHandler: { @Sendable reply in
                if let data = reply[TVRelay.messageKey] as? Data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }, errorHandler: { @Sendable in continuation.resume(throwing: $0) })
        }
    }

    fileprivate func take(_ data: Data) {
        guard let model, let payload = try? WatchPayload.decoded(data) else { return }
        payload.apply(to: model.settings)
        model.scenes.reload()
        model.home.customizations = model.settings.customizations
        model.home.grouping = model.settings.grouping
        expires = payload.smartThingsExpires
        lastReceived = payload.sentAt
        model.accountsChanged()
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext["payload"] as? Data
        Task { @MainActor in
            if let context { self.take(context) }
            self.askIfStale()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let data = context["payload"] as? Data else { return }
        Task { @MainActor in self.take(data) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.askIfStale() }
    }
}
