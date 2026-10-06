import SharedCore
import SwiftUI

/// Engine dispatcher for all video playback in NuvioTV. Call sites present `PlayerScreen`; it probes
/// the stream and routes to the native AVPlayer path (`NativePlayerScreen` — true Dolby Vision via
/// the on-device remux) or the libmpv path (`MPVPlayerScreen` — universal fallback), keeping the
/// choice invisible to callers.
///
/// The native path is gated by `PlayerTuning.nativeDVKey` (Settings > Playback beta toggle). With the
/// flag off, playback goes straight to mpv with no probe delay — non-beta behavior is unchanged. With
/// it on, a brief probe decides per file, and any native-path failure falls back to mpv for the same
/// context. See docs/tvos-hybrid-player-plan.md.
///
/// Owns the `NextEpisodeEngine` for this episode so both engines share it: a native → mpv fallback
/// keeps the Up Next state (trigger, prefetched stream) and resumes mpv at the native position
/// instead of restarting the episode (NE-7/PLY-8).
struct PlayerScreen: View {
    let context: PlaybackContext
    /// Swap in another context (next episode, another source). nil = no autoplay/switching.
    var onPlayNext: ((PlaybackContext) -> Void)?
    /// Leave the player for the details page — the presenter also closes its stream picker, so an
    /// autoplay chain never lands on a previous episode's picker. nil = dismiss the player only.
    var onExitToDetails: (() -> Void)?
    /// Open the stream picker for the next episode (its stream couldn't be auto-selected).
    var onPickNextSource: ((MetaVideo) -> Void)?
    /// The stream can't be played (mpv's error card, PLY-1): close the player onto a stream list for
    /// this episode. nil = no picker behind the player (the card's button just leaves it).
    var onChooseAnotherSource: (() -> Void)?

    @StateObject private var upNext: NextEpisodeEngine
    @State private var decision: EngineDecision?
    /// Set when the native path fails; pins this context to mpv.
    @State private var forcedMPV = false
    /// Where the native engine was when it handed over to mpv.
    @State private var fallbackStartSec: Double?
    /// When this context's playback was asked for: the loading view's delays (black, then a
    /// spinner, then a caption) count from here across the probe and the engine's preparation.
    @State private var loadStartedAt = Date()

    init(context: PlaybackContext,
         onPlayNext: ((PlaybackContext) -> Void)? = nil,
         onExitToDetails: (() -> Void)? = nil,
         onPickNextSource: ((MetaVideo) -> Void)? = nil,
         onChooseAnotherSource: (() -> Void)? = nil) {
        self.context = context
        self.onPlayNext = onPlayNext
        self.onExitToDetails = onExitToDetails
        self.onPickNextSource = onPickNextSource
        self.onChooseAnotherSource = onChooseAnotherSource
        _upNext = StateObject(wrappedValue: NextEpisodeEngine(context: context, onPlayNext: onPlayNext ?? { _ in }))
    }

    private var nativeDVEnabled: Bool { UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey) }

    private enum Shown { case deciding, native, mpv }
    private var shown: Shown {
        if forcedMPV { return .mpv }
        guard nativeDVEnabled else { return .mpv }       // flag off → mpv immediately, no probe wait
        guard let decision else { return .deciding }
        return decision.engine == .native ? .native : .mpv
    }

    var body: some View {
        Group {
            switch shown {
            case .native:
                NativePlayerScreen(context: context, upNext: upNext,
                                   onFallback: { position in
                                       fallbackStartSec = position
                                       forcedMPV = true
                                   },
                                   routingNote: decision?.displayNote,
                                   onExitToDetails: onExitToDetails,
                                   onPickNextSource: onPickNextSource,
                                   canSwitchStreams: onPlayNext != nil,
                                   onChooseAnotherSource: onChooseAnotherSource)
            case .mpv:
                MPVPlayerScreen(context: context, upNext: upNext,
                                canSwitchStreams: onPlayNext != nil,
                                // The native engine's hand-over position, else a source switch's.
                                startPositionSec: fallbackStartSec.flatMap { $0 > 1 ? $0 : nil } ?? context.startPositionSec,
                                routingNote: forcedMPV ? String(localized: "mpv \u{00B7} fallback") : decision?.displayNote,
                                onExitToDetails: onExitToDetails,
                                onPickNextSource: onPickNextSource,
                                onChooseAnotherSource: onChooseAnotherSource,
                                // PLY-A9 (contract C1): a Dolby Vision Profile 5 file on mpv —
                                // routed there, or after a native fallback — renders with reshaping.
                                forceDVReshape: decision?.needsDVReshapeOnMPV ?? false)
            case .deciding:
                PlayerLoadingView()
            }
        }
        .environment(\.playerLoadingStartedAt, loadStartedAt)
        .onChange(of: context.id) {
            // Another episode or source in the same player: its own wait starts now.
            loadStartedAt = Date()
        }
        .task(id: context.id) { await decideEngine() }
        .onAppear {
            // Orchestrate Up Next only when a presenter can swap contexts (series autoplay,
            // source switching); the engine no-ops the rest for movies.
            if onPlayNext != nil { upNext.start() }
        }
        .onDisappear {
            // The end screen's full-screen cover also makes the player "disappear" — but the
            // engine is still in use under it (the next episode's source may be resolving for its
            // "Next Episode"): stop only on a real exit. The engine's own exits (details, a source
            // pick, a hand-off) release its search and observers, and `deinit` covers the rest.
            if upNext.endScreen == nil { upNext.stop() }
        }
    }

    /// Probe off-main (hard-bounded) and pick the engine. No-op straight to mpv when the flag is off.
    private func decideEngine() async {
        #if DEBUG
        let failures = PlayerEngineRouter.selfCheckFailures()
        if failures.isEmpty {
            print("[PlayerRouter] self-check passed")
        } else {
            failures.forEach { print("[PlayerRouter] \u{26A0}\u{FE0F} \($0)") }
        }
        #endif

        guard nativeDVEnabled else { return }

        let url = context.url
        let requestHeaders = context.requestHeaders
        let felToMpv = UserDefaults.standard.bool(forKey: PlayerTuning.dvP7FelMpvKey)
        let timeoutSec = PlayerTuning.probeTimeoutSec
        let result = await Task.detached(priority: .utility) {
            let probe = MediaProbe.probe(url: url, timeoutSec: timeoutSec, requestHeaders: requestHeaders)
            return PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv)
        }.value
        print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
        decision = result
    }
}
