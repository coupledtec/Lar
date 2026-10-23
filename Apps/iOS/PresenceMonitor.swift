import CoreLocation
import LarCore

/// Arriving at and leaving home: a region around the spot marked as home (Ajustes → Casa). iOS wakes the app when
/// the iPhone crosses it, even with the app closed, and the scenes set for that run.
@MainActor
final class PresenceMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = PresenceMonitor()

    private let manager = CLLocationManager()
    private weak var model: LarModel?
    private var waitingForHere: CheckedContinuation<CLLocation?, Never>?
    static let radius: CLLocationDistance = 150
    nonisolated static let regionID = "lar.home"

    var homeIsSet: Bool { Preferences.object(forKey: "homeLocation") != nil }

    func start(model: LarModel) {
        self.model = model
        manager.delegate = self
        if let home = Self.savedHome() { monitor(home) }
    }

    /// Marks where the iPhone is now as home; asks for "Always" location (needed to notice arriving and leaving).
    func setHomeHere() async -> String? {
        manager.requestAlwaysAuthorization()
        let location: CLLocation? = await withCheckedContinuation { continuation in
            waitingForHere = continuation
            manager.requestLocation()
        }
        guard let location else { return "Não deu para saber onde o iPhone está. Permita a localização em Ajustes." }
        Preferences.set([location.coordinate.latitude, location.coordinate.longitude], forKey: "homeLocation")
        monitor(location.coordinate)
        return manager.authorizationStatus == .authorizedAlways ? nil
            : "Para chegar e sair funcionarem com o app fechado, permita a localização “Sempre” nos Ajustes do iPhone."
    }

    func forgetHome() {
        Preferences.set(nil, forKey: "homeLocation")
        for region in manager.monitoredRegions where region.identifier == Self.regionID { manager.stopMonitoring(for: region) }
    }

    private static func savedHome() -> CLLocationCoordinate2D? {
        guard let pair = Preferences.object(forKey: "homeLocation") as? [Double], pair.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
    }

    private func monitor(_ center: CLLocationCoordinate2D) {
        let region = CLCircularRegion(center: center, radius: Self.radius, identifier: Self.regionID)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func crossed(_ presence: ScenePresence) {
        guard let model else { return }
        Task {
            if model.home.devices.isEmpty { await model.home.refresh() }
            for scene in model.scenes.scenes where scene.presence == presence {
                let problem = model.home.run(scene)
                await model.home.waitUntilSent()
                Notifier.post([HomeAlert(id: "scene:\(scene.id)", title: scene.name,
                                         body: problem ?? "\(presence.text): cena executada.")], force: true)
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        Task { @MainActor in self.crossed(.arrive) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        Task { @MainActor in self.crossed(.leave) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            self.waitingForHere?.resume(returning: location)
            self.waitingForHere = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.waitingForHere?.resume(returning: nil)
            self.waitingForHere = nil
        }
    }
}
