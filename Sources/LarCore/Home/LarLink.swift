import Foundation

/// The app's links, for Shortcuts ("Open URL") and anything else that opens one:
/// `lar://cena/Dormir`, `lar://ligar/TV da Sala`, `lar://desligar/Luz da sala`, `lar://alternar/Abajur`,
/// `lar://temperatura/Ar do quarto/23`, `lar://porteiro` (calls the intercom), `lar://discar/*43`,
/// `lar://encerrar` (ends the call).
/// Names are matched ignoring case and accents.
public enum LarLink: Equatable, Sendable {
    case scene(String)
    case power(device: String, on: Bool?)
    case temperature(device: String, value: Double)
    /// A call: to the intercom (nil) or to a number. The app with the phone handles it.
    case call(String?)
    case hangUp

    public static let scheme = "lar"

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if host == "porteiro" || host == "intercom" {
            self = .call(nil)
            return
        }
        if host == "encerrar" || host == "hangup" {
            self = .hangUp
            return
        }
        guard !name.isEmpty else { return nil }
        switch host {
        case "cena", "scene": self = .scene(name)
        case "discar", "dial": self = .call(name)
        case "ligar", "on": self = .power(device: name, on: true)
        case "desligar", "off": self = .power(device: name, on: false)
        case "alternar", "toggle": self = .power(device: name, on: nil)
        case "temperatura", "temperature":
            // The last path part is the temperature: "Ar do quarto/23".
            guard let slash = name.lastIndex(of: "/"), let value = Double(name[name.index(after: slash)...]) else { return nil }
            self = .temperature(device: String(name[..<slash]), value: value)
        default: return nil
        }
    }

    public static func url(_ link: LarLink) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch link {
        case .scene(let name):
            components.host = "cena"
            components.path = "/" + name
        case .power(let device, let on):
            components.host = on.map { $0 ? "ligar" : "desligar" } ?? "alternar"
            components.path = "/" + device
        case .temperature(let device, let value):
            components.host = "temperatura"
            components.path = "/\(device)/\(HomeText.number(value))"
        case .call(let number):
            components.host = number == nil ? "porteiro" : "discar"
            components.path = number.map { "/" + $0 } ?? ""
        case .hangUp:
            components.host = "encerrar"
        }
        return components.url
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

extension HomeStore {
    /// Runs a link; the message to show when it can't.
    @discardableResult
    public func open(_ link: LarLink, scenes: [HomeScene]) -> String? {
        switch link {
        case .scene(let name):
            guard let scene = scenes.first(where: { LarLink.same($0.name, name) }) else {
                showNotice(tr("Cena “\(name)” não encontrada"))
                return tr("Cena “\(name)” não encontrada")
            }
            return run(scene)
        case .power(let name, let on):
            guard let device = devices.first(where: { LarLink.same($0.name, name) }), let current = device.isOn else {
                showNotice(tr("Aparelho “\(name)” não encontrado"))
                return tr("Aparelho “\(name)” não encontrado")
            }
            perform(.power(on ?? !current), on: device.id)
            return nil
        case .temperature(let name, let value):
            guard let device = devices.first(where: { LarLink.same($0.name, name) }), device.acceptsTemperature else {
                showNotice(tr("Ar-condicionado “\(name)” não encontrado"))
                return tr("Ar-condicionado “\(name)” não encontrado")
            }
            if device.isOn != true { perform(.power(true), on: device.id) }
            perform(.temperature(min(max(value, 16), 30)), on: device.id)
            return nil
        case .call, .hangUp:
            return nil
        }
    }

    /// Waits until the queued commands have gone out (Siri and Shortcuts may suspend the app right after).
    public func waitUntilSent(timeout: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + timeout
        while isSending, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
