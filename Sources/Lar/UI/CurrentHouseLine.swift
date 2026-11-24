import LarCore
import SwiftUI

/// With more than one house: the one this Mac is in (or nearest to) and its temperature, under the header.
struct CurrentHouseLine: View {
    var home: HomeStore
    @State private var version = 0

    var body: some View {
        content
            .id(version)
            .onReceive(NotificationCenter.default.publisher(for: HomePlaces.changed).receive(on: RunLoop.main)) { _ in version += 1 }
    }

    @ViewBuilder private var content: some View {
        let places = HomePlaces.all
        if places.count > 1, let place = HomePlaces.current(in: places, currentID: HomePlaces.currentID) {
            let here = HomePlaces.here(home.devices, customizations: home.customizations)
            let elsewhere = home.switchedOnHere.elsewhere
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                Text(place.name)
                if elsewhere > 0 {
                    Text(elsewhere == 1 ? String(localized: "· 1 ligado em outra casa") : String(localized: "· \(elsewhere) ligados em outras casas"))
                }
                Spacer()
                if let temperature = HomePlaces.roomTemperature(here) {
                    Text(HomeText.degrees(temperature)).monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// With several houses: Geral (every device, where the menu always opens) or one house's devices only.
struct HouseViewPicker: View {
    var home: HomeStore
    @State private var places = HomePlaces.all

    var body: some View {
        Group {
            if places.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(String(localized: "Geral"), id: nil)
                        ForEach(places) { place in chip(place.name, id: place.id) }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HomePlaces.changed).receive(on: RunLoop.main)) { _ in
            places = HomePlaces.all
            if let id = home.viewingPlace, !places.contains(where: { $0.id == id }) { home.viewingPlace = nil }
        }
    }

    private func chip(_ title: String, id: String?) -> some View {
        let selected = home.viewingPlace == id
        return Button { home.viewingPlace = id } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
