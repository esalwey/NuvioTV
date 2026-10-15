import SharedCore
import SwiftUI

/// Engine dispatcher for all video playback in NuvioTV. Call sites present `PlayerScreen`; it probes
/// the stream and routes to the native AVPlayer path (`NativePlayerScreen` — the system player itself,
/// with true Dolby Vision, fed by the on-device remux or opening an HLS stream directly) or the libmpv
/// path (`MPVPlayerScreen` — for what AVPlayer cannot play), keeping the choice invisible to callers.
///
/// NATIVE FIRST: the native player is the only exact copy of the system player there is, so the router
/// (`PlayerEngineRouter`) sends it everything AVPlayer can play. The native path is gated by
/// `PlayerTuning.nativeDVKey` (Settings > Playback > Dolby Vision > Off turns it off for good, straight
/// to mpv with no probe delay) and steered by Settings > Playback > Advanced > Player
/// (`PlayerEnginePreference`: Automatic, Prefer Native, Prefer mpv). A brief probe decides per file
/// (none for an `.m3u8` URL, which AVPlayer opens itself), and any native-path failure falls back to mpv
/// for the same context. See docs/player-spec.md, "Engine routing".
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
    /// The Jellyfin / Emby session behind this context (inert for any other source): reports the
    /// playback to the server, offers its audio / burned-in subtitle tracks and its transcode
    /// fallback, the same on both engines.
    @StateObject private var server: ServerPlaybackLink
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
        _server = StateObject(wrappedValue: ServerPlaybackLink(context: context, switchContext: onPlayNext))
    }

    /// The engine routing note (the manual override's, else the router's) with how the server is
    /// delivering the file ("Direct play", "Transcoding · Audio codec not supported") appended, for
    /// the Stream Info.
    private var engineNote: String? {
        let note = [engineOverride?.note ?? decision?.displayNote, server.summary].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
        return note.isEmpty ? nil : note
    }

    private var nativeDVEnabled: Bool { UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey) }

    /// Player: Prefer mpv, with a Dolby Vision setting that never sends Dolby Vision to the native
    /// player: there is nothing left to find out about the file, so no probe either.
    private var mpvWithoutProbe: Bool {
        PlayerEnginePreference.current == .preferMpv && !DolbyVisionMode.current.playsDolbyVision
    }

    private enum Shown { case deciding, native, mpv }
    private var shown: Shown {
        if let engineOverride { return engineOverride.engine == .native ? .native : .mpv }
        // Native engine off, or Prefer mpv with nothing to probe for → mpv immediately, no probe wait.
        guard nativeDVEnabled, !mpvWithoutProbe else { return .mpv }
        guard let decision else { return .deciding }
        return decision.engine == .native ? .native : .mpv
    }

    /// How the native engine plays this stream: the router's decision, except that a playlist URL is
    /// always opened by AVPlayer itself (a manual switch to native for a stream the router had sent to
    /// mpv still has no file for the remux to read).
    private var nativePlan: NativePlaybackPlan {
        let decided = decision?.engine == .native ? decision : nil
        return NativePlaybackPlan(
            delivery: PlayerEngineRouter.isHLSURL(context.url) ? .directHLS : (decided?.delivery ?? .remux),
            dolbyVision: decided?.dvHandling ?? .passthrough)
    }

    var body: some View {
        Group {
            switch shown {
            case .native:
                NativePlayerScreen(context: nativeContext, upNext: upNext,
                                   onFallback: { position in
                                       // The one automatic hand-back, also after a manual switch to
                                       // native that could not play: mpv, for good (no loop).
                                       // A native engine that never got to play (the remux failed
                                       // before readyToPlay) reports 0: keep the hand-over position
                                       // an engine switch gave it instead of overwriting it.
                                       if position > 1 { fallbackStartSec = position }
                                       engineOverride = .fallback
                                       nativePossible = false
                                   },
                                   routingNote: engineNote,
                                   plan: nativePlan,
                                   onExitToDetails: onExitToDetails,
                                   onPickNextSource: onPickNextSource,
                                   canSwitchStreams: onPlayNext != nil,
                                   onChooseAnotherSource: onChooseAnotherSource,
                                   engineSwitch: engineSwitch,
                                   serverLink: server)
            case .mpv:
                MPVPlayerScreen(context: context, upNext: upNext,
                                canSwitchStreams: onPlayNext != nil,
                                // The native engine's hand-over position, else a source switch's.
                                startPositionSec: fallbackStartSec.flatMap { $0 > 1 ? $0 : nil } ?? context.startPositionSec,
                                routingNote: engineNote,
                                onExitToDetails: onExitToDetails,
                                onPickNextSource: onPickNextSource,
                                onChooseAnotherSource: onChooseAnotherSource,
                                // PLY-A9 (contract C1): a Dolby Vision Profile 5 file on mpv —
                                // routed there, or after a native fallback — renders with reshaping.
                                forceDVReshape: decision?.needsDVReshapeOnMPV ?? false,
                                engineSwitch: engineSwitch,
                                serverLink: server)
            case .deciding:
                PlayerLoadingView()
            }
        }
        .overlay(alignment: .top) {
            if let notice = server.notice {
                ServerNoticeBanner(text: notice)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: server.notice)
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
                // The server gets its stop report with the last position reached.
                server.stop()
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

    /// Probe off-main (hard-bounded) and pick the engine. No-op straight to mpv when the flag is off,
    /// and when Prefer mpv leaves nothing to probe for.
    private func decideEngine() async {
        #if DEBUG
        let failures = PlayerEngineRouter.selfCheckFailures()
        if failures.isEmpty {
            print("[PlayerRouter] self-check passed")
        } else {
            failures.forEach { print("[PlayerRouter] \u{26A0}\u{FE0F} \($0)") }
        }
        #endif

        guard nativeDVEnabled, !mpvWithoutProbe else { return }

        let url = context.url
        let requestHeaders = context.requestHeaders
        let dvMode = DolbyVisionMode.current
        let felToMpv = dvMode.sendsP7FelToMpv
        let stripDV = dvMode.stripsDolbyVision
        let options = RoutingOptions(enginePreference: PlayerEnginePreference.current,
                                     hardwareAV1: DeviceVideoCapabilities.decodesAV1InHardware)

        // A playlist URL (.m3u8: an addon's playlist, a Jellyfin / Emby transcode, a live channel) is
        // opened by AVPlayer itself, so there is nothing for a probe to add. A stream AVPlayer then
        // rejects falls back to mpv (NativePlaybackCoordinator).
        if PlayerEngineRouter.isHLSURL(url) {
            let result = PlayerEngineRouter.routeHLS(nativeDVEnabled: true, options: options)
            print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
            decision = result
            if nativePossible != false { nativePossible = true }
            return
        }

        let timeoutSec = PlayerTuning.probeTimeoutSec
        let retryTimeoutSec = PlayerTuning.probeRetryTimeoutSec
        // `.userInitiated`: the viewer is staring at the loading view while this runs.
        let (probed, routed, nativeCanPlay) = await Task.detached(priority: .userInitiated) {
            () -> (ProbeResult?, EngineDecision, Bool) in
            // A source that is slow to open gets a second, longer try before it is given up on.
            let probe = MediaProbe.probeWithRetry(url: url, timeoutSec: timeoutSec,
                                                  retryTimeoutSec: retryTimeoutSec, requestHeaders: requestHeaders)
            let decision = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv,
                                                    stripDolbyVision: stripDV, options: options)
            // Could the native engine play it at all, the viewer's routing preferences aside (the Player
            // choice, Dolby Vision as HDR10, Profile 7 FEL on mpv)? A probe that found nothing proves
            // nothing.
            return (probe, decision, PlayerEngineRouter.nativeCouldPlay(probe: probe, options: options))
        }.value
        // The detached probe runs to its deadline whatever happens here: a viewer who left meanwhile
        // (the `.task` was cancelled) gets no decision for a stream no longer asked for.
        guard !Task.isCancelled else { return }

        var result = routed
        // Automatic routing keeps a file on mpv when the native player would leave the viewer without
        // subtitles they would otherwise have (bitmap tracks only, in their language).
        if result.engine == .native, result.delivery == .remux, options.enginePreference == .automatic,
           let probed, let reason = await bitmapSubtitleGapReason(probe: probed) {
            guard !Task.isCancelled else { return }
            var moved = EngineDecision(engine: .mpv, reason: reason)
            moved.dvProfile = result.dvProfile
            result = moved
        }
        guard !Task.isCancelled else { return }
        print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
        decision = result
        // A native failure on this stream (set by the fallback) stays final.
        if nativePossible != false { nativePossible = nativeCanPlay }
    }

    // MARK: - Subtitles the native player could not show

    /// How long the router waits for the addon subtitle search before it judges a file's subtitles.
    private static let addonSubtitleWaitSec: TimeInterval = 3

    /// The native player shows the file's text subtitles and the addons' files, never images (PGS, VobSub,
    /// DVB): a Blu-ray remux whose only subtitles in the viewer's language are PGS would play there with
    /// none. When that is the case for this file and no addon file in that language came back (the search is
    /// awaited, `addonSubtitleWaitSec` at most), the file plays on mpv, which draws the images. Nil: the
    /// native player shows what the viewer would have.
    ///
    /// Only for what the language plan would switch on at the start: not when subtitles are off, when the plan
    /// is forced-only (the audio is already in the viewer's language), or when the viewer turned them off for
    /// this title. A media server's own subtitles are the server's business.
    private func bitmapSubtitleGapReason(probe: ProbeResult) async -> String? {
        guard probe.subtitles.contains(where: { $0.isBitmap }) else { return nil }
        guard !ServerStreams.shared.isServerSourceId(addonId: context.providerAddonId) else { return nil }
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else { return nil }
        let persisted = PlayerSubtitleMemory.load(parentMetaId: context.parentMetaId)
        if persisted?.subtitleType == PersistedSubtitleSelectionType.shared.DISABLED { return nil }

        // The audio the viewer will hear, picked the way the remux picks it.
        let audioTargets = PlayerAudioLanguagePlan.audioTargets(settings: settings, context: context, persisted: persisted)
        let audioTracks = probe.audio.enumerated().map { offset, audio in
            AudioTrack(index: Int32(offset), id: String(audio.index), label: audio.language ?? "",
                       language: audio.language, isSelected: false)
        }
        var heard: AudioTrack?
        if !audioTracks.isEmpty {
            let picked = Int(PlayerTrackSelectionKt.resolveInitialAudioTrackIndex(
                tracks: audioTracks, targets: audioTargets,
                savedLanguage: persisted?.audioLanguage, savedName: persisted?.audioName,
                savedTrackId: persisted?.audioTrackId))
            heard = audioTracks.indices.contains(picked) ? audioTracks[picked] : audioTracks[0]
        }
        guard let plan = PlayerAudioLanguagePlan.subtitlePlan(settings: settings, audio: heard, audioTargets: audioTargets),
              plan.mode != .forcedOnly, !plan.targets.isEmpty else { return nil }

        func inViewerLanguage(_ language: String?) -> Bool {
            guard let language, !language.isEmpty else { return false }
            return plan.targets.contains {
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: language, targetLanguage: $0)
            }
        }
        // Text tracks of the file, and files the stream came with, show on the native player.
        if probe.subtitles.contains(where: { !$0.isBitmap && inViewerLanguage($0.language) }) { return nil }
        if context.externalSubtitles.contains(where: { inViewerLanguage($0.language) }) { return nil }
        // Nothing lost if the file has no image track in the viewer's language either.
        guard probe.subtitles.contains(where: { $0.isBitmap && inViewerLanguage($0.language) }) else { return nil }

        // The addon search: started now (the native player would start it as it opens), awaited briefly.
        let key = SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId)
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        let deadline = Date().addingTimeInterval(Self.addonSubtitleWaitSec)
        while (SubtitleRepository.shared.completedRequest.value_ as? String) != key, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard !Task.isCancelled else { return nil }
        if (SubtitleRepository.shared.completedRequest.value_ as? String) == key,
           let addon = SubtitleRepository.shared.addonSubtitles.value_ as? [AddonSubtitle],
           addon.contains(where: { inViewerLanguage($0.language) }) {
            return nil
        }
        return "bitmap subtitles only in your language"
    }
}
