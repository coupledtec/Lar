import AVFoundation
import AVKit
import LarCore
import SwiftUI

/// A camera's live video (Tuya's HLS, which AVPlayer plays as it is), muted, like the Mac's camera window. Shared by
/// the iPhone and the watch: the watch asks the cloud for the link itself and plays it through the phone's
/// connection. Leaving the screen stops the video.
struct CameraLiveView: View {
    var home: HomeStore
    var deviceID: String
    /// One of several in a grid: the screen's title is the grid's, not this camera's.
    var isTile = false

    @State private var player: AVPlayer?
    @State private var failure: String?

    private var device: HomeDevice? { home.device(id: deviceID) }

    var body: some View {
        if isTile {
            video
        } else {
            video
                .navigationTitle(device?.name ?? "Câmera")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }

    private var video: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else if let failure {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                    Text(failure)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Tentar de novo") { Task { await load() } }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            } else {
                ProgressView("Conectando…")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .task { await load() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func load() async {
        failure = nil
        player = nil
        do {
            let url = try await home.liveStreamURL(for: deviceID)
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.play()
            self.player = player
        } catch {
            failure = "Não deu para abrir o vídeo.\n" + ((error as? ProviderError)?.message ?? error.localizedDescription)
        }
    }
}

#if os(iOS)
/// Every camera that's online, live, one under the other (the Mac's camera grid window).
struct CameraGridView: View {
    var home: HomeStore

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(home.devices.filter(\.hasLiveVideo)) { camera in
                    VStack(alignment: .leading, spacing: 6) {
                        CameraLiveView(home: home, deviceID: camera.id, isTile: true)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(camera.name).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Câmeras")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
