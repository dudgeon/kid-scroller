import SwiftUI
import UIKit
import AVFoundation
import SameAgeCore

/// A video page in fullscreen.
///
/// Deliberately **not** SwiftUI's `VideoPlayer`: that wraps the system controls overlay,
/// whose AirPlay button sat directly over our dismiss button and intercepted its taps —
/// the app's own chrome must be the only chrome. This hosts a bare `AVPlayerLayer` with
/// one interaction: tap to play/pause.
///
/// In the feed, videos autoplay **muted** because you didn't ask for them (R15). Tapping
/// one through to fullscreen is an explicit request to watch it, so here it plays with
/// sound.
struct FullscreenVideoPage: View {
    let item: FeedItem
    let isActive: Bool
    /// Poster frame from the image pipeline, shown while the player item loads so the
    /// page is never blank.
    let poster: UIImage?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            } else if let poster {
                Image(uiImage: poster).resizable().scaledToFit()
            }

            if loadFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Couldn't load this video").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else if player == nil {
                ProgressView().tint(.white)
            } else if !isPlaying {
                // Paused: a single unobtrusive affordance, and the only overlay there is.
                Image(systemName: "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .task(id: item.id) { await load() }
        .onChange(of: isActive) { _, nowActive in
            // Swiping to another page must silence this one; swiping back resumes.
            nowActive ? play() : pause()
        }
        .onDisappear { pause() }
    }

    private func toggle() {
        isPlaying ? pause() : play()
    }

    private func play() {
        player?.play()
        isPlaying = true
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }

    private func load() async {
        guard player == nil else { return }

        // A video the user chose to open should be audible even with the ring switch
        // silenced — the default session would produce no sound at all.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let playerItem = await ThumbnailProvider.shared
            .requestPlayerItem(identifier: item.assetIdentifier) else {
            loadFailed = true
            return
        }

        let created = AVPlayer(playerItem: playerItem)
        player = created

        // At the end, rewind and pause so the tap affordance reappears — looping with
        // sound is grating in a way muted feed loops are not.
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { _ in
            created.seek(to: .zero)
            Task { @MainActor in isPlaying = false }
        }

        if isActive { play() }
    }

    /// Bare `AVPlayerLayer` host — no controls, no AirPlay chrome.
    private struct PlayerLayerView: UIViewRepresentable {
        let player: AVPlayer

        final class LayerHost: UIView {
            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        }

        func makeUIView(context: Context) -> LayerHost {
            let host = LayerHost()
            host.playerLayer.player = player
            host.playerLayer.videoGravity = .resizeAspect
            return host
        }

        func updateUIView(_ host: LayerHost, context: Context) {
            if host.playerLayer.player !== player { host.playerLayer.player = player }
        }
    }
}
