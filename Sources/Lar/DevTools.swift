import AppKit
import LarCore
import SwiftUI

/// `Lar --snapshot <dir>` renders the popover offscreen in a few fixed states, for visual checks
/// without a menu bar or network.
@MainActor
enum DevTools {
    static var sampleDevices: [HomeDevice] { [
        HomeDevice(provider: .androidTV, rawID: "SERIAL1", name: String(localized: "TV do Quarto"), kind: .tv, isOn: true,
                   detail: "Crunchyroll", controls: ["app": "com.crunchyroll.crunchyroid", "host": "192.168.1.50"]),
        HomeDevice(provider: .androidTV, rawID: "192.168.1.51", name: String(localized: "TV da Sala"), kind: .tv, isOnline: false,
                   detail: String(localized: "Aceite “Permitir depuração USB?” na TV"), controls: ["host": "192.168.1.51"]),
        HomeDevice(provider: .lg, rawID: "ac", name: String(localized: "Ar do Escritório"), kind: .airConditioner, isOn: true,
                   detail: String(localized: "Ambiente 26° · ajustado em 22°"), controls: ["operation": "airConOperationMode"]),
        HomeDevice(provider: .lg, rawID: "w", name: String(localized: "Lavadora"), kind: .laundry, isOn: true,
                   detail: String(localized: "Enxaguando · faltam 0:07"), controls: ["operation": "washerOperationMode"]),
        HomeDevice(provider: .tuya, rawID: "l1", name: String(localized: "Luz da Varanda"), kind: .light, isOn: true, brightness: 0.6,
                   color: LightColor(hue: 30, saturation: 1), controls: ["switch": "switch_led"]),
        HomeDevice(provider: .tuya, rawID: "l2", name: String(localized: "Luzes do Jardim"), kind: .plug, isOn: false,
                   controls: ["switch": "switch_1"]),
        HomeDevice(provider: .tuya, rawID: "l3", name: String(localized: "Abajur do quarto"), kind: .light, isOnline: false, isOn: false),
        HomeDevice(provider: .tuya, rawID: "c1", name: String(localized: "Câmera do portão"), kind: .camera),
        HomeDevice(provider: .tuya, rawID: "s1", name: String(localized: "Sensor da sala"), kind: .climateSensor, detail: "24° · 61%"),
        HomeDevice(provider: .xbox, rawID: "console", name: "Xbox", kind: .gameConsole, isOn: true, detail: "Minecraft"),
    ] }

    static func renderSnapshots(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The Mac App Store's screenshots: as that version is, without the intercom.
        if CommandLine.arguments.contains("--no-intercom") { Features.intercom = false }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let home = HomeStore(previewDevices: sampleDevices)
        let model = AppModel(preview: home)
        model.scenes.save(HomeScene(name: String(localized: "Dormir"), symbol: "moon.fill", actions: HomeScene.actions(for: sampleDevices[0], on: false)))
        model.scenes.save(HomeScene(name: String(localized: "Cinema"), symbol: "film", actions: HomeScene.actions(for: sampleDevices[0], on: true)))
        write(HomeView(model: model, fixedDate: date), "list", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .scene(id: model.scenes.scenes.first?.id)), "scene", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .dialer), "dialer", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .light(id: "tuya:l1")), "light", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .settings), "settings", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .tv(id: "androidTV:SERIAL1")), "tv", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .tv(id: "xbox:console")), "xbox", to: directory)
        write(HomeView(model: model, fixedDate: date, initialRoute: .about), "about", to: directory)

        let failing = HomeStore(previewDevices: sampleDevices, accounts: [.lg: .connected, .tuya: .unauthorized])
        write(HomeView(model: AppModel(preview: failing), fixedDate: date), "account-problem", to: directory)

        let empty = HomeStore(previewDevices: [], accounts: [.lg: .connected])
        write(HomeView(model: AppModel(preview: empty), fixedDate: date), "empty", to: directory)

        let caps = ACCapabilities(
            modes: [ACMode.fan, ACMode.dry, ACMode.auto, ACMode.cool], fanSpeeds: ["LOW", "MID", "HIGH", "AUTO"],
            minTemperature: 18, maxTemperature: 30, temperatureStep: 0.5,
            supportsEco: true, supportsSwing: true, supportsSleep: true
        )
        let status = ACStatus(isOn: true, mode: ACMode.cool, currentTemperature: 26, targetTemperature: 22, fanSpeed: "AUTO", swing: false, eco: false)
        let ac = ACStore(previewStatus: status, capabilities: caps)
        write(HomeView(model: AppModel(preview: home, airConditioner: ac), fixedDate: date, initialRoute: .airConditioner(rawID: "ac")),
              "air-conditioner", to: directory)
        print("Snapshots written to \(directory.path)")
    }

    private static func write<V: View>(_ view: V, _ name: String, to directory: URL) {
        render(view, to: directory.appendingPathComponent("\(name).png"))
        renderNative(view, to: directory.appendingPathComponent("\(name)-native.png"))
    }

    /// Waits for the live store to load, then renders the popover with real data
    /// (`LAR_LIVE_SNAPSHOT=<file.png>`).
    static func snapshotLive(model: AppModel, to url: URL) {
        Task {
            for _ in 0..<60 where model.home.devices.isEmpty || model.home.isRefreshing {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            renderNative(HomeView(model: model, fixedDate: Date()), to: url)
            print("Live snapshot written to \(url.path)")
        }
    }

    /// Faithful for SwiftUI drawing (transforms, canvas), but AppKit-backed controls (switches,
    /// pop-up buttons, segmented controls, text fields) come out as placeholders.
    private static func render<V: View>(_ view: V, to url: URL) {
        let root = view
            .background(Color(white: 0.11))
            .environment(\.colorScheme, .dark)
            .environment(\.rendersWithoutScrolling, true)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Draws through an offscreen window so native controls render, at the cost of scale/3D
    /// transforms (the unit illustration lands out of place) and an inactive-window look.
    private static func renderNative<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(white: 0.11)).environment(\.rendersWithoutScrolling, true))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
