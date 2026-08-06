import SwiftUI
import AVKit
import AVFoundation
import SameAgeCore

/// A video page in fullscreen.
///
/// In the feed, videos autoplay **muted** because you didn't ask for them (R15). Tapping
/// one through to fullscreen is an explicit request to watch it, so here it plays with
/// sound and system controls.
struct FullscreenVideoPage: View {
    let item: FeedItem
    let isActive: Bool
    /// Poster frame from the image pipeline, shown while the player item loads so the
    /// page is never blank.
    let poster: UIImage?

    @State private var player: AVPlayer?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFit()
                }
                if loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Couldn't load this video").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .task(id: item.id) { await load() }
        .onChange(of: isActive) { _, nowActive in
            nowActive ? player?.play() : player?.pause()
        }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        guard player == nil else { return }

        // A video the user chose to open should be audible even with the ring switch
        // silenced — that's what every video player does, and the default session
        // (.soloAmbient) would silently produce no sound at all.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let playerItem = await ThumbnailProvider.shared
            .requestPlayerItem(identifier: item.assetIdentifier) else {
            loadFailed = true
            return
        }
        let created = AVPlayer(playerItem: playerItem)
        player = created
        if isActive { created.play() }
    }
}
