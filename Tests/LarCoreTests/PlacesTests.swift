import Foundation
import Testing
@testable import LarCore

/// Several houses: each shows its own devices and temperature, never another's.
@Suite(.serialized) struct PlacesTests {
    let casa1 = HomePlace(id: "1", name: "Casa 1", coordinate: Coordinate(latitude: -23.55, longitude: -46.63))
    let casa2 = HomePlace(id: "2", name: "Praia", coordinate: Coordinate(latitude: -23.80, longitude: -45.40))
    let casa3 = HomePlace(id: "3", name: "Sítio", coordinate: Coordinate(latitude: -22.90, longitude: -47.06))

    func ac(_ id: String, room: Double, on: Bool = true) -> HomeDevice {
        HomeDevice(provider: .lg, rawID: id, name: "Ar \(id)", kind: .airConditioner, isOn: on,
                   controls: ["roomTemperatureValue": "\(room)"])
    }

    @Test func eachHouseShowsItsOwnAir() {
        let devices = [ac("a", room: 29), ac("b", room: 22), ac("c", room: 18)]
        let custom = [devices[0].id: DeviceCustomization(place: "1"), devices[1].id: DeviceCustomization(place: "2"),
                      devices[2].id: DeviceCustomization(place: "3")]
        let places = [casa1, casa2, casa3]
        for (current, expected) in [("1", 29.0), ("2", 22.0), ("3", 18.0)] {
            let here = HomePlaces.here(devices, customizations: custom, places: places, currentID: current)
            #expect(here.map(\.rawID) == [["1": "a", "2": "b", "3": "c"][current]!])
            #expect(HomePlaces.roomTemperature(here) == expected)
        }
    }

    @Test func unassignedDevicesAreInTheMainHouse() {
        let devices = [ac("a", room: 29), ac("b", room: 22)]
        let custom = [devices[1].id: DeviceCustomization(place: "2")]
        #expect(HomePlaces.here(devices, customizations: custom, places: [casa1, casa2], currentID: "1").map(\.rawID) == ["a"])
        #expect(HomePlaces.here(devices, customizations: custom, places: [casa1, casa2], currentID: "2").map(\.rawID) == ["b"])
        // One house (or none): everything is here.
        #expect(HomePlaces.here(devices, customizations: custom, places: [casa1], currentID: nil).count == 2)
        #expect(HomePlaces.here(devices, customizations: custom, places: [], currentID: nil).count == 2)
    }

    @Test func theNearestHouseIsTheCurrentOne() {
        let nearBeach = Coordinate(latitude: -23.801, longitude: -45.401)
        #expect(HomePlaces.nearest(to: nearBeach, in: [casa1, casa2, casa3])?.id == "2")
        #expect(HomePlaces.distance(casa1.coordinate!, casa1.coordinate!) < 1)
        #expect(abs(HomePlaces.distance(Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 1)) - 111_195) < 100)
    }

    @Test func theAirThatIsOnGivesTheTemperature() {
        let devices = [ac("off", room: 30, on: false), ac("on", room: 24)]
        #expect(HomePlaces.roomTemperature(devices) == 24)
    }

    @Test func placesTravelWithTheScenes() {
        let settings = InMemorySettings()
        settings.places = [casa1, casa2]
        let state = SyncState.capture(settings)
        let other = InMemorySettings()
        state.apply(to: other)
        #expect(other.places == [casa1, casa2])
        var older = state
        older.places = nil
        #expect(SyncState.direction(local: state, remote: older) == nil)
    }

    @Test func housesComeFromTheAccountsAndTheNights() {
        HomePlaces.all = []
        HomePlaces.learned = [:]
        Preferences.set(nil, forKey: "placeNights")
        Preferences.set(nil, forKey: "placeVotes")
        Preferences.set(nil, forKey: "placesRemoved")
        defer { HomePlaces.all = []; HomePlaces.learned = [:] }
        var beach = ac("st", room: 25)
        beach.controls["geo"] = "-23.8,-45.4"
        beach.controls["placeName"] = "Praia"
        let lg = ac("lg", room: 29)
        // The home marked on the iPhone is the main house; SmartThings' location is another, with its name.
        #expect(HomePlaces.discover(from: [beach, lg], home: casa1.coordinate))
        #expect(HomePlaces.all.map(\.name) == ["Casa", "Praia"])
        #expect(!HomePlaces.discover(from: [beach, lg], home: casa1.coordinate))
        // One night somewhere new isn't a house; the second is.
        #expect(!HomePlaces.noteNight(at: casa3.coordinate!))
        #expect(HomePlaces.noteNight(at: Coordinate(latitude: -22.9005, longitude: -47.0605)))
        #expect(HomePlaces.all.count == 3)
        // The LG air used from the third house is in it; used from far away teaches nothing.
        let third = HomePlaces.all[2]
        HomePlaces.noteUse(of: lg, at: Coordinate(latitude: 10, longitude: 10))
        #expect(HomePlaces.learned[lg.id] == nil)
        HomePlaces.noteUse(of: lg, at: casa3.coordinate!)
        #expect(HomePlaces.learned[lg.id] == third.id)
        let places = HomePlaces.all
        #expect(HomePlaces.placeID(of: beach, customizations: [:], places: places, learned: HomePlaces.learned) == places[1].id)
        #expect(HomePlaces.placeID(of: lg, customizations: [:], places: places, learned: HomePlaces.learned) == third.id)
        // At the beach, the beach's temperature.
        let here = HomePlaces.here([beach, lg], customizations: [:], places: places, currentID: places[1].id, learned: HomePlaces.learned)
        #expect(HomePlaces.roomTemperature(here) == 25)
    }

    @Test func aRemovedHouseIsntFoundAgain() {
        HomePlaces.all = []
        Preferences.set(nil, forKey: "placesRemoved")
        defer { HomePlaces.all = []; Preferences.set(nil, forKey: "placesRemoved") }
        var beach = ac("st", room: 25)
        beach.controls["geo"] = "-23.8,-45.4"
        HomePlaces.discover(from: [beach], home: casa1.coordinate)
        #expect(HomePlaces.all.count == 2)
        HomePlaces.remove(HomePlaces.all[1].id)
        #expect(!HomePlaces.discover(from: [beach], home: casa1.coordinate))
        #expect(HomePlaces.all.count == 1)
        // Made again by hand there, it stays.
        HomePlaces.all.append(HomePlace(name: "Praia", coordinate: Coordinate(latitude: -23.8, longitude: -45.4)))
        #expect(!HomePlaces.discover(from: [beach], home: casa1.coordinate))
        #expect(HomePlaces.all.count == 2)
    }

    @Test func whatIsEditedByHandStays() {
        HomePlaces.all = []
        Preferences.set(nil, forKey: "placesRemoved")
        defer { HomePlaces.all = [] }
        var beach = ac("st", room: 25)
        beach.controls["geo"] = "-23.8,-45.4"
        beach.controls["placeName"] = "Praia"
        HomePlaces.discover(from: [beach], home: casa1.coordinate)
        var places = HomePlaces.all
        // Renamed and moved by hand (say the account's spot was wrong).
        let moved = Coordinate(latitude: -23.75, longitude: -45.30)
        places[1] = places[1].edited(name: "Casa de praia", coordinate: moved)
        HomePlaces.all = places
        // The next reads keep it: no house again at the old spot, no name from the account, the device still in it.
        #expect(!HomePlaces.discover(from: [beach], home: casa1.coordinate))
        #expect(HomePlaces.all.count == 2)
        #expect(HomePlaces.all[1].name == "Casa de praia")
        #expect(HomePlaces.all[1].coordinate == moved)
        #expect(HomePlaces.placeID(of: beach, customizations: [:], places: HomePlaces.all) == HomePlaces.all[1].id)
        // A device put in a house by hand stays there, whatever its account says.
        let custom = [beach.id: DeviceCustomization(place: HomePlaces.all[0].id)]
        #expect(HomePlaces.placeID(of: beach, customizations: custom, places: HomePlaces.all) == HomePlaces.all[0].id)
    }

    @Test func whatIsOnIsCountedPerHouse() {
        HomePlaces.all = [casa1, casa2]
        HomePlaces.currentID = "2"
        defer { HomePlaces.all = []; HomePlaces.currentID = nil }
        let devices = [ac("a", room: 29), ac("b", room: 22), ac("c", room: 20, on: false)]
        let custom = [devices[1].id: DeviceCustomization(place: "2"), devices[2].id: DeviceCustomization(place: "2")]
        let split = HomePlaces.switchedOn(devices, customizations: custom)
        #expect(split.here.map(\.rawID) == ["b"])
        #expect(split.elsewhere == 1)
        // Leaving the beach: the alert names it.
        #expect(HomeWatch.forgotOnAlert([devices[1]], house: "Praia")?.title == "Ficou ligado: Praia")
        #expect(HomeWatch.forgotOnAlert([devices[1]])?.title == "Ficou ligado")
    }

    @MainActor @Test func theListShowsGeralOrOneHouse() async {
        HomePlaces.all = [casa1, casa2]
        defer { HomePlaces.all = [] }
        let devices = [ac("a", room: 29), ac("b", room: 22)]
        let store = HomeStore(makeProviders: { [] })
        store.seed(devices)
        store.customize(devices[1].id) { $0.place = "2" }
        #expect(store.visibleSections(grouping: .kind).flatMap(\.devices).count == 2)
        store.viewingPlace = "2"
        #expect(store.visibleSections(grouping: .kind).flatMap(\.devices).map(\.rawID) == ["b"])
        store.viewingPlace = "1"
        #expect(store.visibleSections(grouping: .kind).flatMap(\.devices).map(\.rawID) == ["a"])
        #expect(store.viewedOnCount == 1)
    }

    @Test func oneHouseIsSharedOnItsOwn() {
        let a = ac("a", room: 29), b = ac("b", room: 22)
        let devices = [a, b]
        let sceneA = HomeScene(name: "Casa", symbol: "house", actions: [.init(deviceID: a.id, deviceName: a.name, command: .power(true))])
        let sceneB = HomeScene(name: "Praia", symbol: "sun.max", actions: [.init(deviceID: b.id, deviceName: b.name, command: .power(true))])
        let whole = SyncState(scenes: [sceneA, sceneB],
                              customizations: [a.id: DeviceCustomization(name: "Ar da sala"), b.id: DeviceCustomization(name: "Ar", place: "2")],
                              grouping: .kind, updatedAt: Date(timeIntervalSince1970: 100), places: [casa1, casa2])
        let beach = SyncState.house("2", from: whole, devices: devices)
        #expect(beach.sharedDevices == [b.id])
        #expect(beach.scenes.map(\.name) == ["Praia"])
        #expect(beach.customizations.keys.sorted() == [b.id])
        #expect(beach.places?.map(\.id) == ["2"])
        // The guest renames the air and deletes the scene: it comes back so, the other house untouched.
        var guest = beach
        guest.customizations[b.id]?.name = "Ar da praia"
        guest.scenes = []
        guest.updatedAt = Date(timeIntervalSince1970: 200)
        let merged = whole.merging(house: guest)
        #expect(merged.customizations[b.id]?.name == "Ar da praia")
        #expect(merged.customizations[a.id]?.name == "Ar da sala")
        #expect(merged.scenes.map(\.name) == ["Casa"])
    }

    @MainActor @Test func aGuestSeesOnlyTheirHouse() {
        defer { HomePlaces.guestDevices = nil }
        let devices = [ac("a", room: 29), ac("b", room: 22)]
        let store = HomeStoreProbe.sections(devices, guest: [devices[1].id])
        #expect(store == ["b"])
    }
}

@MainActor enum HomeStoreProbe {
    static func sections(_ devices: [HomeDevice], guest: Set<String>) -> [String] {
        HomePlaces.guestDevices = guest
        let store = HomeStore(makeProviders: { [] })
        store.seed(devices)
        return store.sections(grouping: .kind).flatMap(\.devices).map(\.rawID)
    }
}
