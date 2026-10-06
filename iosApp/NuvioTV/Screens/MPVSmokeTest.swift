import AVKit
import SwiftUI

#if DEBUG
/// UI-level player smoke: when `debug.mpvSmokeURL` holds a source URL, the root view presents the
/// real `PlayerScreen` (engine routing included) shortly after launch. The native engine is ON by
/// default (beta.13+), so compatible files land on the native AVPlayer screen — handy for headed
/// info-panel checks; write `player.nativeDolbyVision -bool NO` first to force the full libmpv
/// path: event-driven property cache, track-list walks on the event queue, progress saves, and
/// the `[MPVStats]` first-90s diagnostics.
///
/// Sim workflow (mirrors `debug.remuxSmokeURL` — see RemuxSmokeTest.swift):
///   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.mpvSmokeURL -string '<url>'
///   xcrun simctl launch --console-pty <dev> com.nuvio.media.NuvioTV     # grep [MPVSmoke]/[MPVStats]
///   xcrun simctl spawn <dev> defaults delete com.nuvio.media.NuvioTV debug.mpvSmokeURL
///
/// `debug.mpvSmokeDelaySec` (default 2) holds presentation until app bootstrap settles.
struct MPVSmokeModifier: ViewModifier {
    @State private var context: PlaybackContext?
    @State private var armed = false
    /// `debug.avplayerUIURL`: present a bare AVPlayerViewController on an arbitrary URL (e.g. Apple's
    /// reference HLS stream) — a control for what the SIMULATOR's system panel shows (Subtitles /
    /// Audio tabs) independent of our synthesized master.
    @State private var bareURL: URL?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !armed, let raw = UserDefaults.standard.string(forKey: "debug.avplayerUIURL"), let url = URL(string: raw) {
                    armed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { bareURL = url }
                    return
                }
                guard !armed,
                      let raw = UserDefaults.standard.string(forKey: "debug.mpvSmokeURL"),
                      let url = URL(string: raw) else { return }
                armed = true
                let delay = max(UserDefaults.standard.double(forKey: "debug.mpvSmokeDelaySec"), 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("[MPVSmoke] presenting PlayerScreen for \(url)")
                    let poster = UserDefaults.standard.string(forKey: "debug.mpvSmokePosterURL")
                    context = PlaybackContext(
                        url: url, title: "MPV Smoke", contentType: "movie",
                        parentMetaId: "smoke-mpv", videoId: "smoke-mpv",
                        season: nil, episode: nil, poster: poster, background: nil,
                        providerName: nil, providerAddonId: nil,
                        streamTitle: "Smoke.Release.2160p.WEB-DL", streamSubtitle: nil, externalSubtitles: [],
                        // Info-tab header content for headed sim checks (poster optional).
                        synopsis: "Headless smoke run. This synopsis exists so the native player's Info tab header can be checked in the simulator without a signed-in catalog."
                    )
                }
            }
            .fullScreenCover(item: $context) { ctx in
                PlayerScreen(context: ctx, onPlayNext: { _ in })
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $bareURL) { url in
                BareAVPlayerView(url: url).ignoresSafeArea()
            }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

private struct BareAVPlayerView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.player?.play()
        return vc
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
#endif
