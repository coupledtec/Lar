import CoreLocation
import LarCore

/// Where this Mac is: which house it's in (the menu bar's temperature and devices are that one's) and the spot for
/// "Usar a localização deste Mac" when making a house. Asked once at launch and when the houses change; a Mac moves
/// little, so nothing runs in between.
@MainActor
final class MacLocation: NSObject, CLLocationManagerDelegate {
    static let shared = MacLocation()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Coordinate?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Notes the house this Mac is at (nothing to do with fewer than two houses).
    func locateHouse() {
        guard HomePlaces.all.count > 1 else { return }
        Task {
            guard let spot = await here(asking: false) else { return }
            HomePlaces.update(at: spot)
        }
    }

    /// This Mac's spot; `asking` shows the system's permission prompt the first time.
    func here(asking: Bool = true) async -> Coordinate? {
        switch manager.authorizationStatus {
        case .notDetermined:
            guard asking else { return nil }
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            return nil
        default:
            break
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    private func finish(_ spot: Coordinate?) {
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume(returning: spot) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let spot = locations.last.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        Task { @MainActor in self.finish(spot) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let decided = manager.authorizationStatus != .notDetermined
        Task { @MainActor in
            if !self.waiting.isEmpty, decided { self.manager.requestLocation() }
        }
    }
}
