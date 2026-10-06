import Foundation
import SharedCore
import UIKit

/// Engine-agnostic watch-progress + tracker scrobbling (Trakt directly, Simkl and any other connected
/// tracker through `TrackingScrobbleCoordinator.scrobbleOtherTrackers`) for a `PlaybackContext`. Mirrors the logic in
/// `MPVTVPlayerViewController` exactly so both engines record identically; the native AVPlayer path
/// (Phase 3) uses it. The mpv controller can be migrated onto this later — it still has its own copy
/// for now to avoid touching the shipping player. See docs/tvos-hybrid-player-plan.md.
@MainActor
final class PlaybackProgressRecorder {
    private let context: PlaybackContext

    init(context: PlaybackContext) { self.context = context }

    // MARK: - Resume

    /// Saved resume position in seconds — only if >10s in and not completed (mirrors MPV's gate).
    /// `durationSec` is the opened file's duration: a row with a percentage and no timecode (Simkl
    /// episode or Trakt playback row, upstream b7657dbe4) resumes at that share of it.
    /// nil for a Start Over launch (`PlaybackContext.resumeFromStart`, PLY-A13).
    func resumePositionSec(durationSec: Double = 0) -> Double? {
        guard !context.resumeFromStart else { return nil }
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: context.videoId,
            parentMetaId: context.parentMetaId,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) }
        ), !entry.isCompleted else { return nil }
        var seconds = Double(entry.lastPositionMs) / 1000.0
        if seconds <= 0, entry.durationMs <= 0, durationSec.isFinite, durationSec > 0 {
            seconds = Double(entry.progressFraction) * durationSec
        }
        return seconds > 10 ? seconds : nil
    }

    // MARK: - Progress save

    // CW-1: filed under the SERIES name with the episode's own name/still beside it (mobile
    // parity) — `context.title` is the "S1E3 · Pilot" picker label, which Continue Watching, the
    // hero and the synced record used to show as the show's title.
    private lazy var session = WatchProgressPlaybackSession(
        profileId: ActiveProfileProvider.shared.activeProfileId,
        contentType: context.contentType,
        parentMetaId: context.parentMetaId,
        parentMetaType: context.contentType,
        videoId: context.videoId,
        title: context.progressTitle,
        logo: context.logo,
        poster: context.poster,
        background: context.background,
        seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
        episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
        episodeTitle: context.episodeTitle,
        episodeThumbnail: context.episodeStill,
        providerName: context.providerName,
        providerAddonId: context.providerAddonId,
        lastStreamTitle: context.streamTitle,
        lastStreamSubtitle: context.streamSubtitle,
        pauseDescription: context.synopsis,
        lastSourceUrl: context.url.absoluteString
    )

    /// PLY-4: the last periodic tick, and whether it was playing — a pause pushes the position to
    /// the account (mobile flushes on every playing → paused), and so does the app leaving the
    /// foreground mid-playback (the TV button, sleep): neither reaches the teardown flush.
    private var lastTick: (positionSec: Double, durationSec: Double, speed: Double)?
    private var lastTickWasPlaying = false
    private var backgroundObserver: NSObjectProtocol?

    /// Record playback progress. `flush` forces an immediate write (use on teardown). `isEnded`
    /// records the entry as completed regardless of the watched fraction — the end of the file,
    /// or an Up Next hand-off during the credits — so Continue Watching moves on to the next one.
    /// `isBuffering`: a stall, not a pause (a periodic tick while it lasts is not flushed).
    func record(positionSec: Double, durationSec: Double, isPaused: Bool, speed: Double, flush: Bool,
                isEnded: Bool = false, isBuffering: Bool = false) {
        guard durationSec > 0, positionSec > 1 else { return }
        var flush = flush
        if flush {
            // A terminal write (teardown, the end of the file): nothing is left for a later
            // background flush to re-send — it would overwrite this record with an older tick.
            lastTick = nil
            lastTickWasPlaying = false
        } else {
            observeBackgroundIfNeeded()
            // A session requested before the file knew its duration (an HLS item at readyToPlay)
            // reaches the other trackers with the first tick that knows it.
            openOtherTrackersIfReady(positionSec: positionSec, durationSec: durationSec)
            if isPaused && !isBuffering && lastTickWasPlaying { flush = true }
            if !isBuffering { lastTickWasPlaying = !isPaused }
            lastTick = (positionSec: positionSec, durationSec: durationSec, speed: speed)
        }
        let snapshot = PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: !isPaused,
            isEnded: isEnded,
            durationMs: Int64(durationSec * 1000),
            positionMs: Int64(positionSec * 1000),
            bufferedPositionMs: Int64(positionSec * 1000),
            playbackSpeed: Float(speed),
            videoWidth: 0,
            videoHeight: 0
        )
        if flush {
            // PLY-4: the terminal write reaches the Nuvio account (mobile `flushWatchProgress`
            // parity) — and, through the shared completion cascade, marks a finished episode
            // watched there too. The 3 s ticks below stay local; the push is deduplicated.
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: true)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    /// PLY-4: installed with the first tick, so a recorder that never plays observes nothing.
    private func observeBackgroundIfNeeded() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushLastTick() }
        }
    }

    /// The app left the foreground: the last tick (at most one tick interval old) goes to the
    /// account as it stands.
    private func flushLastTick() {
        guard let tick = lastTick else { return }
        record(positionSec: tick.positionSec, durationSec: tick.durationSec, isPaused: !lastTickWasPlaying,
               speed: tick.speed, flush: true)
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    // MARK: - Trakt scrobbling

    private var traktItem: TraktScrobbleItem?
    private var traktRequested = false
    private var traktClosed = false
    /// The other trackers' scrobble (Simkl — every connected tracker but Trakt, through
    /// `TrackingScrobbleCoordinator.scrobbleOtherTrackers`) is open: started with the Trakt session
    /// but independently of its item build, which returns nil for `kitsu:`/`mal:` ids. Cleared by the
    /// one stop, so a second `stop()` of the coordinator sends nothing.
    private var otherTrackersOpen = false

    func startTrakt(positionSec: Double, durationSec: Double) {
        guard !traktRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) { return }
        traktRequested = true
        // Not behind the Trakt item build below: it returns nil for ids Trakt can't address
        // (`kitsu:`, `mal:` …), which Simkl can.
        openOtherTrackersIfReady(positionSec: positionSec, durationSec: durationSec)
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.progressTitle,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: context.episodeTitle,
            releaseInfo: nil
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, let item, !self.traktClosed else { return }
                self.traktItem = item
                TraktScrobbleRepository.shared.scrobbleStart(
                    profileId: ActiveProfileProvider.shared.activeProfileId,
                    item: item,
                    progressPercent: Self.percent(positionSec, durationSec)
                ) { _ in }
            }
        }
    }

    /// Opens the other trackers' session once the Trakt session is requested and the file's
    /// duration is known. That is at `startTrakt`, or at the first tick that knows the duration
    /// when an HLS item did not know it at readyToPlay.
    ///
    /// Why wait for the duration: a start sent at 0 % would end with a stop at 0 %, and that stop
    /// replaces the show's real Simkl resume point.
    ///
    /// Never once the session is closed: a start that lands after the viewer left, while the resume
    /// seek was still in flight, would have no stop.
    private func openOtherTrackersIfReady(positionSec: Double, durationSec: Double) {
        guard traktRequested, !traktClosed, !otherTrackersOpen, durationSec > 0,
              !WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) else { return }
        otherTrackersOpen = true
        scrobbleOtherTrackers(TrackingScrobbleAction.start, percent: Self.percent(positionSec, durationSec))
    }

    /// A new viewing on this recorder ("Play Again" after the session was stopped): the next
    /// `startTrakt` opens a fresh scrobble instead of being ignored as a repeat.
    func reopenTrakt() {
        traktItem = nil
        traktRequested = false
        traktClosed = false
        otherTrackersOpen = false
    }

    /// `positionSec` is the duration for a finished or handed-off episode
    /// (`NativePlaybackCoordinator.stop()`), so an autoplayed episode closes at 100 %.
    func stopTrakt(positionSec: Double, durationSec: Double) {
        traktClosed = true
        // A session can open before a placeholder's short duration is known; close
        // it at 0% so Trakt never marks the stub watched.
        let short = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000))
        let percent: Float = short ? 0 : Self.percent(positionSec, durationSec)
        if otherTrackersOpen {
            otherTrackersOpen = false
            // Not for a placeholder clip, nor with the duration unknown (the percentage would read
            // 0): Simkl keeps one paused session per show, so a stop at 0 % would replace the
            // show's real resume point.
            if !short, durationSec > 0 { scrobbleOtherTrackers(TrackingScrobbleAction.stop, percent: percent) }
        }
        guard let item = traktItem else { return }
        traktItem = nil
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: percent
        ) { _ in }
    }

    /// Start/stop for every connected tracker but Trakt (Simkl). The shared coordinator catches every
    /// failure itself (nothing escapes into Swift) and no-ops when no such tracker is connected.
    private func scrobbleOtherTrackers(_ action: TrackingScrobbleAction, percent: Float) {
        TrackingScrobbleCoordinator.shared.scrobbleOtherTrackers(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            action: action,
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.progressTitle,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: context.episodeTitle,
            progressPercent: Double(percent)
        ) { _ in }
    }

    private static func percent(_ positionSec: Double, _ durationSec: Double) -> Float {
        guard durationSec > 0 else { return 0 }
        return Float(min(100, max(0, positionSec / durationSec * 100)))
    }
}
