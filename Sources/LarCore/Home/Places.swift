import Foundation
import Synchronization

/// A house (or any place with devices: the beach house, the office). Each device belongs to one; the iPhone notices
/// which one it's at, so the widgets and the watch's face show that house's temperature and devices, never another's.
public struct HomePlace: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// Where it is (from the devices' accounts, the nights the iPhone spent there, or home marked by hand).
    public var coordinate: Coordinate?
    /// Found by itself (its name can be improved from the address); nil or false: named by the person.
    public var isAutomatic: Bool?
    /// Where it was before being moved by hand: still this house (the devices whose accounts say that spot stay in it,
    /// and no house is made there again).
    public var formerSpots: [Coordinate]?

    public init(id: String = UUID().uuidString, name: String, coordinate: Coordinate? = nil, isAutomatic: Bool? = nil,
                formerSpots: [Coordinate]? = nil) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.isAutomatic = isAutomatic
        self.formerSpots = formerSpots
    }

    /// Every spot that is this house.
    var spots: [Coordinate] { (coordinate.map { [$0] } ?? []) + (formerSpots ?? []) }

    /// Changed by hand (name, spot): from now on the Lar keeps it as it is. The old spot stays this house's.
    public func edited(name: String, coordinate: Coordinate?) -> HomePlace {
        var copy = self
        copy.name = name
        if let old = self.coordinate, coordinate != old {
            copy.formerSpots = ((formerSpots ?? []) + [old]).filter { $0 != coordinate }
        }
        copy.coordinate = coordinate
        copy.isAutomatic = nil
        return copy
    }
}

/// The houses, which one each device is in and which one this device is at now. With one house (or none) nothing
/// changes: every device is "here".
public enum HomePlaces {
    /// Within this of a house, you're at it (meters).
    public static let radius: Double = 300

    /// The houses, the first being the main one (devices not put anywhere are in it). Synced with the scenes.
    public static var all: [HomePlace] {
        get { Preferences.decoded([HomePlace].self, forKey: "places") ?? [] }
        set {
            Preferences.setEncoded(newValue, forKey: "places")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Posted when the houses or the current one change (the screens showing them redraw).
    public static let changed = Notification.Name("LarPlacesChanged")

    /// The house this device is at (or was last near), set from the location; nil: not known yet.
    public static var currentID: String? {
        get { Preferences.string(forKey: "currentPlace") }
        set {
            Preferences.set(newValue, forKey: "currentPlace")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The house a device is in: chosen by hand, else where its account says it is, else where it's been used from,
    /// else the main house.
    public static func placeID(of device: HomeDevice, customizations: [String: DeviceCustomization], places: [HomePlace],
                               learned: [String: String] = [:]) -> String? {
        if let chosen = customizations[device.id]?.place, places.contains(where: { $0.id == chosen }) { return chosen }
        if let geo = device.geo, let near = nearest(to: geo, in: places) { return near.id }
        if let used = learned[device.id], places.contains(where: { $0.id == used }) { return used }
        return places.first?.id
    }

    /// The house being shown: the one this device is at (or nearest to), else the main one.
    public static func current(in places: [HomePlace], currentID: String?) -> HomePlace? {
        places.first { $0.id == currentID } ?? places.first
    }

    /// The devices of the house being shown (all of them with fewer than two houses).
    public static func here(_ devices: [HomeDevice], customizations: [String: DeviceCustomization],
                            places: [HomePlace], currentID: String?, learned: [String: String] = [:]) -> [HomeDevice] {
        guard places.count > 1, let place = current(in: places, currentID: currentID) else { return devices }
        return devices.filter { placeID(of: $0, customizations: customizations, places: places, learned: learned) == place.id }
    }

    /// The same, with what's saved on this device.
    public static func here(_ devices: [HomeDevice], customizations: [String: DeviceCustomization]) -> [HomeDevice] {
        here(devices, customizations: customizations, places: all, currentID: currentID, learned: learned)
    }

    // MARK: Finding the houses by themselves

    /// Two spots closer than this are the same house (meters).
    public static let sameHouse: Double = 500

    /// Which house each device without a spot of its own was used from (the iPhone at that house), by device id.
    public static var learned: [String: String] {
        get { Preferences.object(forKey: "placeLearned") as? [String: String] ?? [:] }
        set {
            Preferences.set(newValue, forKey: "placeLearned")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static var votes: [String: [String: Int]] {
        get { Preferences.decoded([String: [String: Int]].self, forKey: "placeVotes") ?? [:] }
        set { Preferences.setEncoded(newValue, forKey: "placeVotes") }
    }

    /// A new house's name until the address names it ("Casa", "Casa 2").
    static func defaultName(_ count: Int) -> String { count == 0 ? tr("Casa") : tr("Casa \(count + 1)") }

    /// Adds a house at a spot unless one is already there; the house there either way.
    static func house(at spot: Coordinate, name: String?, in places: inout [HomePlace]) -> HomePlace {
        if let near = nearest(to: spot, in: places), let meters = distance(from: spot, to: near), meters <= sameHouse { return near }
        let place = HomePlace(name: name ?? defaultName(places.count), coordinate: spot, isAutomatic: name == nil ? true : nil)
        places.append(place)
        return place
    }

    /// Spots of houses removed by hand: never made again by themselves.
    static var removedSpots: [Coordinate] {
        get { Preferences.decoded([Coordinate].self, forKey: "placesRemoved") ?? [] }
        set { Preferences.setEncoded(Array(newValue.suffix(40)), forKey: "placesRemoved") }
    }

    /// Removes a house (its devices go back to where the Lar finds them); one found by itself isn't found again.
    public static func remove(_ id: String) {
        if let place = all.first(where: { $0.id == id }) { removedSpots += place.spots }
        all.removeAll { $0.id == id }
        learned = learned.filter { $0.value != id }
        if currentID == id { currentID = nil }
    }

    static func wasRemoved(_ spot: Coordinate) -> Bool {
        removedSpots.contains { distance($0, spot) <= sameHouse }
    }

    /// Houses from the devices' own spots (SmartThings' locations, where Smart Life paired them): one per spot,
    /// named by the account when it says. True when something changed.
    @discardableResult
    public static func discover(from devices: [HomeDevice], home: Coordinate? = nil) -> Bool {
        var places = all
        let before = places
        // The home marked for arriving and leaving is the main house.
        if let home, !wasRemoved(home) { _ = house(at: home, name: nil, in: &places) }
        for device in devices {
            guard let geo = device.geo, !wasRemoved(geo) || nearest(to: geo, in: places).flatMap({ distance(from: geo, to: $0) }).map({ $0 <= sameHouse }) == true else { continue }
            let place = house(at: geo, name: device.accountPlace, in: &places)
            // An automatic name gives way to the account's ("Casa 2" → "Praia").
            if let name = device.accountPlace, place.isAutomatic == true, let index = places.firstIndex(of: place) {
                places[index].name = name
                places[index].isAutomatic = nil
            }
        }
        guard places != before else { return false }
        all = places
        return true
    }

    /// A night spent at a spot (the iPhone's visits): the second one there makes it a house. True when it did.
    @discardableResult
    public static func noteNight(at spot: Coordinate) -> Bool {
        var nights = Preferences.decoded([Coordinate].self, forKey: "placeNights") ?? []
        if let near = nearest(to: spot, in: all), let meters = distance(from: spot, to: near), meters <= sameHouse { return false }
        if wasRemoved(spot) { return false }
        let before = nights.filter { distance($0, spot) <= sameHouse }.count
        nights.append(spot)
        Preferences.setEncoded(Array(nights.suffix(40)), forKey: "placeNights")
        guard before >= 1 else { return false }
        var places = all
        _ = house(at: spot, name: nil, in: &places)
        all = places
        return true
    }

    /// Where this device was a moment ago (the iPhone's last location), for the commands sent now to teach.
    public static var recentSpot: Coordinate? {
        get { spot.withLock { $0.flatMap { Date().timeIntervalSince($0.at) < 15 * 60 ? $0.spot : nil } } }
        set { spot.withLock { $0 = newValue.map { (spot: $0, at: Date()) } } }
    }
    private static let spot = Mutex<(spot: Coordinate, at: Date)?>(nil)

    /// A device used (a command sent) while this device is at a house: after a few times it's known to be there.
    /// Devices with a spot of their own, and uses away from every house, teach nothing.
    public static func noteUse(of device: HomeDevice, at spot: Coordinate) {
        guard device.geo == nil, let near = nearest(to: spot, in: all), let meters = distance(from: spot, to: near),
              meters <= radius else { return }
        var all = votes
        all[device.id, default: [:]][near.id, default: 0] += 1
        votes = all
        if let best = all[device.id]?.max(by: { $0.value < $1.value }), learned[device.id] != best.key {
            learned[device.id] = best.key
        }
    }

    /// The house nearest to a spot (only the ones marked on the map).
    public static func nearest(to spot: Coordinate, in places: [HomePlace]) -> HomePlace? {
        places.compactMap { place in place.spots.map { distance($0, spot) }.min().map { (place, $0) } }.min { $0.1 < $1.1 }?.0
    }

    /// Meters from a spot to a house (its nearest spot); nil when it has none.
    static func distance(from spot: Coordinate, to place: HomePlace) -> Double? {
        place.spots.map { distance($0, spot) }.min()
    }

    /// Notes where this device is: the nearest house becomes the current one. True when it changed.
    @discardableResult
    public static func update(at spot: Coordinate) -> Bool {
        guard let place = nearest(to: spot, in: all), place.id != currentID else { return false }
        currentID = place.id
        return true
    }

    /// Meters between two spots (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// The room temperature to show: the house's air conditioners first, then its sensors.
    public static func roomTemperature(_ devices: [HomeDevice]) -> Double? {
        let online = devices.filter(\.isOnline)
        return online.first { $0.kind == .airConditioner && $0.isOn == true }?.roomTemperature
            ?? online.compactMap(\.roomTemperature).first
            ?? devices.compactMap(\.roomTemperature).first
    }
}
