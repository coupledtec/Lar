import Foundation

/// What the owner changed about a device in this app: its name, a favorite, its room, hidden from the list.
/// Kept by device id; the accounts themselves never see it.
public struct DeviceCustomization: Codable, Sendable, Equatable {
    public var name: String?
    public var isFavorite = false
    public var room: String?
    public var isHidden = false

    public init(name: String? = nil, isFavorite: Bool = false, room: String? = nil, isHidden: Bool = false) {
        self.name = name
        self.isFavorite = isFavorite
        self.room = room
        self.isHidden = isHidden
    }

    public var isEmpty: Bool { self == DeviceCustomization() }
}

/// How the list is grouped below the favorites.
public enum DeviceGrouping: String, Codable, Sendable, CaseIterable {
    case kind, room

    public var title: String {
        switch self {
        case .kind: "Tipo"
        case .room: "Cômodo"
        }
    }
}

/// One section of the list.
public struct DeviceSection: Identifiable, Sendable, Equatable {
    public var id: String { title }
    public var title: String
    public var devices: [HomeDevice]
}

extension HomeStore {
    /// The list as every app shows it: favorites first, then by kind or by room; hidden devices left out.
    public func sections(grouping: DeviceGrouping, includeHidden: Bool = false) -> [DeviceSection] {
        let all = devices.filter { includeHidden || customizations[$0.id]?.isHidden != true }
        let favorites = all.filter { customizations[$0.id]?.isFavorite == true }
        let rest = all.filter { customizations[$0.id]?.isFavorite != true }
        var out = favorites.isEmpty ? [] : [DeviceSection(title: "Favoritos", devices: favorites)]
        switch grouping {
        case .kind:
            out += HomeStore.kindOrder.compactMap { kind in
                let matching = rest.filter { $0.kind == kind }
                return matching.isEmpty ? nil : DeviceSection(title: Labels.kindTitle(kind), devices: matching)
            }
        case .room:
            let rooms = Set(rest.compactMap { room(of: $0.id) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            out += rooms.map { room in DeviceSection(title: room, devices: rest.filter { self.room(of: $0.id) == room }) }
            let loose = rest.filter { room(of: $0.id) == nil }
            if !loose.isEmpty { out.append(DeviceSection(title: rooms.isEmpty ? "Aparelhos" : "Sem cômodo", devices: loose)) }
        }
        return out
    }

    /// The rooms already in use, for suggestions.
    public var rooms: [String] {
        Set(customizations.values.compactMap(\.room)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var hiddenDevices: [HomeDevice] { devices.filter { customizations[$0.id]?.isHidden == true } }

    public func customization(of deviceID: String) -> DeviceCustomization { customizations[deviceID] ?? DeviceCustomization() }

    /// Saves a device's customization (an empty one is removed); the list shows it at once.
    public func customize(_ deviceID: String, _ change: (inout DeviceCustomization) -> Void) {
        var value = customization(of: deviceID)
        change(&value)
        value.name = value.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        value.room = value.room?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        customizations[deviceID] = value.isEmpty ? nil : value
    }

    private func room(of deviceID: String) -> String? { customizations[deviceID]?.room }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
