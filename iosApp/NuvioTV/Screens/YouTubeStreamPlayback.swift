import Foundation
import SharedCore

/// Plays an add-on stream that only carries a YouTube id (`StreamItem.ytId`, no url / torrent /
/// debrid resolve). The video is resolved on the device with the trailer extractor and handed to
/// the regular player route, so both engines (mpv and the native AVPlayer) open it like any other
/// link.
///
/// The pick differs from a trailer's: a stream is the full video and must have sound.
///  1. the extraction offers a demuxed H.264 + AAC pair worth repackaging: `TrailerLocalHLS`
///     serves it as a local byte-range HLS master (the SABR path every trailer already takes);
///  2. otherwise the HLS master playlist (audio as a rendition), the shared
///     `YouTubeStreamResolver.preferredDirectUrl`;
///  3. otherwise whatever the trailer path would play (the progressive file).
///
/// The result is a short-lived link: it must never be kept for "reuse last link" (see
/// `ContinueWatchingDirectPlay.sourceURL`, which refuses these hosts).
enum YouTubeStreamPlayback {
    /// Deadline for the whole resolve. Kotlin completions cannot be cancelled from Swift, so the
    /// deadline is also handed down to the extractor, which stops its own work at the same time.
    static let timeoutSeconds: Double = 20

    /// The watch-page URL to resolve for `stream`, or nil when the stream plays some other way
    /// (it has a url, a torrent, a debrid resolve, or no `ytId` at all).
    static func watchURL(for stream: StreamItem) -> String? {
        let watch: String? = YouTubeStreamResolver.shared.watchUrlToResolve(stream: stream)
        guard let watch, !watch.isEmpty else { return nil }
        return watch
    }

    /// True for a stream that is resolved through this path.
    static func needsResolving(_ stream: StreamItem) -> Bool {
        watchURL(for: stream) != nil
    }

    /// Resolves `watchUrl` to a playable URL, or nil when the video could not be resolved in time.
    static func resolve(watchUrl: String) async -> URL? {
        let source: TrailerPlaybackSource? = await withCheckedContinuation { continuation in
            let latch = Latch(continuation)
            HeroTrailerResolver.shared.resolveYouTube(
                youtubeUrl: watchUrl,
                timeoutMillis: Int64(timeoutSeconds * 1000)
            ) { source, _ in
                DispatchQueue.main.async { latch.settle(source) }
            }
            // A small margin over the extractor's own deadline: the latch settles once, first wins.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds + 2) { latch.settle(nil) }
        }
        guard let source else { return nil }

        let direct: String? = YouTubeStreamResolver.shared.preferredDirectUrl(source: source)
        if let direct, let url = URL(string: direct) { return url }

        // `playbackURL(for:)` repackages the demuxed pair when there is one, else returns the
        // progressive / HLS URL; both reach the player through the same loopback or CDN route.
        let playable: String? = await TrailerLocalHLS.shared.playbackURL(for: source)
        if let playable, let url = URL(string: playable) { return url }
        let fallback: String = source.videoUrl
        return URL(string: fallback)
    }

    /// One-shot resume for "Kotlin completion handler vs. Swift deadline, first one wins".
    private final class Latch {
        private var continuation: CheckedContinuation<TrailerPlaybackSource?, Never>?

        init(_ continuation: CheckedContinuation<TrailerPlaybackSource?, Never>) {
            self.continuation = continuation
        }

        /// Main-queue only (every call site hops first).
        func settle(_ value: TrailerPlaybackSource?) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }
}
