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
    /// These are synchronous property calls on the main thread, which the BUG-2/BUG-3 rule
    /// documented above `refreshTracksAsync()` otherwise forbids. They are safe HERE and only here:
    /// nothing is loaded yet, so the core lock is uncontended and cannot stall. Do not move any
    /// synchronous mpv property access onto the main thread once playback has started.
    func applyAudioLanguagePreferences() {
        guard mpv != nil, !didUserSelectAudio else { return }
        if preferredAudioLanguages.isEmpty {
            preferredAudioLanguages = resolvePreferredAudioLanguages()
        }
        guard !preferredAudioLanguages.isEmpty else { return }
        setMpvString("alang", PlayerAudioLanguagePlan.alangValue(targets: preferredAudioLanguages))
        if let currentId = getString("aid"), Int(currentId) != nil {
            setMpvString("aid", currentId)
        }
        setMpvString("aid", "auto")
        didApplyAlang = true
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
    /// `subAdd` checks this flag and side-loads such subtitles through its own credential-free
    /// download instead of letting the core fetch them.
    private static let credentialHeaderNames: Set<String> = ["authorization", "cookie", "proxy-authorization"]

    func applyRequestHeaders(_ headers: [String: String]) {
        guard mpv != nil else { return }
        streamHeadersCarryCredentials = headers.keys.contains {
            Self.credentialHeaderNames.contains($0.lowercased())
        }
        if headers.isEmpty {
            setMpvString("http-header-fields", "")
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
        setMpvString("http-header-fields", serialized)
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

    /// Schedule a track-list walk on `eventQueue`. The walk is dozens of synchronous property
    /// reads — cheap at steady state but seconds-slow while the core is starting up, so it must
    /// never run on the main thread (beta BUG-3: swipe-up menu slow to appear early in playback).
    /// Coalesced: a burst of track events settles into one walk.
    func refreshTracksAsync() {
        eventQueue.async { [weak self] in
            guard let self, !self.trackRefreshPending, self.mpv != nil else { return }
            self.trackRefreshPending = true
            self.eventQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.trackRefreshPending = false
                self.walkAndPublishTracks()
            }
        }
    }

    /// Runs on `eventQueue`: one pass over track-list building both the UI rows and the raw
    /// infos the auto-selection logic needs, then publishes on main.
    private func walkAndPublishTracks() {
        guard mpv != nil else { return }
        let count = getInt("track-list/count")
        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = [PlayerTrack(id: -1, label: String(localized: "Off"), isSelected: getString("sid") == "no")]
        var audioInfos: [TrackInfo] = []
        var subInfos: [TrackInfo] = []

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            guard type == "audio" || type == "sub" else { continue }
            let id = getInt("track-list/\(i)/id")
            let selected = getFlag("track-list/\(i)/selected")
            // External (side-loaded) subtitles: the URL behind the file mpv reads — the local copy
            // of a credential-scoped download maps back to its addon URL.
            let sourceURL: String? = type == "sub" && getFlag("track-list/\(i)/external")
                ? getString("track-list/\(i)/external-filename").map { externalSubtitleSources[$0] ?? $0 }
                : nil
            let info = TrackInfo(
                id: id,
                lang: (getString("track-list/\(i)/lang") ?? "").trimmingCharacters(in: .whitespaces),
                title: (getString("track-list/\(i)/title") ?? "").trimmingCharacters(in: .whitespaces),
                forced: getFlag("track-list/\(i)/forced"),
                selected: selected,
                sourceURL: sourceURL,
                codec: (getString("track-list/\(i)/codec") ?? "").trimmingCharacters(in: .whitespaces),
                codecProfile: getString("track-list/\(i)/codec-profile") ?? "",
                channels: type == "audio" ? getInt("track-list/\(i)/demux-channel-count") : 0,
                isDefault: getFlag("track-list/\(i)/default"),
                hearingImpaired: type == "sub" && getFlag("track-list/\(i)/hearing-impaired")
            )
            let label = Self.trackLabel(info, isAudio: type == "audio")
            if type == "audio" {
                audio.append(PlayerTrack(id: id, label: label, isSelected: selected))
                audioInfos.append(info)
            } else {
                subs.append(PlayerTrack(id: id, label: label, isSelected: selected))
                subInfos.append(info)
            }
        }

        // A restored addon subtitle whose side-load has now landed (c9d6f5f63).
        if let pending = pendingSubtitleSelectURL,
           let info = subInfos.first(where: { $0.sourceURL == pending }) {
            pendingSubtitleSelectURL = nil
            setMpvInt("sid", Int64(info.id))
            refreshTracksAsync()        // publish the new selection
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let newSubs = subs.count > 1 ? subs : []
            // LANG-04: the structured fields first, so the panel's rebuild on the row change below
            // already finds them.
            MPVTrackCatalog.catalog(for: self.state).publish(
                audio: audioInfos.map { Self.trackFields($0, isAudio: true, addon: nil) },
                subtitles: subInfos.map { info in
                    Self.trackFields(info, isAudio: false,
                                     addon: info.sourceURL.flatMap { self.sideLoadedAddonSubtitles[$0] })
                }
            )
            // Don't rebuild the lists while the picker is open — reassigning them rebuilds the
            // SwiftUI list and snaps focus back to the top. Exception: the picker is showing its
            // empty state (first open raced the walk), where populating beats focus preservation.
            // The panel diffs its rows by stable ids, so refreshing while it is open is safe.
            if self.state.audioTracks != audio { self.state.audioTracks = audio }
            if self.state.subtitleTracks != newSubs { self.state.subtitleTracks = newSubs }
            self.lastSubtitleInfos = subInfos
            // VERIFIED-LANGUAGES: remember the file's own tracks for the stream it was picked from.
            PlayedTrackRecorder.record(
                url: self.context.url,
                audio: audioInfos.map { .init(language: $0.lang, title: $0.title, codec: $0.codec, channels: $0.channels) },
                subtitles: subInfos.filter { $0.sourceURL == nil }.map { .init(language: $0.lang, title: $0.title, forced: $0.forced) }
            )
            self.autoSelectPreferredTracks(audioInfos: audioInfos, subInfos: subInfos)
            // The subtitle half: a saved choice first, else the language plan. A saved addon choice
            // that waits for this episode's addon subtitles is retried on every walk.
            self.resolveSubtitleSelection(subInfos: subInfos)
        }
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
                eventQueue.async { [weak self] in
                    guard let self else { return }
                    // The switch must not move the subtitle choice (mpv may re-run its own
                    // forced-subtitle fallback on an audio change).
                    let sidBefore = self.getString("sid")
                    self.setMpvInt("aid", Int64(id))
                    self.keepSubtitle(sidBefore)
                    // Republish so the Audio menu's checkmark follows the forced track.
                    self.refreshTracksAsync()
                }
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
            // Republish after the pick so the Subtitles menu's checkmark follows it (the walk only
            // re-runs on track-count changes otherwise).
            eventQueue.async { [weak self] in self?.setMpvInt("sid", sid); self?.refreshTracksAsync() }
            return .selected
        }
        // Targets to look for and addon subtitles still on their way: wait for them.
        if !plan.targets.isEmpty, !isFinal { return .pending }
        // Nothing matches (or nothing is wanted): subtitles off, whatever the file flags as default.
        eventQueue.async { [weak self] in self?.setMpvString("sid", "no"); self?.refreshTracksAsync() }
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
            eventQueue.async { [weak self] in self?.setMpvString("sid", "no") }
            refreshTracksAsync()
            return .restored
        }
        if type == PersistedSubtitleSelectionType.shared.INTERNAL {
            if let id = persistedInternalSubtitleId(preference, subInfos: subInfos) {
                print("[MPV] subtitles: restored track \(id) (\(preference.subtitleLanguage ?? "?"))")
                eventQueue.async { [weak self] in self?.setMpvInt("sid", Int64(id)) }
                refreshTracksAsync()
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
            subAdd(url: url, title: subtitle.display, lang: subtitle.language)
        }
        eventQueue.async { [weak self] in self?.pendingSubtitleSelectURL = url }
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
        let metaId = context.parentMetaId
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            // In place, at the current position: `aid` is a live property, no reload. The viewer's
            // subtitle choice (a track, or Off) survives the switch.
            let sidBefore = self.getString("sid")
            var v = Int64(id)
            mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &v)
            self.keepSubtitle(sidBefore)
            // LANG-09/STAB-05: remember the pick for this title. Read the track off the handle
            // here, on the event queue (the walk's audio rows carry no language).
            let picked = self.audioTrackInfo(id: id)
            DispatchQueue.main.async { [weak self] in
                guard let self, let picked else { return }
                self.persistedTrackPreference = PlayerSubtitleMemory.saveAudio(
                    parentMetaId: metaId,
                    // No code on the track: what its title says ("Español", "VFQ"), if anything.
                    language: picked.lang.isEmpty
                        ? PlayerLanguagePreferencesKt.languageFromTrackText(text: picked.title)
                        : picked.lang,
                    name: picked.title.isEmpty ? (picked.lang.isEmpty ? nil : picked.lang) : picked.title,
                    trackId: String(picked.id),
                    keeping: self.persistedTrackPreference
                )
            }
        }
        refreshTracksAsync()
    }

    /// `eventQueue` only: put the subtitle selection back to `sid` ("no", or a track id) if an audio
    /// switch moved it — mpv's forced-subtitle fallback can re-pick subtitles for the new audio
    /// language, which would silently replace (or switch on) the viewer's choice.
    private func keepSubtitle(_ sid: String?) {
        guard let sid, mpv != nil, getString("sid") != sid else { return }
        if let id = Int64(sid) {
            setMpvInt("sid", id)
        } else {
            setMpvString("sid", sid)
        }
    }

    /// `eventQueue` only: language and title of the audio track `id`, from the live track list.
    private func audioTrackInfo(id: Int) -> (id: Int, lang: String, title: String)? {
        guard mpv != nil else { return nil }
        let count = getInt("track-list/count")
        for i in 0..<count where getString("track-list/\(i)/type") == "audio" && getInt("track-list/\(i)/id") == id {
            return (id: id,
                    lang: (getString("track-list/\(i)/lang") ?? "").trimmingCharacters(in: .whitespaces),
                    title: (getString("track-list/\(i)/title") ?? "").trimmingCharacters(in: .whitespaces))
        }
        return nil
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
        // LANG-13: the audio delay is a property of this Apple TV's sound setup (soundbar, AV
        // receiver), so one value is kept per device and applied to every file.
        let storedAudioDelay = UserDefaults.standard.double(forKey: Self.audioDelayDefaultsKey)
        if storedAudioDelay != 0 {
            setAudioDelay(storedAudioDelay)
        }
        for sub in context.externalSubtitles {
            subAdd(url: sub.url, title: sub.name ?? sub.language, lang: sub.language)
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
        // The subtitle choice, if a track walk already came through while the file was opening.
        resolveSubtitleSelection(subInfos: lastSubtitleInfos)
    }

    // MARK: - Subtitle appearance (mirrors the mobile libmpv mapping)

    /// Push the user's subtitle style into libmpv. Colors are `SubtitleColor` argb longs (0xAARRGGBB);
    /// the size/outline/border-style formulas match `PlayerEngine.android`'s `applySubtitleStyle`.
    func applySubtitleStyle() {
        guard mpv != nil, let style = playerSettings?.subtitleStyle else { return }
        setMpvString("sub-ass-override", "no")
        setMpvString("sub-color", mpvColorString(style.textColor))
        setMpvString("sub-back-color", mpvColorString(style.backgroundColor))
        setMpvString("sub-outline-color", mpvColorString(style.outlineColor))
        setMpvString("sub-border-color", mpvColorString(style.outlineColor))
        setMpvString("sub-border-style", subtitleBorderStyle(style))
        setMpvString("sub-bold", style.bold ? "yes" : "no")
        setMpvInt("sub-font-size", subtitleFontSize(style))
        let outline = subtitleOutlineSize(style)
        setMpvInt("sub-outline-size", outline)
        setMpvInt("sub-border-size", outline)
        setMpvInt("sub-pos", Int64(max(0, min(100, 100 - Int(style.bottomOffset) / 10))))
        setMpvString("sub-filter-sdh", style.stripSdh ? "yes" : "no")
        setMpvString("sub-filter-sdh-harder", style.stripSdh ? "yes" : "no")
    }

    private func mpvColorString(_ argb: Int64) -> String {
        let a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }

    private func subtitleFontSize(_ s: SubtitleStyleState) -> Int64 {
        let scaled = Int(Double(s.fontSizeSp) * (55.0 / 18.0))
        return Int64(max(36, min(122, scaled)))
    }

    private func subtitleOutlineSize(_ s: SubtitleStyleState) -> Int64 {
        guard s.outlineEnabled else { return 0 }
        return Int64(max(1, Int(Double(s.outlineWidth) * 1.5)))
    }

    private func subtitleBorderStyle(_ s: SubtitleStyleState) -> String {
        if s.outlineEnabled { return "outline-and-shadow" }
        let backgroundAlpha = (s.backgroundColor >> 24) & 0xFF
        return backgroundAlpha > 0 ? "opaque-box" : "outline-and-shadow"
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

    private func setMpvString(_ name: String, _ value: String) {
        guard let mpv else { return }
        checkError(mpv_set_property_string(mpv, name, value))
    }

    private func setMpvInt(_ name: String, _ value: Int64) {
        guard let mpv else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &v)
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
        latestAddonSubtitles = kept
        var added = false
        for sub in kept where !addedSubtitleUrls.contains(sub.url) {
            sideLoadedAddonSubtitles[sub.url] = sub
            subAdd(url: sub.url, title: sub.display, lang: sub.language)
            added = true
        }
        if added { refreshTracksAsync() }
    }

    private func subAdd(url: String, title: String, lang: String) {
        guard mpv != nil, !addedSubtitleUrls.contains(url) else { return }
        addedSubtitleUrls.insert(url)
        // Credential leak guard (Codex round 4, P1): with credential-class stream headers set
        // globally on this handle, an in-core `sub-add <http url>` would send them to the
        // subtitle host. Download the file ourselves WITHOUT those headers and hand mpv a local
        // path instead. Only this rare credential case takes the new path — header-free and
        // benign-header (Referer/UA) streams keep the exact in-core behavior below.
        if streamHeadersCarryCredentials,
           let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" {
            URLSession.shared.dataTask(with: remote) { [weak self] data, _, error in
                guard let self, let data, error == nil, !data.isEmpty else {
                    NSLog("[MPVPlayer] credential-scoped subtitle fetch failed for %@ — skipping side-load", url)
                    return
                }
                let ext = remote.pathExtension.isEmpty ? "srt" : remote.pathExtension
                let local = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mpv-sub-\(UUID().uuidString).\(ext)")
                do {
                    try data.write(to: local)
                } catch {
                    NSLog("[MPVPlayer] credential-scoped subtitle write failed — skipping side-load")
                    return
                }
                self.eventQueue.async { [weak self] in
                    // The track walk maps the local copy back to the addon URL (subtitle memory).
                    self?.externalSubtitleSources[local.path] = url
                    self?.command("sub-add", args: [local.path, "auto", title, lang])
                }
            }.resume()
            return
        }
        // sub-add downloads/probes the file synchronously inside the core — never on main.
        eventQueue.async { [weak self] in
            self?.command("sub-add", args: [url, "auto", title, lang])
        }
    }

    func selectSubtitle(_ id: Int) {
        guard mpv != nil else { return }
        // The viewer's pick wins over a saved choice still waiting to be restored, and is saved for
        // the next episode (c9d6f5f63).
        finishSubtitleSelection()
        persistSubtitleChoice(trackId: id)
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            self.pendingSubtitleSelectURL = nil
            if id < 0 {
                self.checkError(mpv_set_property_string(mpv, "sid", "no"))
            } else {
                var v = Int64(id)
                mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &v)
            }
        }
        refreshTracksAsync()
    }

    // MARK: - Playback speed & A/V-subtitle timing

    func setSpeed(_ speed: Double) {
        guard mpv != nil else { return }
        setMpvDouble("speed", speed)
        state.playbackSpeed = speed
    }

    /// Single source of truth for subtitle re-timing on the mpv path: applies to the running core,
    /// updates the UI state, and persists per title/profile (beta.15 §B1/B2). Called both for user
    /// chip presses and for the persisted-value replay in `onFileLoaded()` — the redundant save on
    /// replay is a same-value no-op.
    func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("sub-delay", seconds)
        state.subtitleDelaySec = seconds
        let delayMs = Int32((seconds * 1000).rounded())
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId, delayMs: delayMs)
    }

    /// UserDefaults key of the per-device audio delay, in seconds (LANG-13).
    static let audioDelayDefaultsKey = "player.audioDelaySec"

    func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        setMpvDouble("audio-delay", seconds)
        state.audioDelaySec = seconds
        UserDefaults.standard.set(seconds, forKey: Self.audioDelayDefaultsKey)
    }

    private func setMpvDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }
}
