import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

extension MPVTVPlayerViewController {
    // MARK: - Preferred audio language

    /// Read the player settings SYNCHRONOUSLY (the same pattern the native engine uses in
    /// `NativePlaybackCoordinator.resolveLanguagePlan`) and resolve the audio-language targets in
    /// priority order. The `playerSettingsWatcher` installed in `viewDidAppear` only starts AFTER
    /// `loadfile`, far too late to steer mpv's first track pick, so the preference has to be read
    /// here. Also seeds `playerSettings`, which closes the hole where `autoSelectPreferredTracks`
    /// used to bail out (without latching) on the first track walk because settings were still nil.
    func resolvePreferredAudioLanguages() -> [String] {
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else {
            return []
        }
        playerSettings = settings
        // The language picked for this title on an earlier episode goes first (LANG-09).
        return PlayerAudioLanguagePlan.audioTargets(settings: settings, context: context,
                                                    persisted: persistedTrackPreference)
    }

    /// Property-level re-apply of the audio-language preference, mirroring upstream's
    /// `MPVPlayerBridge.applyAudioLanguagePreferences`: set `alang`, write the current numeric `aid`
    /// straight back, then hand selection to `auto` so the core re-resolves it against the new
    /// `alang`. Called once, immediately before `loadfile`.
    ///
    /// The targets are resolved here (main) and the writes run in order on `eventQueue`, ahead of the
    /// `loadfile` queued after them: they are synchronous property calls, which never run on the main
    /// thread (see `PropSnapshot`).
    func applyAudioLanguagePreferences() {
        guard mpv != nil, !didUserSelectAudio else { return }
        if preferredAudioLanguages.isEmpty {
            preferredAudioLanguages = resolvePreferredAudioLanguages()
        }
        guard !preferredAudioLanguages.isEmpty else { return }
        let alang = PlayerAudioLanguagePlan.alangValue(targets: preferredAudioLanguages)
        didApplyAlang = true
        onCore { core in
            core.setMpvString("alang", alang)
            if let currentId = core.getString("aid"), Int(currentId) != nil {
                core.setMpvString("aid", currentId)
            }
            core.setMpvString("aid", "auto")
        }
    }

    /// Addon-declared stream headers (`context.requestHeaders`, already sanitized by the shared
    /// `sanitizePlaybackHeaders`) → mpv's `http-header-fields`, applied to every HTTP request this
    /// handle makes (media, HLS segments, addon subtitle side-loads — matching mobile). The
    /// serialization mirrors upstream `MPVPlayerBridge.applyRequestHeaders` exactly: sorted keys,
    /// `Key: Value` pairs comma-joined, `\` and `,` escaped in values, and an explicit "" clear
    /// when there are no headers so a header-free load can never inherit a previous stream's
    /// headers should this handle ever load more than one file. Called before `loadfile`.
    /// Credential-class header names (lowercased). When the stream carries any of these, mpv's
    /// GLOBAL `http-header-fields` would also send them to every `sub-add` URL — i.e. leak the
    /// media host's credentials to unrelated subtitle providers (Codex 2026-08-20 round 4, P1).
    /// `subAdd` never lets the core fetch a subtitle: every remote file comes down through
    /// `MPVSubtitleFetcher`, whose requests carry none of these headers.
    private static let credentialHeaderNames: Set<String> = ["authorization", "cookie", "proxy-authorization"]

    func applyRequestHeaders(_ headers: [String: String]) {
        guard mpv != nil else { return }
        streamHeadersCarryCredentials = headers.keys.contains {
            Self.credentialHeaderNames.contains($0.lowercased())
        }
        if headers.isEmpty {
            onCore { $0.setMpvString("http-header-fields", "") }
            return
        }

        let serialized = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ",", with: "\\,")
                return "\(key): \(escapedValue)"
            }
            .joined(separator: ",")
        onCore { $0.setMpvString("http-header-fields", serialized) }
    }

    // MARK: - Tracks

    nonisolated struct TrackInfo {
        let id: Int; let lang: String; let title: String; let forced: Bool; let selected: Bool
        /// Side-loaded (external) track: the URL it was added from. nil = embedded in the file.
        var sourceURL: String? = nil
        /// LANG-04 structured fields: mpv codec name ("eac3", "subrip"), its profile ("Dolby
        /// TrueHD + Dolby Atmos"), channel count (0 = unknown), and the file's flags.
        var codec: String = ""
        var codecProfile: String = ""
        var channels: Int = 0
        var isDefault: Bool = false
        var hearingImpaired: Bool = false
    }

    /// Republish the tracks as the last `track-list` event reported them (any thread). Selection
    /// changes need no re-read: the core's own `track-list` event follows them and republishes.
    func refreshTracksAsync() {
        DispatchQueue.main.async { [weak self] in self?.scheduleTrackPublish() }
    }

    /// Main thread. A `track-list` event arrived: it carries every audio and subtitle track whole, so
    /// the picker is built from it with no call into the core (it used to walk `track-list/N/...`
    /// one synchronous property at a time, which on a very large stream stalled for as long as the
    /// core stayed busy).
    func tracksChanged(_ entries: [MPVTrackListEntry]) {
        latestTrackEntries = entries
        scheduleTrackPublish()
    }

    /// Coalesced: a burst of track events settles into one publish.
    private func scheduleTrackPublish() {
        guard !trackRefreshPending else { return }
        trackRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.trackRefreshPending = false
            self.publishTracks()
        }
    }

    /// Main thread: one pass over the tracks building both the UI rows and the raw infos the
    /// auto-selection logic needs, then publishing them.
    private func publishTracks() {
        guard mpv != nil else { return }
        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = []
        var audioInfos: [TrackInfo] = []
        var subInfos: [TrackInfo] = []

        for entry in latestTrackEntries {
            // External (side-loaded) subtitles: the URL behind the file mpv reads — the local copy
            // of a credential-scoped download maps back to its addon URL.
            let sourceURL = entry.externalFilename.map { externalSubtitleSources[$0] ?? $0 }
            let info = TrackInfo(
                id: entry.id,
                lang: entry.lang,
                title: entry.title,
                forced: entry.forced,
                selected: entry.selected,
                sourceURL: sourceURL,
                codec: entry.codec,
                codecProfile: entry.codecProfile,
                channels: entry.channels,
                isDefault: entry.isDefault,
                hearingImpaired: entry.hearingImpaired
            )
            let label = Self.trackLabel(info, isAudio: entry.isAudio)
            if entry.isAudio {
                audio.append(PlayerTrack(id: info.id, label: label, isSelected: info.selected))
                audioInfos.append(info)
            } else {
                subs.append(PlayerTrack(id: info.id, label: label, isSelected: info.selected))
                subInfos.append(info)
            }
        }
        // The Off row leads; it shows as chosen while no subtitle track is.
        subs.insert(PlayerTrack(id: -1, label: String(localized: "Off"),
                                isSelected: !subInfos.contains { $0.selected }), at: 0)

        // A restored addon subtitle whose side-load has now landed (c9d6f5f63).
        if let pending = pendingSubtitleSelectURL,
           let info = subInfos.first(where: { $0.sourceURL == pending }) {
            pendingSubtitleSelectURL = nil
            postSubtitleSelection(String(info.id))
        }
        // An audio switch may have made mpv re-pick the subtitles: the viewer's choice goes back.
        if let keep = subtitleToKeep {
            if ProcessInfo.processInfo.systemUptime >= keep.expires {
                subtitleToKeep = nil
            } else {
                let showing = subInfos.first(where: { $0.selected }).map { String($0.id) } ?? "no"
                if showing != keep.sid { postSet("sid", keep.sid) }
            }
        }

        let newSubs = subs.count > 1 ? subs : []
        // LANG-04: the structured fields first, so the panel's rebuild on the row change below
        // already finds them.
        MPVTrackCatalog.catalog(for: state).publish(
            audio: audioInfos.map { Self.trackFields($0, isAudio: true, addon: nil) },
            subtitles: subInfos.map { info in
                Self.trackFields(info, isAudio: false,
                                 addon: info.sourceURL.flatMap { sideLoadedAddonSubtitles[$0] })
            }
        )
        // Don't rebuild the lists while the picker is open — reassigning them rebuilds the
        // SwiftUI list and snaps focus back to the top. Exception: the picker is showing its
        // empty state (first open raced the walk), where populating beats focus preservation.
        // The panel diffs its rows by stable ids, so refreshing while it is open is safe.
        if state.audioTracks != audio { state.audioTracks = audio }
        if state.subtitleTracks != newSubs { state.subtitleTracks = newSubs }
        lastSubtitleInfos = subInfos
        lastAudioInfos = audioInfos
        // VERIFIED-LANGUAGES: remember the file's own tracks for the stream it was picked from.
        PlayedTrackRecorder.record(
            url: context.url,
            audio: audioInfos.map { .init(language: $0.lang, title: $0.title, codec: $0.codec, channels: $0.channels) },
            subtitles: subInfos.filter { $0.sourceURL == nil }.map { .init(language: $0.lang, title: $0.title, forced: $0.forced) }
        )
        autoSelectPreferredTracks(audioInfos: audioInfos, subInfos: subInfos)
        // The subtitle half: a saved choice first, else the language plan. A saved addon choice
        // that waits for this episode's addon subtitles is retried on every walk.
        resolveSubtitleSelection(subInfos: subInfos)
    }

    /// The viewer's (or the plan's) subtitle choice, asynchronously: a track id, or "no". It settles
    /// whatever an earlier audio switch was holding back.
    func postSubtitleSelection(_ sid: String) {
        subtitleToKeep = nil
        postSet("sid", sid)
    }

    /// An audio switch can make mpv re-pick the subtitles for the new language, which would silently
    /// replace (or switch on) the viewer's choice. Remember what is showing: the next track
    /// publishes put it back unless something chooses explicitly first (`postSubtitleSelection`).
    private func keepSubtitleThroughAudioSwitch(_ subInfos: [TrackInfo]) {
        let showing = subInfos.first(where: { $0.selected }).map { String($0.id) } ?? "no"
        subtitleToKeep = (sid: showing, expires: ProcessInfo.processInfo.systemUptime + 2.5)
    }

    /// Once, on first load: reconcile the audio track against the user's preferred languages, then
    /// run the shared audio-aware subtitle auto-selection plan (upstream v0.3.0 parity).
    ///
    /// Audio is now a FALLBACK here: `alang` was already handed to mpv before init (see
    /// `setupMpv()`), so the core's own pick normally satisfies the preference and this pass does
    /// nothing. It only forces `aid` when mpv's selection does not match any target — e.g. a track
    /// whose language tag mpv reads differently than the shared matcher does.
    ///
    /// Subtitles: this pass only records the audio the plan depends on; `applySubtitlePlan` (via
    /// `resolveSubtitleSelection`) does the rest. With "Use forced subtitles" on and the audio in
    /// your language, only a FORCED track in that language is selected; otherwise non-forced tracks
    /// in the preferred languages, SDH first when closed captions are on (spec §8.1). No match →
    /// subtitles off once addon subtitles can no longer bring one. No plan (forced subtitles on but
    /// audio language undeterminable) → mpv's own defaults stay.
    private func autoSelectPreferredTracks(audioInfos: [TrackInfo], subInfos: [TrackInfo]) {
        // `playerSettings` is now seeded synchronously in `setupMpv()`, so this guard can no longer
        // return without latching on the first walk (which used to defer the whole selection to a
        // later track-list change, or to the panel being opened).
        guard !didAutoSelectTracks, let settings = playerSettings, mpv != nil else { return }
        guard !audioInfos.isEmpty || !subInfos.isEmpty else { return }
        didAutoSelectTracks = true

        // The language picked for this title on an earlier episode first (LANG-09), then the
        // settings' targets.
        let audioTargets = PlayerAudioLanguagePlan.audioTargets(settings: settings, context: context,
                                                                persisted: persistedTrackPreference)

        // Audio: only worth switching when there's more than one option, and only when mpv's own
        // pick misses. `alang` already steered that pick, so re-poking `aid` whenever a target
        // merely matches would switch the track after the first frame — exactly the audible switch
        // the proactive `alang` exists to eliminate. `trackToForce` returns nil when a matching
        // track is already selected. A saved choice for this title (LANG-09) is matched first by
        // the shared `findPersistedAudioTrackIndex`, which picks between same-language variants.
        var pickedAudioId: Int?
        if !didUserSelectAudio, audioInfos.count > 1 {
            let wanted = persistedAudioTrackId(audioInfos)
                ?? PlayerAudioLanguagePlan.trackToForce(
                    targets: audioTargets,
                    tracks: audioInfos.map { (id: $0.id, lang: $0.lang, title: $0.title, selected: $0.selected) }
                )
            if let id = wanted, audioInfos.first(where: { $0.id == id })?.selected != true {
                // The switch must not move the subtitle choice (mpv may re-run its own
                // forced-subtitle fallback on an audio change). The track-list event that follows
                // republishes, so the Audio menu's checkmark follows the forced track.
                keepSubtitleThroughAudioSwitch(subInfos)
                postSet("aid", String(id))
                pickedAudioId = id
            }
        }

        // The audio the viewer will actually hear: picked above, else mpv's selection, else first.
        let effectiveAudio = audioInfos.first { $0.id == pickedAudioId }
            ?? audioInfos.first { $0.selected }
            ?? audioInfos.first
        let effectiveAudioTrack: AudioTrack? = effectiveAudio.map { info in
            AudioTrack(
                index: 0,
                id: String(info.id),
                label: info.title.isEmpty ? info.lang : info.title,
                language: info.lang.isEmpty ? nil : info.lang,
                isSelected: true
            )
        }

        // The subtitle half runs from `resolveSubtitleSelection`: a saved choice first (c9d6f5f63),
        // else `applySubtitlePlan` — possibly later, once this episode's addon subtitles arrived.
        subtitlePlanAudio = effectiveAudioTrack
        subtitlePlanAudioTargets = audioTargets
    }

    private enum SubtitlePlanOutcome {
        /// A track was selected.
        case selected
        /// Nothing to select: subtitles were turned off (or the plan left mpv's defaults alone).
        case off
        /// No track matches yet, but this episode's addon subtitles may still bring one.
        case pending
    }

    /// The shared audio-aware subtitle plan (targets + forced/normal mode, with the tvOS defaults
    /// of spec §8.1) over `subInfos`. With `isFinal` false a plan whose targets match nothing yet
    /// returns `.pending` and changes nothing (LANG-01: addon subtitles arriving late are still
    /// auto-selected). With `isFinal` true, no match sets `sid=no` so a file's default-flagged track
    /// can't show when no preferred language matched (LANG-02).
    private func applySubtitlePlan(subInfos: [TrackInfo], isFinal: Bool) -> SubtitlePlanOutcome {
        guard let settings = playerSettings, mpv != nil else { return .off }
        let effectiveAudioTrack = subtitlePlanAudio
        guard let plan = PlayerAudioLanguagePlan.subtitlePlan(settings: settings, audio: effectiveAudioTrack,
                                                               audioTargets: subtitlePlanAudioTargets)
        else { return .off }   // forced subtitles wanted, audio language unknown: mpv decides

        let match: Int
        if plan.targets.isEmpty || subInfos.isEmpty {
            match = -1
        } else {
            let sharedSubs = subInfos.enumerated().map { index, info in
                SubtitleTrack(
                    index: Int32(index),
                    id: String(info.id),
                    // mpv's hearing-impaired flag reaches the shared SDH rule through the label.
                    label: (info.title.isEmpty ? info.lang : info.title) + (info.hearingImpaired ? " SDH" : ""),
                    language: info.lang.isEmpty ? nil : info.lang,
                    isSelected: info.selected,
                    isForced: info.forced
                )
            }
            match = Int(PlayerTrackSelectionKt.findPreferredSubtitleTrackIndexPreferringSdh(
                tracks: sharedSubs, targets: plan.targets, mode: plan.mode,
                selectedAudioTrack: effectiveAudioTrack,
                preferSdh: PlayerAudioLanguagePlan.closedCaptionsPreferred
            ))
        }
        if subInfos.indices.contains(match) {
            let sid = Int64(subInfos[match].id)
            // The track-list event that follows republishes, so the Subtitles menu's checkmark
            // follows the pick.
            postSubtitleSelection(String(sid))
            return .selected
        }
        // Targets to look for and addon subtitles still on their way: wait for them.
        if !plan.targets.isEmpty, !isFinal { return .pending }
        // Nothing matches (or nothing is wanted): subtitles off, whatever the file flags as default.
        postSubtitleSelection("no")
        return .off
    }

    // MARK: - Subtitle choice memory (upstream c9d6f5f63)
    //
    // The viewer's subtitle pick is saved per title (series-wide, profile-scoped, the shared
    // `PlayerTrackPreferenceStorage` mobile uses) and restored on the next episode — or the next
    // session — before the language plan runs: Off stays off, an embedded track is matched by
    // language / forced flag / name, and an addon subtitle by the saved file on the same episode,
    // else this episode's subtitle in the saved language from the saved provider.

    private enum SubtitleRestore { case restored, waiting, unmatched }

    /// Once per file: restore the saved choice, or run the language plan. A saved addon choice can
    /// wait (`.waiting`) for this episode's addon subtitles — retried on every track walk, when the
    /// fetch completes, and at `subtitleRestoreWaitSec` at the latest. Never before FILE_LOADED: a
    /// track walk can publish while the file is still opening, before `onFileLoaded` side-loads the
    /// prefetched addon list — a saved addon choice would find nothing and give up.
    func resolveSubtitleSelection(subInfos: [TrackInfo]) {
        guard didAutoSelectTracks, fileLoaded, !subtitleSelectionResolved, mpv != nil else { return }
        switch restorePersistedSubtitle(subInfos: subInfos) {
        case .restored:
            finishSubtitleSelection()
        case .waiting:
            armSubtitleRestoreDeadline()
        case .unmatched:
            // LANG-01: while this episode's addon subtitles are still being fetched (and the
            // deadline hasn't passed), a plan that matches nothing yet waits; every track walk —
            // including the one after the addon side-loads — tries again.
            // Addon subtitles already fetched but not yet in the track list count as on their way.
            let sideLoadsPending = latestAddonSubtitles.contains { sub in
                !subInfos.contains { $0.sourceURL == sub.url }
            }
            let mayStillArrive = !subtitleRestoreDeadlinePassed
                && (!addonSubtitleFetchFinished() || sideLoadsPending)
            switch applySubtitlePlan(subInfos: subInfos, isFinal: !mayStillArrive) {
            case .selected, .off:
                finishSubtitleSelection()
            case .pending:
                armSubtitleRestoreDeadline()
            }
        }
    }

    private func finishSubtitleSelection() {
        subtitleSelectionResolved = true
        subtitleRestoreDeadline?.cancel()
        subtitleRestoreDeadline = nil
    }

    private func restorePersistedSubtitle(subInfos: [TrackInfo]) -> SubtitleRestore {
        guard let preference = persistedTrackPreference else { return .unmatched }
        let type = preference.subtitleType
        if type == PersistedSubtitleSelectionType.shared.DISABLED {
            print("[MPV] subtitles: restored Off")
            postSubtitleSelection("no")
            return .restored
        }
        if type == PersistedSubtitleSelectionType.shared.INTERNAL {
            if let id = persistedInternalSubtitleId(preference, subInfos: subInfos) {
                print("[MPV] subtitles: restored track \(id) (\(preference.subtitleLanguage ?? "?"))")
                postSubtitleSelection(String(id))
                return .restored
            }
            // Stream-attached subtitle files are side-loaded after the first walk.
            let streamSubtitlesPending = !subtitleRestoreDeadlinePassed && context.externalSubtitles.contains { sub in
                !subInfos.contains { $0.sourceURL == sub.url }
            }
            return streamSubtitlesPending ? .waiting : .unmatched
        }
        if type == PersistedSubtitleSelectionType.shared.ADDON {
            let stillLoading = !subtitleRestoreDeadlinePassed && !addonSubtitleFetchFinished()
            guard let match = PlayerTrackSelectionKt.findPersistedAddonSubtitle(
                subtitles: latestAddonSubtitles, preference: preference
            ) else {
                return stillLoading ? .waiting : .unmatched
            }
            // Another provider's match waits while the saved provider may still answer.
            if stillLoading, !PlayerTrackSelectionKt.canRestorePersistedAddonSubtitleWhileLoading(
                subtitle: match, preference: preference
            ) {
                return .waiting
            }
            print("[MPV] subtitles: restored addon subtitle \(match.display) (\(match.language))")
            selectAddonSubtitle(match)
            return .restored
        }
        return .unmatched
    }

    /// An embedded (or stream-attached) track for a saved INTERNAL choice. The saved mpv track id
    /// counts only while it still names the saved language and forced flag (the same file); across
    /// episodes the shared matcher decides — language, forced flag, variant, then name.
    private func persistedInternalSubtitleId(_ preference: PersistedPlayerTrackPreference,
                                             subInfos: [TrackInfo]) -> Int? {
        let candidates = subInfos.filter { info in
            guard let url = info.sourceURL else { return true }
            return sideLoadedAddonSubtitles[url] == nil       // an addon file is another kind of choice
        }
        guard !candidates.isEmpty else { return nil }
        let language = preference.subtitleLanguage ?? ""
        let forced = preference.subtitleIsForced?.boolValue
        if let savedId = preference.subtitleTrackId.flatMap({ Int($0) }),
           let info = candidates.first(where: { $0.id == savedId }),
           language.isEmpty || PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: info.lang, targetLanguage: language),
           forced == nil || forced == info.forced {
            return info.id
        }
        let tracks = candidates.enumerated().map { index, info in
            SubtitleTrack(
                index: Int32(index),
                id: String(info.id),
                label: info.title.isEmpty ? info.lang : info.title,
                language: info.lang.isEmpty ? nil : info.lang,
                isSelected: info.selected,
                isForced: info.forced
            )
        }
        let match = Int(PlayerTrackSelectionKt.findPersistedSubtitleTrackIndex(
            tracks: tracks, preference: PlayerSubtitleMemory.withoutTrackId(preference)
        ))
        return candidates.indices.contains(match) ? candidates[match].id : nil
    }

    /// Select an addon subtitle, side-loading it first if needed; the track walk after the side-load
    /// lands picks it up (`pendingSubtitleSelectURL`).
    private func selectAddonSubtitle(_ subtitle: AddonSubtitle) {
        let url = subtitle.url
        if !addedSubtitleUrls.contains(url) {
            sideLoadedAddonSubtitles[url] = subtitle
            subAdd(url: url, title: subtitle.display, lang: subtitle.language, priority: 0)
        }
        pendingSubtitleSelectURL = url
        refreshTracksAsync()
    }

    private func addonSubtitleFetchFinished() -> Bool {
        (SubtitleRepository.shared.completedRequest.value_ as? String)
            == SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId)
    }

    private func armSubtitleRestoreDeadline() {
        guard subtitleRestoreDeadline == nil, !subtitleRestoreDeadlinePassed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.subtitleRestoreDeadline = nil
            self.subtitleRestoreDeadlinePassed = true
            self.resolveSubtitleSelection(subInfos: self.lastSubtitleInfos)
        }
        subtitleRestoreDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.subtitleRestoreWaitSec, execute: work)
    }

    /// The viewer picked a subtitle (the top panel): remember it for this title.
    private func persistSubtitleChoice(trackId id: Int) {
        let metaId = context.parentMetaId
        let current = persistedTrackPreference
        if id < 0 {
            persistedTrackPreference = PlayerSubtitleMemory.saveOff(parentMetaId: metaId, keeping: current)
        } else if let info = lastSubtitleInfos.first(where: { $0.id == id }) {
            if let url = info.sourceURL, let addon = sideLoadedAddonSubtitles[url] {
                persistedTrackPreference = PlayerSubtitleMemory.saveAddon(parentMetaId: metaId, subtitle: addon,
                                                                          keeping: current)
            } else {
                persistedTrackPreference = PlayerSubtitleMemory.saveInternal(
                    parentMetaId: metaId,
                    language: info.lang.isEmpty ? nil : info.lang,
                    name: info.title.isEmpty ? info.lang : info.title,
                    trackId: String(info.id),
                    forced: info.forced,
                    keeping: current
                )
            }
        }
    }

    /// Engine switch (the "Player Engine" menu, the error card's "Try Native Player"): write the
    /// live audio and subtitle selection to the title's track memory, the one both engines restore
    /// from when they open a file, so the native engine opens on the tracks playing now — whether
    /// the viewer picked them or the language plan did.
    func rememberTracksForEngineSwitch() {
        guard mpv != nil, fileLoaded else { return }
        if let selected = lastSubtitleInfos.first(where: { $0.selected }) {
            persistSubtitleChoice(trackId: selected.id)
        } else if subtitleSelectionResolved, !lastSubtitleInfos.isEmpty {
            persistSubtitleChoice(trackId: -1)
        }
        if lastAudioInfos.count > 1, let audio = lastAudioInfos.first(where: { $0.selected }) {
            persistedTrackPreference = PlayerSubtitleMemory.saveAudio(
                parentMetaId: context.parentMetaId,
                language: audio.lang.isEmpty
                    ? PlayerLanguagePreferencesKt.languageFromTrackText(text: audio.title)
                    : audio.lang,
                name: audio.title.isEmpty ? (audio.lang.isEmpty ? nil : audio.lang) : audio.title,
                trackId: String(audio.id),
                keeping: persistedTrackPreference
            )
        }
    }

    /// LANG-04: the walk's structured fields for one track (see `MPVTrackFields`).
    nonisolated static func trackFields(_ info: TrackInfo, isAudio: Bool, addon: AddonSubtitle?) -> MPVTrackFields {
        MPVTrackFields(
            id: info.id,
            isAudio: isAudio,
            language: info.lang,
            title: info.title,
            codec: info.codec,
            codecProfile: info.codecProfile,
            channels: info.channels,
            forced: info.forced,
            isDefault: info.isDefault,
            hearingImpaired: info.hearingImpaired,
            isAddon: addon != nil,
            addonName: addon?.addonName
        )
    }

    /// The plain row label ("Français · Dolby Digital+ 5.1", "Anglais · Forcés"), never the raw
    /// "fre (subrip)" it used to be.
    nonisolated static func trackLabel(_ info: TrackInfo, isAudio: Bool) -> String {
        trackFields(info, isAudio: isAudio, addon: nil).label
    }

    /// The audio track the title's saved choice names (LANG-09), or nil (none saved, or none fits).
    private func persistedAudioTrackId(_ audioInfos: [TrackInfo]) -> Int? {
        guard let preference = persistedTrackPreference,
              let language = preference.audioLanguage, !language.isEmpty
        else { return nil }
        let tracks = audioInfos.enumerated().map { index, info in
            AudioTrack(
                index: Int32(index),
                id: String(info.id),
                label: info.title.isEmpty ? info.lang : info.title,
                language: info.lang.isEmpty ? nil : info.lang,
                isSelected: info.selected
            )
        }
        let match = Int(PlayerTrackSelectionKt.findPersistedAudioTrackIndex(tracks: tracks, preference: preference))
        return audioInfos.indices.contains(match) ? audioInfos[match].id : nil
    }

    func selectAudio(_ id: Int) {
        didUserSelectAudio = true
        guard mpv != nil else { return }
        // In place, at the current position: `aid` is a live property, no reload. The viewer's
        // subtitle choice (a track, or Off) survives the switch.
        keepSubtitleThroughAudioSwitch(lastSubtitleInfos)
        postSet("aid", String(id))
        // LANG-09/STAB-05: remember the pick for this title. The track's language and title come
        // from the last publish (the track-list event carries both).
        if let picked = lastAudioInfos.first(where: { $0.id == id }) {
            persistedTrackPreference = PlayerSubtitleMemory.saveAudio(
                parentMetaId: context.parentMetaId,
                // No code on the track: what its title says ("Español", "VFQ"), if anything.
                language: picked.lang.isEmpty
                    ? PlayerLanguagePreferencesKt.languageFromTrackText(text: picked.title)
                    : picked.lang,
                name: picked.title.isEmpty ? (picked.lang.isEmpty ? nil : picked.lang) : picked.title,
                trackId: String(picked.id),
                keeping: persistedTrackPreference
            )
        }
        refreshTracksAsync()
    }

    /// Once the file is loaded: side-load stream-provided subtitles and kick off an addon subtitle fetch.
    func onFileLoaded() {
        guard !fileLoaded else { return }
        fileLoaded = true
        // Restore any subtitle delay saved for this exact video (per title/episode, per profile —
        // beta.15 §B2). `setSubtitleDelay` re-saves the same value, which is a harmless no-op.
        if let storedMs = PlayerTrackPreferenceStorage.shared.loadSubtitleDelayMs(videoId: context.videoId) {
            setSubtitleDelay(Double(storedMs.intValue) / 1000.0)
        }
        // The title's remembered speed (1x is never stored) and the chosen aspect ratio.
        if let storedSpeed = PlayerTrackPreferenceStorage.shared.loadPlaybackSpeed(contentId: context.parentMetaId)?.floatValue,
           storedSpeed > 0, abs(Double(storedSpeed) - 1) > 0.001 {
            setSpeed(Double(storedSpeed))
        }
        // Fit is mpv's own default: nothing to send, and no reason to touch the video output while it
        // is still setting up.
        if state.aspectMode != .fit {
            applyAspectMode(state.aspectMode)
        }
        // LANG-13: the audio delay is a property of this Apple TV's sound setup (soundbar, AV
        // receiver), so one value is kept per device and applied to every file.
        let storedAudioDelay = UserDefaults.standard.double(forKey: Self.audioDelayDefaultsKey)
        if storedAudioDelay != 0 {
            setAudioDelay(storedAudioDelay)
        }
        for sub in context.externalSubtitles {
            subAdd(url: sub.url, title: sub.name ?? sub.language, lang: sub.language, priority: 0)
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        // A stream-picker prefetch may already have completed (the fetch call above then no-ops,
        // and the flow watcher's replay fired before fileLoaded was set) — side-load what's there.
        // Key check: never side-load a lingering list that belongs to a different title.
        if (SubtitleRepository.shared.completedRequest.value_ as? String)
            == SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId),
           let prefetched = SubtitleRepository.shared.addonSubtitles.value_ as? [AddonSubtitle], !prefetched.isEmpty {
            addAddonSubtitles(prefetched)
        }
        // The Settings style plus the viewer's system caption overrides (spec §8.3).
        applySubtitleAppearance()
        applyDisplayCriteriaIfEnabled()
        fetchSkipSegments()
        // Started by the first refresh tick that knows the duration (PLY-6).
        traktStartPending = true
        // The subtitle choice, if a track publish already came through while the file was opening,
        // and one more publish now that the file is known.
        resolveSubtitleSelection(subInfos: lastSubtitleInfos)
        scheduleTrackPublish()
    }

    // MARK: - Subtitle appearance (mirrors the mobile libmpv mapping)

    /// Push the user's subtitle style into libmpv, through the `SubtitleRenderStyle` the native
    /// engine builds its `AVTextStyleRule` from (one mapping for both, so they cannot drift).
    /// Colors are `SubtitleColor` argb longs (0xAARRGGBB). `sub-ass-override=no` keeps styled ASS
    /// events as authored; the style applies to plain-text cues, which is what AVPlayer's
    /// text-style rule covers as well.
    func applySubtitleStyle() {
        guard mpv != nil, let state = playerSettings?.subtitleStyle else { return }
        let style = SubtitleRenderStyle(state)
        let stripSdh = state.stripSdh
        // A dozen property writes, posted asynchronously (never a call that waits on the core).
        postSet("sub-ass-override", "no")
        postSet("sub-color", SubtitleRenderStyle.mpvColor(style.textARGB))
        postSet("sub-back-color", SubtitleRenderStyle.mpvColor(style.backgroundARGB))
        postSet("sub-outline-color", SubtitleRenderStyle.mpvColor(style.outlineARGB))
        postSet("sub-border-color", SubtitleRenderStyle.mpvColor(style.outlineARGB))
        postSet("sub-border-style", style.mpvBorderStyle)
        postSet("sub-bold", style.bold ? "yes" : "no")
        postSet("sub-font-size", String(style.mpvFontSize))
        postSet("sub-outline-size", String(style.mpvOutlineSize))
        postSet("sub-border-size", String(style.mpvOutlineSize))
        postSet("sub-pos", String(style.mpvSubPos))
        postSet("sub-filter-sdh", stripSdh ? "yes" : "no")
        postSet("sub-filter-sdh-harder", stripSdh ? "yes" : "no")
    }

    #if DEBUG
    /// Sim-harness trace for the proactive `alang` audio preference (`debug.mpvAlangTrace`).
    func alangTrace(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "debug.mpvAlangTrace") else { return }
        print("[MPVAlang] \(message())")
    }
    #else
    func alangTrace(_ message: @autoclosure () -> String) {}
    #endif

    /// Blocking property write: `eventQueue` only, and only for the writes that must land in order
    /// before the load (`alang`, `aid`, `http-header-fields`). Everything else is posted.
    fileprivate func setMpvString(_ name: String, _ value: String) {
        guard let mpv else { return }
        checkError(MainThreadStallMonitor.shared.run("set \(name)") { mpv_set_property_string(mpv, name, value) })
    }

    /// Fetch intro/recap/outro segments for a series episode (no-op for movies / missing episode
    /// numbers). Works for anime out of the box (AniSkip/AnimeSkip); other content needs an
    /// `INTRO_DB_URL` configured. `requireSkipIntroEnabled: false` bypasses the mobile settings gate.
    private func fetchSkipSegments() {
        guard let season = context.season, let episode = context.episode else { return }
        SkipIntroRepository.shared.getSkipIntervalsForContentId(
            // Routes kitsu:/mal: anime ids to the anime providers; everything else keeps the
            // IMDB path. parentMetaId carries the prefix for addon-sourced anime.
            contentId: context.parentMetaId,
            season: Int32(season),
            episode: Int32(episode),
            // Respect the Settings > Playback "Skip Intro" toggle (skipIntroEnabled).
            requireSkipIntroEnabled: true
        ) { [weak self] intervals, _ in
            guard let intervals else { return }
            let segments = intervals.map { SkipSegment(start: $0.startTime, end: $0.endTime, type: $0.type) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.skipSegments = segments
                self.autoSkipTracker.reset()
                // The outro also times the Up Next card (credits-aware trigger).
                self.state.onSkipSegmentsLoaded?(segments)
            }
        }
    }

    func addAddonSubtitles(_ subs: [AddonSubtitle]) {
        guard fileLoaded else { return }
        // "Show only preferred languages": same shared filter the native path and the mobile
        // runtime apply, so the setting isn't engine-dependent.
        let kept = playerSettings.map {
            PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
        } ?? subs
        // The panel lists 24 add-on rows at most (`addonTotalCap`): the best matches are downloaded
        // first, the rest behind them, and a hard ceiling keeps a title with hundreds of files sane.
        let ranked = Array(rankedForSideLoad(kept).prefix(Self.sideLoadCeiling))
        latestAddonSubtitles = ranked
        var added = false
        for (index, sub) in ranked.enumerated() where !addedSubtitleUrls.contains(sub.url) {
            sideLoadedAddonSubtitles[sub.url] = sub
            subAdd(url: sub.url, title: sub.display, lang: sub.language,
                   priority: index < Self.sideLoadEagerCount ? 1 : 2)
            added = true
        }
        if added { refreshTracksAsync() }
    }

    /// Add-on subtitles downloaded ahead of the others, and the most that are side-loaded at all.
    private static let sideLoadEagerCount = 24
    private static let sideLoadCeiling = 48

    /// `subs` with the one the viewer saved for this title first, then the preferred subtitle
    /// languages in their order, then the rest, each group in arrival order.
    private func rankedForSideLoad(_ subs: [AddonSubtitle]) -> [AddonSubtitle] {
        var targets: [String] = []
        if let playerSettings {
            targets = PlayerTrackSelectionKt.preferredSubtitleTargetsForSettings(settings: playerSettings)
        }
        let saved: AddonSubtitle? = persistedTrackPreference.flatMap {
            PlayerTrackSelectionKt.findPersistedAddonSubtitle(subtitles: subs, preference: $0)
        }
        func rank(_ sub: AddonSubtitle) -> Int {
            if let saved, saved.url == sub.url { return -1 }
            return targets.firstIndex { PlayerTrackSelectionKt.addonSubtitleMatchesLanguage(subtitle: sub, target: $0) }
                ?? targets.count
        }
        return subs.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element), r = rank(rhs.element)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// Side-loads one subtitle. A remote file is downloaded by `URLSession` (`MPVSubtitleFetcher`),
    /// never by the core: `sub-add <http url>` probes the file inside libmpv, and forty of them in a
    /// row held the core, and with it the picture and every command, for 10 to 30 s after the file
    /// loaded. mpv is handed the local copy once it is down, which `sub-add` takes in milliseconds.
    /// The download carries none of the stream's headers, so their credentials never reach a
    /// subtitle host. `priority`: lower first (0 is a subtitle the viewer is waiting for).
    private func subAdd(url: String, title: String, lang: String, priority: Int = 1) {
        guard mpv != nil, !addedSubtitleUrls.contains(url) else { return }
        addedSubtitleUrls.insert(url)
        guard let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" else {
            addSubtitleFile(url, title: title, lang: lang)
            return
        }
        let generation = subtitleGeneration
        subtitleFetcher.enqueue(remote, priority: priority) { [weak self] local in
            DispatchQueue.main.async {
                guard let self, self.mpv != nil, self.subtitleGeneration == generation else { return }
                guard let local else {
                    NSLog("[MPVPlayer] subtitle download failed for %@ - skipping side-load", url)
                    self.subtitleDownloadFailed(url)
                    return
                }
                // The track publish maps the local copy back to the addon URL (subtitle memory).
                self.externalSubtitleSources[local.path] = url
                self.addSubtitleFile(local.path, title: title, lang: lang)
            }
        }
    }

    /// Main thread. A file that never came down is not waited for: the language plan and a saved
    /// choice go on without it instead of holding out to their deadline.
    private func subtitleDownloadFailed(_ url: String) {
        sideLoadedAddonSubtitles[url] = nil
        latestAddonSubtitles.removeAll { $0.url == url }
        if pendingSubtitleSelectURL == url { pendingSubtitleSelectURL = nil }
        resolveSubtitleSelection(subInfos: lastSubtitleInfos)
    }

    /// `sub-add`, reading the file in the legacy code page its language is written in when it is not
    /// UTF-8 (`SubtitleCharset.mpvCodepage`: a Russian SRT is Windows-1251, a Chinese one GBK…).
    /// `sub-add` opens and decodes the file before it returns, so the option only needs to hold for
    /// the call; mpv's own detection comes back after it. A language with no legacy code page of its
    /// own keeps that detection. The three requests are posted in order and the core takes them in
    /// that order.
    private func addSubtitleFile(_ path: String, title: String, lang: String) {
        guard let codepage = SubtitleCharset.mpvCodepage(forLanguage: lang) else {
            postCommand("sub-add", [path, "auto", title, lang])
            return
        }
        postSet("sub-codepage", codepage)
        postCommand("sub-add", [path, "auto", title, lang])
        postSet("sub-codepage", "auto")
    }

    func selectSubtitle(_ id: Int) {
        guard mpv != nil else { return }
        // The viewer's pick wins over a saved choice still waiting to be restored, and is saved for
        // the next episode (c9d6f5f63).
        finishSubtitleSelection()
        persistSubtitleChoice(trackId: id)
        pendingSubtitleSelectURL = nil
        postSubtitleSelection(id < 0 ? "no" : String(id))
        refreshTracksAsync()
    }

    // MARK: - Playback speed & A/V-subtitle timing

    /// Applies a speed picked in the transport bar and remembers it for this title (normal speed
    /// forgets it); `onFileLoaded()` replays it on the next playback of the title. The replay's
    /// own save is a same-value no-op.
    func setSpeed(_ speed: Double) {
        guard mpv != nil else { return }
        postSet("speed", double: speed)
        state.playbackSpeed = speed
        PlayerTrackPreferenceStorage.shared.savePlaybackSpeed(contentId: context.parentMetaId, speed: Float(speed))
    }

    // MARK: - Aspect ratio

    /// Aspect Ratio menu: applies the mode to the running core and remembers Fit / Fill.
    func setAspectMode(_ mode: PlayerAspectMode) {
        state.aspectMode = mode
        mode.remember()
        applyAspectMode(mode)
    }

    /// Fit, Fill and Stretch through mpv's own `panscan` and `keepaspect`: the Metal layer keeps
    /// filling the view, so the drawable size (and HDR output) is untouched.
    func applyAspectMode(_ mode: PlayerAspectMode) {
        guard mpv != nil else { return }
        // Both properties make the video output re-lay-out its picture, which waits on the render
        // thread. Never a call that waits, and never from the main thread: at file load (where this
        // used to run) that parked the main thread, so the whole screen froze while the film played on.
        postSet("panscan", double: mode.mpvPanscan)
        postSet("keepaspect", flag: mode.mpvKeepsAspect)
    }

    /// Runs `work` on `eventQueue`, the one place the core may be written to without parking the
    /// main thread on its lock (the BUG-2/BUG-3 rule above `PropSnapshot`).
    func onCore(_ work: @escaping (MPVTVPlayerViewController) -> Void) {
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            work(self)
        }
    }

    /// Single source of truth for subtitle re-timing on the mpv path: applies to the running core,
    /// updates the UI state, and persists per title/profile (beta.15 §B1/B2). Called both for user
    /// chip presses and for the persisted-value replay in `onFileLoaded()` — the redundant save on
    /// replay is a same-value no-op.
    func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        postSet("sub-delay", double: seconds)
        state.subtitleDelaySec = seconds
        let delayMs = Int32((seconds * 1000).rounded())
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId, delayMs: delayMs)
    }

    /// UserDefaults key of the per-device audio delay, in seconds (LANG-13).
    static let audioDelayDefaultsKey = "player.audioDelaySec"

    func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        postSet("audio-delay", double: seconds)
        state.audioDelaySec = seconds
        UserDefaults.standard.set(seconds, forKey: Self.audioDelayDefaultsKey)
    }

    // MARK: - Volume boost & dialogue boost

    /// Volume boost from the Audio menu: mpv's software volume (unity at 0 dB), remembered for the
    /// next playbacks. `eventQueue` like the other live changes to the audio chain.
    func setAudioGain(_ db: Int) {
        guard mpv != nil else { return }
        state.audioGainDb = db
        MPVAudioSettings(output: .current, gainDb: db, dialogueDb: state.dialogueBoostDb).storeBoosts()
        let percent = db > 0 ? MPVAudioSettings.volumePercent(gainDb: db) : 100
        postSet("volume", double: Double(percent))
    }

    /// Dialogue boost from the Audio menu: replaces mpv's audio filter with the centre-weighted
    /// stereo downmix (or clears it at 0), remembered for the next playbacks.
    func setDialogueBoost(_ db: Int) {
        guard mpv != nil else { return }
        state.dialogueBoostDb = db
        MPVAudioSettings(output: .current, gainDb: state.audioGainDb, dialogueDb: db).storeBoosts()
        let filter = MPVAudioSettings.audioFilter(dialogueDb: db,
                                                  stereoOutput: MPVAudioSettings.isStereoOutput(.current))
        postSet("af", filter)
    }
}
