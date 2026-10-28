import AppKit
import AVKit
import LarCore
import SwiftUI

/// A camera's live video in its own window (Tuya's HLS, which AVPlayer plays as it is). One window per camera;
/// opening it again brings it forward. Closing it stops the video.
@MainActor
enum CameraWindow {
    private static var open: [String: (window: NSWindow, closer: Closer)] = [:]

    static func show(device: HomeDevice, home: HomeStore) {
        if let window = open[device.id]?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = device.name
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: CameraView(deviceID: device.id, home: home))
        window.center()
        window.setFrameAutosaveName("Camera-\(device.id)")
        let closer = Closer(id: device.id)
        window.delegate = closer
        open[device.id] = (window, closer)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Every camera live in one window, in a grid (two per row).
    static func showAll(home: HomeStore) {
        let id = "all-cameras"
        if let window = open[id]?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Câmeras"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: CameraGrid(home: home))
        window.center()
        window.setFrameAutosaveName("Camera-grid")
        let closer = Closer(id: id)
        window.delegate = closer
        open[id] = (window, closer)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    fileprivate static func closed(_ id: String) {
        open[id] = nil
    }
}

/// Tears the player down when the window closes, so the stream stops with it.
private final class Closer: NSObject, NSWindowDelegate {
    let id: String

    init(id: String) { self.id = id }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.contentView = nil
        CameraWindow.closed(id)
    }
}

/// The cameras that are online, two per row, each with its name.
private struct CameraGrid: View {
    var home: HomeStore

    var body: some View {
        let cameras = home.devices.filter(\.hasLiveVideo)
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(cameras) { camera in
                    VStack(alignment: .leading, spacing: 4) {
                        CameraView(deviceID: camera.id, home: home)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(camera.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(10)
        }
        .background(Color.black)
    }
}

private struct CameraView: View {
    var deviceID: String
    var home: HomeStore

    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerView(player: player)
            } else if let failure {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 26))
                    Text(failure)
                        .multilineTextAlignment(.center)
                    Button("Tentar de novo") { Task { await load() } }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            } else {
                ProgressView("Conectando à câmera…")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        failure = nil
        do {
            let url = try await home.liveStreamURL(for: deviceID)
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.play()
            self.player = player
        } catch {
            failure = String(localized: "Não deu para abrir o vídeo.") + "\n" + ((error as? ProviderError)?.message ?? error.localizedDescription)
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
