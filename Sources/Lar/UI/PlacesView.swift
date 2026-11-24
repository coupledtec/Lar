import CoreLocation
import LarCore
import SwiftUI

/// Ajustes → Casas on the Mac: the houses (found by themselves or made by hand), which one this Mac is at, and an
/// editor for each: name, where it is (this Mac's spot or an address) and its devices. What's changed by hand stays.
struct PlacesView: View {
    var home: HomeStore
    var onChange: () -> Void = {}

    @State private var places = HomePlaces.all
    @State private var current = HomePlaces.currentID
    /// The house being edited ("new" for a new one).
    @State private var editing: String?

    private var here: HomePlace? { HomePlaces.current(in: places, currentID: current) }

    private func count(_ place: HomePlace) -> Int {
        home.devices.filter {
            HomePlaces.placeID(of: $0, customizations: home.customizations, places: places, learned: HomePlaces.learned) == place.id
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if places.isEmpty {
                Text("Nenhuma casa ainda. O Lar encontra as casas pelo endereço que a conta do aparelho informa (SmartThings, Smart Life) e pelo iPhone; ou crie uma.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(places) { place in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: place.id == places.first?.id ? "house.fill" : "house")
                            .foregroundStyle(Theme.secondaryText)
                        Text(place.name).font(.system(size: 12, weight: .medium))
                        Text(count(place) == 1 ? "1 aparelho" : "\(count(place)) aparelhos")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        if places.count > 1, place.id == here?.id {
                            Text("Este Mac está aqui").font(.system(size: 10)).foregroundStyle(.green)
                        }
                        Button(editing == place.id ? "Fechar" : "Editar") { editing = editing == place.id ? nil : place.id }
                            .controlSize(.small)
                    }
                    if editing == place.id {
                        PlaceEditor(home: home, place: place) { done() }
                    }
                }
            }
            HStack {
                Button {
                    editing = editing == "new" ? nil : "new"
                } label: {
                    Label("Nova casa", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
            }
            if editing == "new" {
                PlaceEditor(home: home, place: nil) { done() }
            }
            Text("A temperatura e os aparelhos mostrados são os da casa onde você está, ou da mais próxima. O que você muda aqui fica valendo e vai para o iPhone e o relógio.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: HomePlaces.changed).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() {
        places = HomePlaces.all
        current = HomePlaces.currentID
    }

    private func done() {
        editing = nil
        reload()
        onChange()
    }
}

/// One house's name, spot and devices.
private struct PlaceEditor: View {
    var home: HomeStore
    var place: HomePlace?
    var onDone: () -> Void

    @State private var name = ""
    @State private var coordinate: Coordinate?
    @State private var address = ""
    @State private var chosen: Set<String> = []
    @State private var isMain = false
    @State private var busy = false
    @State private var problem: String?
    @State private var newID = UUID().uuidString

    private var id: String { place?.id ?? newID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Nome (ex.: Praia)", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Casa principal (os aparelhos sem casa ficam nela)", isOn: $isMain)
                .toggleStyle(.checkbox).font(.system(size: 12))
            HStack(spacing: 6) {
                TextField("Endereço", text: $address).textFieldStyle(.roundedBorder).onSubmit(findAddress)
                Button("Buscar", action: findAddress).controlSize(.small)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 6) {
                Button {
                    Task {
                        busy = true
                        if let spot = await MacLocation.shared.here() {
                            coordinate = spot
                            problem = nil
                        } else {
                            problem = String(localized: "Não deu para saber onde o Mac está. Permita a localização em Ajustes do Sistema → Privacidade.")
                        }
                        busy = false
                    }
                } label: {
                    Label("Usar a localização deste Mac", systemImage: "location.fill")
                }
                .controlSize(.small)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if let coordinate {
                    Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Theme.warning) }
            Text("Aparelhos nesta casa").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            ForEach(home.devices) { device in
                Toggle(device.name, isOn: Binding(get: { chosen.contains(device.id) }, set: { on in
                    if on { chosen.insert(device.id) } else { chosen.remove(device.id) }
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }
            HStack {
                if place != nil {
                    Button("Remover esta casa", role: .destructive) {
                        for device in home.devices where home.customization(of: device.id).place == id {
                            home.customize(device.id) { $0.place = nil }
                        }
                        HomePlaces.remove(id)
                        onDone()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Salvar", action: save)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .onAppear(perform: load)
    }

    private func load() {
        guard let place else { return }
        name = place.name
        coordinate = place.coordinate
        let places = HomePlaces.all
        isMain = places.first?.id == place.id
        chosen = Set(home.devices.filter {
            HomePlaces.placeID(of: $0, customizations: home.customizations, places: places, learned: HomePlaces.learned) == place.id
        }.map(\.id))
    }

    private func findAddress() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            busy = true
            let found = try? await CLGeocoder().geocodeAddressString(text)
            if let location = found?.first?.location {
                coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                problem = nil
            } else {
                problem = String(localized: "Endereço não encontrado.")
            }
            busy = false
        }
    }

    private func save() {
        var places = HomePlaces.all
        let typed = name.trimmingCharacters(in: .whitespaces)
        let edited = place?.edited(name: typed, coordinate: coordinate) ?? HomePlace(id: id, name: typed, coordinate: coordinate)
        if let index = places.firstIndex(where: { $0.id == id }) { places[index] = edited } else { places.append(edited) }
        if isMain, let index = places.firstIndex(where: { $0.id == id }) { places.insert(places.remove(at: index), at: 0) }
        HomePlaces.all = places
        for device in home.devices {
            let mine = home.customization(of: device.id).place == id
            if chosen.contains(device.id), !mine {
                home.customize(device.id) { $0.place = id }
            } else if !chosen.contains(device.id), mine {
                home.customize(device.id) { $0.place = nil }
            }
        }
        MacLocation.shared.locateHouse()
        onDone()
    }
}
