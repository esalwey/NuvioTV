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
///
/// The viewer can also switch engines by hand ("Player Engine" in the transport bar, "Try Native
/// Player" on the error card — `PlayerEngineSwitch`). That override beats the router for the rest of
/// this stream, resumes at the same position with the same audio and subtitle tracks, and is never
/// undone automatically: only a failing native engine hands back to mpv, once.
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
    /// The engine pinned for this stream instead of the router's pick: mpv after a native failure,
    /// or the engine the viewer asked for. Cleared when the stream changes.
    @State private var engineOverride: PlayerEngineOverride?
    /// Where the engine being left was when it handed over (a native failure, a manual switch).
    @State private var fallbackStartSec: Double?
    /// The native engine could take this stream, preferences aside: the probe did not rule it out.
    /// nil = not probed (the native engine is off in Settings, or the probe came back empty), which
    /// leaves the manual switch available. false once the native path failed on this stream.
    @State private var nativePossible: Bool?
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
        if let engineOverride { return engineOverride.engine == .native ? .native : .mpv }
        guard nativeDVEnabled else { return .mpv }       // flag off → mpv immediately, no probe wait
        guard let decision else { return .deciding }
        return decision.engine == .native ? .native : .mpv
    }

    var body: some View {
        Group {
            switch shown {
            case .native:
                NativePlayerScreen(context: nativeContext, upNext: upNext,
                                   onFallback: { position in
                                       // The one automatic hand-back, also after a manual switch to
                                       // native that could not play: mpv, for good (no loop).
                                       fallbackStartSec = position
                                       engineOverride = .fallback
                                       nativePossible = false
                                   },
                                   routingNote: engineOverride?.note ?? decision?.displayNote,
                                   onExitToDetails: onExitToDetails,
                                   onPickNextSource: onPickNextSource,
                                   canSwitchStreams: onPlayNext != nil,
                                   onChooseAnotherSource: onChooseAnotherSource,
                                   engineSwitch: engineSwitch)
            case .mpv:
                MPVPlayerScreen(context: context, upNext: upNext,
                                canSwitchStreams: onPlayNext != nil,
                                // The native engine's hand-over position, else a source switch's.
                                startPositionSec: fallbackStartSec.flatMap { $0 > 1 ? $0 : nil } ?? context.startPositionSec,
                                routingNote: engineOverride?.note ?? decision?.displayNote,
                                onExitToDetails: onExitToDetails,
                                onPickNextSource: onPickNextSource,
                                onChooseAnotherSource: onChooseAnotherSource,
                                // PLY-A9 (contract C1): a Dolby Vision Profile 5 file on mpv —
                                // routed there, or after a native fallback — renders with reshaping.
                                forceDVReshape: decision?.needsDVReshapeOnMPV ?? false,
                                engineSwitch: engineSwitch)
            case .deciding:
                PlayerLoadingView()
            }
        }
        .environment(\.playerLoadingStartedAt, loadStartedAt)
        .onChange(of: context.id) {
            // Another episode or source in the same player: its own wait starts now, and the
            // engine override of the last stream does not follow it.
            loadStartedAt = Date()
            engineOverride = nil
            fallbackStartSec = nil
            nativePossible = nil
            // The launch resume prompt follows what is playing now.
            ResumePromptRepository.shared.markPlayerEntered(videoId: context.videoId)
        }
        .task(id: context.id) { await decideEngine() }
        .onAppear {
            // Orchestrate Up Next only when a presenter can swap contexts (series autoplay,
            // source switching); the engine no-ops the rest for movies.
            if onPlayNext != nil { upNext.start() }
            // Resume Prompt on Launch: the marker stays set until the player is left normally, so
            // a launch that follows the app being closed mid-playback can offer to resume. Here,
            // above both engines, so mpv and the native player behave the same.
            ResumePromptRepository.shared.markPlayerEntered(videoId: context.videoId)
        }
        .onDisappear {
            // The end screen's full-screen cover also makes the player "disappear" — but the
            // engine is still in use under it (the next episode's source may be resolving for its
            // "Next Episode"): stop only on a real exit. The engine's own exits (details, a source
            // pick, a hand-off) release its search and observers, and `deinit` covers the rest.
            if upNext.endScreen == nil {
                upNext.stop()
                ResumePromptRepository.shared.markPlayerExitedNormally()
            }
        }
    }

    /// What the player screens offer for switching engines by hand.
    private var engineSwitch: PlayerEngineSwitch {
        PlayerEngineSwitch(
            current: shown == .native ? .native : .mpv,
            nativeAvailable: nativePossible ?? true,
            perform: { target, position in switchEngine(to: target, at: position) })
    }

    /// The viewer asked for `target` from the player: it replaces the router's pick for this stream
    /// and takes over at `position`. The engine being left has already written its audio and
    /// subtitle selection to the title's track memory.
    private func switchEngine(to target: PlaybackEngine, at position: Double) {
        fallbackStartSec = position > 1 ? position : nil
        engineOverride = .manual(target)
    }

    /// The context the native engine plays: a hand-over position (a manual switch from mpv) is its
    /// explicit start, which also wins over a Start Over request.
    private var nativeContext: PlaybackContext {
        guard let start = fallbackStartSec, start > 1 else { return context }
        var copy = context
        copy.startPositionSec = start
        copy.resumeFromStart = false
        return copy
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
        let dvMode = DolbyVisionMode.current
        let felToMpv = dvMode.sendsP7FelToMpv
        let stripDV = dvMode.stripsDolbyVision
        let timeoutSec = PlayerTuning.probeTimeoutSec
        // `.userInitiated`: the viewer is staring at the loading view while this runs.
        let (result, nativeCanPlay) = await Task.detached(priority: .userInitiated) { () -> (EngineDecision, Bool) in
            let probe = MediaProbe.probe(url: url, timeoutSec: timeoutSec, requestHeaders: requestHeaders)
            let decision = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv,
                                                    stripDolbyVision: stripDV)
            // Could the native engine play it at all, the viewer's routing preferences aside (Dolby
            // Vision as HDR10, Profile 7 FEL on mpv)? A probe that found nothing proves nothing.
            let possible = probe == nil || PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true).engine == .native
            return (decision, possible)
        }.value
        // The detached probe runs to its deadline whatever happens here: a viewer who left meanwhile
        // (the `.task` was cancelled) gets no decision for a stream no longer asked for.
        guard !Task.isCancelled else { return }
        print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
        decision = result
        // A native failure on this stream (set by the fallback) stays final.
        if nativePossible != false { nativePossible = nativeCanPlay }
    }
}
