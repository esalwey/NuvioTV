import AVFoundation
import Combine
import Foundation
import SharedCore

extension NativePlaybackCoordinator {
    /// Resolve the language plan from the shared player settings (same helpers + semantics as the
    /// mpv screen's `autoSelectPreferredTracks`). Called at start (audio unknown) and again once
    /// the remux has picked the audio track, because the forced-only decision depends on it.
    func resolveLanguagePlan(selectedAudioTrack: AudioTrack?) {
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else { return }
        playerSettings = settings
        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        // The same targets as the mpv engine (`PlayerAudioLanguagePlan.audioTargets`): the audio
        // picked for this show on an earlier episode/session first, WITH its variant (LANG-09/10:
        // a VFQ pick is "fr-ca", not just French), then the stream's own audio hint, then the
        // settings (the title's original language for "Original"). The remux starts on the match
        // and AVPlayer's audible criteria prefer it.
        let audioTargets = PlayerAudioLanguagePlan.audioTargets(settings: settings, context: context,
                                                                persisted: persistedTrackPreference)
        let subTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: settings.secondaryPreferredSubtitleLanguage,
            deviceLanguages: deviceLanguages
        )
        var plan = LanguagePlan()
        plan.audioTargets = audioTargets
        plan.subtitleFilterLanguages = subTargets
        plan.onlyPreferredLanguages = settings.subtitleStyle.showOnlyPreferredLanguages
        // Always consult the shared plan, with the tvOS defaults the mpv engine applies (spec
        // §8.1): the "Forced" subtitle option, forced subtitles when the audio is in the device's
        // language, always-on subtitles with system closed captions. Even with no subtitle targets
        // it can yield a forced-only plan in the audio's language (mpv parity).
        if let shared = PlayerAudioLanguagePlan.subtitlePlan(settings: settings, audio: selectedAudioTrack,
                                                              audioTargets: audioTargets) {
            plan.subtitleTargets = shared.targets
            plan.forcedOnly = shared.mode == .forcedOnly
            plan.subtitlesOff = shared.targets.isEmpty   // nothing to auto-select → never auto-enable
        } else {
            // Forced on but audio language unknown: leave player defaults untouched (mpv parity).
            plan.leaveToPlayer = true
            plan.subtitleTargets = subTargets
        }
        // Subtitles turned off on an earlier episode stay off (c9d6f5f63): nothing auto-enables.
        if persistedTrackPreference?.subtitleType == PersistedSubtitleSelectionType.shared.DISABLED {
            plan.subtitlesOff = true
            plan.leaveToPlayer = false
        }
        if plan != languagePlan {
            languagePlan = plan
            print("[NativePlayer] language plan: audio=\(plan.audioTargets) subs=\(plan.subtitlesOff ? "off" : plan.subtitleTargets.description)"
                  + (plan.forcedOnly ? " forced-only" : "") + (plan.leaveToPlayer ? " player-default" : "")
                  + (plan.onlyPreferredLanguages ? " only-preferred" : ""))
        }
    }

    /// Install the plan on a player: AVPlayer applies these when the item's selection groups load
    /// (and again after an audio-switch rebuild). Empty preferred languages fall back to the
    /// system's own behaviour, so "subtitles off" is additionally enforced by the master's
    /// AUTOSELECT=NO flags (see `subtitleAutoselect`).
    func applyLanguagePlan(to player: AVPlayer) {
        let plan = languagePlan
        // Applied once per item, at setup: re-applying after a MANUAL audio/subtitle pick would let
        // AVPlayer snap back to the preferences.
        if !plan.audioTargets.isEmpty {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(preferredLanguages: plan.audioTargets, preferredMediaCharacteristics: nil),
                forMediaCharacteristic: .audible)
        }
        if plan.subtitlesOff || plan.leaveToPlayer {
            player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .legible)
        } else {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(
                    preferredLanguages: plan.subtitleTargets,
                    preferredMediaCharacteristics: plan.forcedOnly ? [.containsOnlyForcedSubtitles] : nil),
                forMediaCharacteristic: .legible)
        }
    }

    /// AUTOSELECT/DEFAULT decision for one subtitle rendition (master playlist flags).
    /// - subtitles off → nothing auto-selectable, so neither the system's accessibility prefs nor
    ///   AVPlayer's defaults can switch captions on;
    /// - otherwise renditions in a preferred language are AUTOSELECT=YES and the first match is
    ///   DEFAULT=YES (mpv parity: preferred subtitles start on), the rest AUTOSELECT=NO.
    func subtitleFlags(for renditions: [SubtitleRendition]) -> [SubtitleRenditionFlags] {
        let plan = languagePlan
        // DEFAULT goes to the rendition the shared subtitle rule picks (the mpv engine's rule):
        // the target's variant (VFF vs VFQ), forced vs full per the plan, SDH only with system
        // closed captions. None when the plan deferred to player defaults or matches nothing.
        let defaultIndex = plannedDefaultSubtitleIndex(in: renditions)
        return renditions.enumerated().map { index, rendition in
            // FORCED renditions are always auto-selectable: HLS requires AUTOSELECT=YES with
            // FORCED=YES (an invalid master is an admission failure), and forced tracks — foreign
            // dialogue / signs — are meant to show per the player's own rules even when the viewer
            // has no subtitle language preference (standard forced-subtitle behaviour). Never DEFAULT
            // outside a forced-only plan.
            guard !plan.subtitlesOff else { return SubtitleRenditionFlags(autoselect: rendition.forced, isDefault: false) }
            // Deferred to player defaults: every rendition stays auto-selectable, none is DEFAULT.
            guard !plan.leaveToPlayer else { return .legacy }
            let matches = plan.subtitleTargets.contains { target in
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: rendition.language ?? "", targetLanguage: target)
            }
            // Forced-only plan: only a FORCED rendition in the target language may start on
            // (embedded tracks carry the flag; addon files never do). Normal plan: only FULL
            // renditions — a forced (signs/foreign-dialogue-only) track must not win DEFAULT just
            // because it's listed first. Both enforced by the shared rule.
            let isDefault = index == defaultIndex
            // Forced renditions stay auto-selectable (the player applies them per its own rules)
            // whenever subtitles aren't off outright.
            return SubtitleRenditionFlags(autoselect: matches || rendition.forced || isDefault, isDefault: isDefault)
        }
    }

    /// The rendition the language plan starts on, as an index into `renditions` (the master's
    /// order), or nil: subtitles off, deferred to the player, or nothing matches. The shared
    /// `findPreferredSubtitleTrackIndexPreferringSdh`, exactly as the mpv engine applies it.
    func plannedDefaultSubtitleIndex(in renditions: [SubtitleRendition]) -> Int? {
        let plan = languagePlan
        guard !plan.subtitlesOff, !plan.leaveToPlayer, !plan.subtitleTargets.isEmpty, !renditions.isEmpty
        else { return nil }
        let tracks = renditions.enumerated().map { index, rendition in
            SubtitleTrack(
                index: Int32(index),
                id: String(rendition.index),
                // The SDH flag reaches the shared rule through the label, as on mpv.
                label: rendition.name + (rendition.hearingImpaired ? " SDH" : ""),
                language: rendition.language,
                isSelected: false,
                isForced: rendition.forced
            )
        }
        let mode: SubtitleAutoSelectionMode = plan.forcedOnly ? .forcedOnly : .normalOnly
        let picked = Int(PlayerTrackSelectionKt.findPreferredSubtitleTrackIndexPreferringSdh(
            tracks: tracks, targets: plan.subtitleTargets, mode: mode,
            selectedAudioTrack: planAudioTrack(),
            preferSdh: PlayerAudioLanguagePlan.closedCaptionsPreferred
        ))
        return renditions.indices.contains(picked) ? picked : nil
    }

    /// The audio the remux produces — the one the subtitle plan was resolved against.
    private func planAudioTrack() -> AudioTrack? {
        guard let track = remux?.audioTracks.first(where: \.selected) else { return nil }
        return AudioTrack(index: 0, id: String(track.streamIndex),
                          label: track.title ?? track.language ?? "",
                          language: track.language, isSelected: true)
    }

    /// No saved choice applied: select the plan's rendition explicitly, so the item starts on the
    /// same track the master marks DEFAULT (AVPlayer's own criteria cannot tell two "fr"
    /// renditions, or a plain and an SDH one, apart). Never turns subtitles off: forced renditions
    /// keep showing per the player's rules when nothing is planned.
    private func applyPlannedSubtitleDefault(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        let renditions = subtitleRenditionsByName.values.sorted { $0.index < $1.index }
        guard let index = plannedDefaultSubtitleIndex(in: renditions) else { return }
        let name = renditions[index].name
        guard let option = group.options.first(where: { option in
            let optionName = Self.renditionName(of: option)
            return Self.subtitleSlot(ofName: optionName) == 0 && Self.canonicalSubtitleName(optionName) == name
        }) else { return }
        guard item.currentMediaSelection.selectedMediaOption(in: group) != option else { return }
        item.select(option, in: group)
        selectionVersion &+= 1
        print("[NativePlayer] subtitles: planned ‘\(name)’")
    }

    /// True once the repo has completed the fetch for THIS content (deduplicated prefetches
    /// included). Read on the poll cadence; sticky via `subsFetchDone`.
    func subsFetchCompleted() -> Bool {
        if subsFetchDone { return true }
        if (SubtitleRepository.shared.completedRequest.value_ as? String) == subsRequestKey {
            subsFetchDone = true
            print("[NativePlayer] addon subtitle fetch finished (\(addonSubtitles.count) found)")
            return true
        }
        return false
    }

    /// The remux worker's initial audio pick (`RemuxSession.Config.preferredAudioPicker`), or nil
    /// when there is nothing to steer it by. Captures plain values only: it runs on the worker.
    func preferredAudioPicker() -> (@Sendable ([RemuxAudioTrack]) -> Int?)? {
        let targets = languagePlan.audioTargets
        let savedLanguage = persistedTrackPreference?.audioLanguage
        let savedName = persistedTrackPreference?.audioName
        let savedTrackId = persistedTrackPreference?.audioTrackId
        guard !targets.isEmpty || !(savedLanguage ?? "").isEmpty else { return nil }
        return { tracks in
            Self.preferredAudioStream(in: tracks, targets: targets, savedLanguage: savedLanguage,
                                      savedName: savedName, savedTrackId: savedTrackId)
        }
    }

    /// The playable track to start on: the show's saved choice when this file has it (matched by
    /// variant, then name — LANG-09/10: VFQ stays VFQ on the next episode even if the France dub
    /// now has its old track number), else the first target with a match, its exact variant first
    /// (the same shared rule as `PlayerAudioLanguagePlan.trackToForce` on mpv). Pure — runs on
    /// the remux worker.
    nonisolated static func preferredAudioStream(in tracks: [RemuxAudioTrack], targets: [String],
                                                 savedLanguage: String?, savedName: String?,
                                                 savedTrackId: String?) -> Int? {
        let playable = tracks.filter(\.playable)
        guard !playable.isEmpty else { return nil }
        let shared = playable.enumerated().map { index, track in
            AudioTrack(index: Int32(index), id: String(track.streamIndex), label: audioMemoryName(track),
                       language: track.language, isSelected: false)
        }
        let picked = Int(PlayerTrackSelectionKt.resolveInitialAudioTrackIndex(
            tracks: shared, targets: targets,
            savedLanguage: savedLanguage, savedName: savedName, savedTrackId: savedTrackId))
        return playable.indices.contains(picked) ? playable[picked].streamIndex : nil
    }

    /// The name an audio choice is remembered by, and matched by on the next file: the container
    /// title ("VFQ", "Commentary"), else the raw language code — the mpv engine's convention, so
    /// a choice saved on one engine is found on the other.
    nonisolated static func audioMemoryName(_ track: RemuxAudioTrack) -> String {
        let title = track.title?.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? (track.language ?? "") : title
    }

    /// Follow AVPlayer's audible selection (system Audio tab): remember the selected track for the
    /// server (only its rendition-file requests may switch the worker) and kick the worker's switch
    /// proactively. The subtitle selection is deliberately left alone — like the mpv screen (which
    /// auto-selects once) and the old rebuild path (which restored the previous choice), an audio
    /// switch must not override an explicit subtitle pick or Off.
    func observeMediaSelection(item: AVPlayerItem, player: AVPlayer) {
        if let old = mediaSelectionObserver { NotificationCenter.default.removeObserver(old) }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaSelectionChange(item: item, player: player) }
        }
    }

    func handleMediaSelectionChange(item: AVPlayerItem, player: AVPlayer) {
        guard playerItem === item else { return }
        selectionVersion &+= 1
        rememberSubtitleChoiceIfChanged(item: item)
        if audibleGroup == nil {
            Task { @MainActor [weak self] in
                let group = (try? await item.asset.loadMediaSelectionGroup(for: .audible)) ?? nil
                guard let self, self.playerItem === item, let group else { return }
                self.audibleGroup = group
                self.syncAudioSelection(item: item, player: player)
            }
        } else {
            syncAudioSelection(item: item, player: player)
        }
    }

    /// Compare AVPlayer's audible selection with what we last relayed; on a change, relay it to the
    /// server/worker. Cheap — called on every tick and on the media-selection notification.
    func syncAudioSelection(item: AVPlayerItem, player: AVPlayer) {
        guard let group = audibleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let stream = Self.renditionStream(for: option, byName: audioRenditionsByName,
                                                tracks: remux?.audioTracks ?? []) else { return }
        // The first relay of an item is AVPlayer's own initial pick (criteria / DEFAULT), not the
        // viewer's: never remembered.
        defer { didRelayInitialAudio = true }
        guard selectedAudioBox.value != stream else { return }
        selectedAudioBox.value = stream
        print("[NativePlayer] audio selection → stream \(stream) (\(option.displayName))")
        remux?.selectAudio(streamIndex: stream, atSegment: nil)
        // A later change came from the system Audio popover (panel picks save in `select(audio:)`):
        // remember it for the show (LANG-09 / STAB-05).
        if didRelayInitialAudio, subtitleChoiceTrackingArmed, lastSavedAudioStream != stream {
            rememberAudioChoice(option: option, stream: stream)
        }
    }

    /// Save the viewer's audio pick for the show (contract C4), keeping the subtitle half.
    func rememberAudioChoice(option: AVMediaSelectionOption, stream: Int?) {
        let track = stream.flatMap { s in remux?.audioTracks.first { $0.streamIndex == s } }
        let rawLanguage = track?.language ?? option.extendedLanguageTag
        let language = TrackLabelFormatter.normalizedTag(rawLanguage) ?? rawLanguage
        // The container title ("VFQ") — what the next file's tracks are matched by — else the
        // menu label, whose release tag still tells the variant.
        let memoryName = track.map(Self.audioMemoryName) ?? ""
        let name = memoryName.isEmpty ? Self.renditionName(of: option) : memoryName
        persistedTrackPreference = PlayerSubtitleMemory.saveAudio(
            parentMetaId: context.parentMetaId,
            language: language,
            name: name,
            trackId: stream.map { String($0) },
            keeping: persistedTrackPreference
        )
        lastSavedAudioStream = stream
        print("[NativePlayer] audio choice remembered: \(language ?? "?") (\(name))")
    }

    /// Map an audible option back to our track. `displayName` is AVFoundation's LOCALIZED language
    /// ("French"), not the rendition NAME — the NAME is the option's common-metadata title. Fall back
    /// to the language tag when it identifies exactly one playable track.
    private static func renditionStream(for option: AVMediaSelectionOption, byName: [String: Int],
                                        tracks: [RemuxAudioTrack]) -> Int? {
        let title = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                 filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
        if let title, let stream = byName[title] { return stream }
        if let stream = byName[option.displayName] { return stream }
        if let tag = option.extendedLanguageTag {
            let matches = tracks.filter { $0.playable && $0.language.map {
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: $0, targetLanguage: tag) } == true }
            if matches.count == 1 { return matches[0].streamIndex }
        }
        return nil
    }

    /// Cache the item's legible media-selection group (Info tab's "Subtitles" row).
    func loadLegibleSelection(item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            let group = (try? await item.asset.loadMediaSelectionGroup(for: .legible)) ?? nil
            guard let self, self.playerItem === item else { return }
            self.legibleGroup = group
            self.selectionVersion &+= 1
            if let group { self.applyPersistedSubtitleChoice(item: item, group: group) }
        }
    }

    // MARK: - Subtitle choice memory (upstream c9d6f5f63)

    /// Restore the saved subtitle choice on this item (once per item) — an explicit selection, which
    /// AVPlayer honours over its criteria — then start remembering the viewer's own changes.
    private func applyPersistedSubtitleChoice(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        guard subtitleRestoreItem !== item else { return }
        subtitleRestoreItem = item
        var restored = false
        if let preference = persistedTrackPreference {
            if preference.subtitleType == PersistedSubtitleSelectionType.shared.DISABLED {
                item.select(nil, in: group)
                selectionVersion &+= 1
                restored = true
                print("[NativePlayer] subtitles: restored Off")
            } else if let rendition = persistedSubtitleRendition(preference),
                      let option = group.options.first(where: { option in
                          let name = Self.renditionName(of: option)
                          return Self.subtitleSlot(ofName: name) == 0 && Self.canonicalSubtitleName(name) == rendition.name
                      }) {
                item.select(option, in: group)
                selectionVersion &+= 1
                restored = true
                print("[NativePlayer] subtitles: restored ‘\(rendition.name)’")
            }
        }
        // No saved choice (or none that fits this file): the language plan's pick (mpv parity).
        if !restored { applyPlannedSubtitleDefault(item: item, group: group) }
        armSubtitleChoiceTracking(item: item, group: group)
    }

    /// The rendition a saved INTERNAL or ADDON choice maps to in this master, if any.
    private func persistedSubtitleRendition(_ preference: PersistedPlayerTrackPreference) -> SubtitleRendition? {
        let renditions = subtitleRenditionsByName.values.sorted { $0.index < $1.index }
        if preference.subtitleType == PersistedSubtitleSelectionType.shared.ADDON {
            guard let match = PlayerTrackSelectionKt.findPersistedAddonSubtitle(
                subtitles: masterAddonSubtitles, preference: preference
            ) else { return nil }
            let key = Self.subtitleURLKey(match.url)
            return renditions.first { $0.sourceURL?.absoluteString == key }
        }
        guard preference.subtitleType == PersistedSubtitleSelectionType.shared.INTERNAL else { return nil }
        // The file's own tracks and the stream's attached files — not the addon ones.
        let candidates = renditions.filter { rendition in
            guard let url = rendition.sourceURL else { return true }
            return masterAddonSubtitlesByURL[url.absoluteString] == nil
        }
        let tracks = candidates.enumerated().map { index, rendition in
            SubtitleTrack(
                index: Int32(index),
                id: String(rendition.index),
                label: rendition.name,
                language: rendition.language,
                isSelected: false,
                isForced: rendition.forced
            )
        }
        let match = Int(PlayerTrackSelectionKt.findPersistedSubtitleTrackIndex(
            tracks: tracks, preference: PlayerSubtitleMemory.withoutTrackId(preference)
        ))
        return candidates.indices.contains(match) ? candidates[match] : nil
    }

    /// After the initial selection settled (AVPlayer's automatic pick, then the restore), a legible
    /// change is the viewer's — the panel, or the system Subtitles menu.
    private func armSubtitleChoiceTracking(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        subtitleChoiceTrackTask?.cancel()
        subtitleChoiceTrackingArmed = false
        subtitleChoiceTrackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.playerItem === item else { return }
            self.lastSubtitleChoiceName = Self.subtitleChoiceName(item.currentMediaSelection.selectedMediaOption(in: group))
            self.lastAudioChoiceName = self.currentAudioChoiceName(item: item)
            self.subtitleChoiceTrackingArmed = true
        }
    }

    /// Media-selection change: remember a new subtitle choice — not the delay re-fetch's Off hop.
    /// AVPlayer re-picking subtitles for audio the viewer just switched to (its criteria bring in
    /// forced subtitles for the new language, or drop the current ones) is undone instead: an
    /// audio switch never changes the subtitle choice, Off included. The re-pick can arrive in the
    /// same notification as the audio change or in the next one, hence the short window.
    private func rememberSubtitleChoiceIfChanged(item: AVPlayerItem) {
        guard subtitleChoiceTrackingArmed, !isRefetchingSubtitles, let group = legibleGroup else { return }
        let option = item.currentMediaSelection.selectedMediaOption(in: group)
        let name = Self.subtitleChoiceName(option)
        let audioName = currentAudioChoiceName(item: item)
        if audioName != lastAudioChoiceName {
            lastAudioChoiceName = audioName
            lastAudioSwitchAt = Date()
        }
        guard name != lastSubtitleChoiceName else { return }
        if let switchedAt = lastAudioSwitchAt, Date().timeIntervalSince(switchedAt) < Self.audioSwitchSubtitleGuardSec,
           let wanted = lastSubtitleChoiceName {
            restoreSubtitleChoice(named: wanted, item: item, group: group)
            return
        }
        lastSubtitleChoiceName = name
        persistSubtitleChoice(option: option)
    }

    /// How long after an audio switch a subtitle change counts as AVPlayer's, not the viewer's.
    private static let audioSwitchSubtitleGuardSec: TimeInterval = 2

    /// Put the subtitle selection back to the viewer's choice ("" = Off) after AVPlayer moved it.
    private func restoreSubtitleChoice(named wanted: String, item: AVPlayerItem, group: AVMediaSelectionGroup) {
        let target: AVMediaSelectionOption?
        if wanted.isEmpty {
            target = nil
        } else if let option = group.options.first(where: { option in
            let name = Self.renditionName(of: option)
            return Self.subtitleSlot(ofName: name) == 0 && Self.canonicalSubtitleName(name) == wanted
        }) {
            target = option
        } else {
            // The choice is no longer offered: accept the new selection as it is.
            lastSubtitleChoiceName = Self.subtitleChoiceName(item.currentMediaSelection.selectedMediaOption(in: group))
            return
        }
        item.select(target, in: group)
        selectionVersion &+= 1
        print("[NativePlayer] subtitles kept on ‘\(wanted.isEmpty ? "Off" : wanted)’ after the audio switch")
    }

    private func currentAudioChoiceName(item: AVPlayerItem) -> String? {
        guard let group = audibleGroup, let option = item.currentMediaSelection.selectedMediaOption(in: group)
        else { return nil }
        return Self.renditionName(of: option)
    }

    private func persistSubtitleChoice(option: AVMediaSelectionOption?) {
        let metaId = context.parentMetaId
        let current = persistedTrackPreference
        guard let option else {
            persistedTrackPreference = PlayerSubtitleMemory.saveOff(parentMetaId: metaId, keeping: current)
            return
        }
        guard let rendition = subtitleRenditionsByName[Self.canonicalSubtitleName(Self.renditionName(of: option))]
        else { return }
        if let url = rendition.sourceURL, let addon = masterAddonSubtitlesByURL[url.absoluteString] {
            persistedTrackPreference = PlayerSubtitleMemory.saveAddon(parentMetaId: metaId, subtitle: addon,
                                                                      keeping: current)
        } else {
            persistedTrackPreference = PlayerSubtitleMemory.saveInternal(
                parentMetaId: metaId, language: rendition.language, name: rendition.name, trackId: nil,
                forced: rendition.forced, keeping: current
            )
        }
    }

    /// "" = Off (rendition names are never empty).
    private static func subtitleChoiceName(_ option: AVMediaSelectionOption?) -> String {
        option.map { canonicalSubtitleName(renditionName(of: $0)) } ?? ""
    }

    /// The form a rendition's `sourceURL` takes, for matching an addon subtitle's URL string to it.
    static func subtitleURLKey(_ url: String) -> String {
        URL(string: url)?.absoluteString ?? url
    }

    // MARK: - Top panel: media selection API (Subtitles / Audio tabs)

    /// Select a legible option (nil = Off). AVPlayer honours manual picks over the criteria.
    func select(subtitle option: AVMediaSelectionOption?) {
        subtitleRefetchRestoreTask?.cancel(); subtitleRefetchRestoreTask = nil
        isRefetchingSubtitles = false
        guard let item = playerItem, let group = legibleGroup else { return }
        item.select(option, in: group)
        print("[NativePlayer] subtitle selection → \(option.map(Self.renditionName(of:)) ?? "Off")")
        selectionVersion &+= 1
        // A panel pick is the viewer's: remembered for the next episode (c9d6f5f63).
        lastSubtitleChoiceName = Self.subtitleChoiceName(option)
        persistSubtitleChoice(option: option)
    }

    /// Select an audible option; the remux worker is switched by `syncAudioSelection` on the
    /// next tick / media-selection notification, exactly as for a pick from the native popover.
    func select(audio option: AVMediaSelectionOption) {
        guard let item = playerItem, let group = audibleGroup, let player else { return }
        item.select(option, in: group)
        selectionVersion &+= 1
        // A panel pick is the viewer's: remembered for the next episode (LANG-09 / STAB-05).
        rememberAudioChoice(option: option,
                            stream: Self.renditionStream(for: option, byName: audioRenditionsByName,
                                                         tracks: remux?.audioTracks ?? []))
        syncAudioSelection(item: item, player: player)
    }

    var currentSubtitleOption: AVMediaSelectionOption? {
        guard let item = playerItem, let group = legibleGroup else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)
    }

    var currentAudioOption: AVMediaSelectionOption? {
        guard let item = playerItem, let group = audibleGroup else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)
    }

    /// The rendition NAME of an option (its common-metadata title); `displayName` is AVFoundation's
    /// localized language, which is not unique.
    static func renditionName(of option: AVMediaSelectionOption) -> String {
        AVMetadataItem.metadataItems(from: option.commonMetadata,
                                     filteredByIdentifier: .commonIdentifierTitle).first?.stringValue ?? option.displayName
    }

    /// Whether the top panel should list this subtitle option under "Show only preferred languages".
    func subtitleOptionAllowed(_ option: AVMediaSelectionOption) -> Bool {
        guard languagePlan.onlyPreferredLanguages else { return true }
        let allowed = languagePlan.subtitleFilterLanguages
        guard !allowed.isEmpty, let tag = option.extendedLanguageTag else { return true }
        return allowed.contains { PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: tag, targetLanguage: $0) }
    }

    /// True once the addon subtitle fetch has completed (top panel empty-state copy).
    var addonSubtitlesFetched: Bool { subsFetchDone }

    /// Metadata chips for the Info tab (the dynamic half — the screen prepends context-derived
    /// year/runtime/rating and appends genres). Bare values, Infuse-style.
    func infoChips() -> [PlayerPanelChip] {
        var chips: [PlayerPanelChip] = []
        if lastDurationSec > 0 { chips.append(PlayerPanelChip(text: Self.runtimeString(lastDurationSec), isRuntime: true)) }
        if let s = remux?.videoSignaling {
            if s.height >= 2000 { chips.append(PlayerPanelChip(text: "4K")) }
            else if s.height >= 1000 { chips.append(PlayerPanelChip(text: "1080p")) }
            else if s.height >= 700 { chips.append(PlayerPanelChip(text: "720p")) }
            else if s.height > 0 { chips.append(PlayerPanelChip(text: "SD")) }
            if s.supplementalCodecs != nil { chips.append(PlayerPanelChip(text: "Dolby Vision")) }
            else if s.videoRange == "PQ" { chips.append(PlayerPanelChip(text: "HDR10")) }
            else if s.videoRange == "HLG" { chips.append(PlayerPanelChip(text: "HLG")) }
            let codec = s.codecs.lowercased()
            if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") || codec.hasPrefix("dvh1") || codec.hasPrefix("dvhe") {
                chips.append(PlayerPanelChip(text: "HEVC"))
            } else if codec.hasPrefix("avc1") || codec.hasPrefix("avc3") {
                chips.append(PlayerPanelChip(text: "H.264"))
            }
            if s.frameRate > 0 { chips.append(PlayerPanelChip(text: LocalizedNumberFormat.frameRate(Double(s.frameRate)))) }
        }
        if let audio = audioTracks.first(where: \.selected)?.name {
            // Drop the leading language ("English · ") — the chip is about the format.
            let parts = audio.components(separatedBy: " \u{00B7} ")
            chips.append(PlayerPanelChip(text: parts.count > 1 ? parts.dropFirst().joined(separator: " \u{00B7} ") : audio))
        }
        if let event = playerItem?.accessLog()?.events.last, event.indicatedBitrate > 0 {
            chips.append(PlayerPanelChip(text: LocalizedNumberFormat.bitrate(bitsPerSecond: event.indicatedBitrate)))
        } else if let bandwidth = remux?.estimatedBandwidth, bandwidth > 0 {
            chips.append(PlayerPanelChip(text: LocalizedNumberFormat.bitrate(bitsPerSecond: Double(bandwidth))))
        }
        return chips
    }

    private static func runtimeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }

    // MARK: - Subtitle languages, ranking and appearance

    /// Normalized tag + localized name for every raw language code the master will carry
    /// (LANG-07), resolved here on the main actor and handed to the nonisolated `SubtitleVTT`.
    func subtitleLanguageLabels(rawLanguages: [String]) -> [String: SubtitleLanguageLabel] {
        var labels: [String: SubtitleLanguageLabel] = [:]
        for raw in rawLanguages where labels[raw] == nil {
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let tag = TrackLabelFormatter.normalizedTag(raw)
            let name = TrackLabelFormatter.languageName(raw)
            guard tag != nil || name != nil else { continue }
            labels[raw] = SubtitleLanguageLabel(tag: tag, name: name)
        }
        return labels
    }

    /// Most addon subtitles offered per language (LANG-05).
    static let addonSubtitlesPerLanguage = 4

    /// Addon subtitles in the order the master offers them (LANG-05): preferred subtitle languages
    /// first (in preference order), then the audio's language, then the rest, each language capped
    /// at `addonSubtitlesPerLanguage`; the addon order is kept inside a rank. The stream's own
    /// files are prepended by the caller, and `SubtitleVTT` caps the total.
    func rankedAddonSubtitles(_ subs: [AddonSubtitle], audioLanguage: String?) -> [AddonSubtitle] {
        let targets = languagePlan.subtitleFilterLanguages.isEmpty
            ? languagePlan.subtitleTargets : languagePlan.subtitleFilterLanguages
        let audio = audioLanguage.flatMap { $0.isEmpty || $0.lowercased() == "und" ? nil : $0 }
            .map { TrackLabelFormatter.normalizedTag($0) ?? $0 }
        func rank(_ sub: AddonSubtitle) -> Int {
            if let index = targets.firstIndex(where: {
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: sub.language, targetLanguage: $0)
            }) { return index }
            if let audio, PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: sub.language,
                                                                               targetLanguage: audio) {
                return targets.count
            }
            return targets.count + 1
        }
        let ordered = subs.enumerated()
            .map { (offset: $0.offset, sub: $0.element, rank: rank($0.element)) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
        var perLanguage: [String: Int] = [:]
        var out: [AddonSubtitle] = []
        for entry in ordered {
            let key = (TrackLabelFormatter.normalizedTag(entry.sub.language) ?? entry.sub.language).lowercased()
            let count = perLanguage[key, default: 0]
            guard count < Self.addonSubtitlesPerLanguage else { continue }
            perLanguage[key] = count + 1
            out.append(entry.sub)
        }
        return out
    }

    /// Subtitle appearance on the native engine (LANG-06): the user's Settings → Subtitles style
    /// becomes the item's `textStyleRules`. Only values that differ from the default style are set,
    /// so an untouched style leaves the system caption appearance (Accessibility) in charge.
    /// Sampled per item, like the mpv engine applies it per file.
    func applySubtitleAppearance(to item: AVPlayerItem) {
        guard let style = playerSettings?.subtitleStyle else { return }
        var attributes: [String: Any] = [:]
        if style.textColor != Self.defaultTextARGB {
            attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] = Self.argbComponents(style.textColor)
        }
        let backgroundAlpha = (style.backgroundColor >> 24) & 0xFF
        if backgroundAlpha > 0 {
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] =
                Self.argbComponents(style.backgroundColor)
        }
        if style.bold {
            attributes[kCMTextMarkupAttribute_BoldStyle as String] = true
        }
        if style.fontSizeSp > 0, style.fontSizeSp != Self.defaultFontSizeSp {
            // Relative size in percent of the default caption size (Small 78 % … X-Large 167 %).
            let percent = Double(style.fontSizeSp) / Double(Self.defaultFontSizeSp) * 100
            attributes[kCMTextMarkupAttribute_RelativeFontSize as String] = max(50, min(200, percent))
        }
        if !style.outlineEnabled {
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = kCMTextMarkupCharacterEdgeStyle_None as String
        } else if style.outlineColor != Self.defaultOutlineARGB {
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = kCMTextMarkupCharacterEdgeStyle_Uniform as String
        }
        guard !attributes.isEmpty, let rule = AVTextStyleRule(textMarkupAttributes: attributes) else {
            item.textStyleRules = nil
            return
        }
        item.textStyleRules = [rule]
        print("[NativePlayer] subtitle style rules: \(attributes.count) attribute(s), size \(style.fontSizeSp)")
    }

    /// `SubtitleStyleState` defaults (shared `SubtitleAudioModels.kt`): white text, black outline,
    /// 18 sp.
    private static let defaultTextARGB: Int64 = 0xFFFFFFFF
    private static let defaultOutlineARGB: Int64 = 0xFF000000
    private static let defaultFontSizeSp: Int32 = 18

    /// 0xAARRGGBB → [A, R, G, B] in 0…1, the form CoreMedia's text-markup colour attributes take.
    private static func argbComponents(_ argb: Int64) -> [NSNumber] {
        let a = Double((argb >> 24) & 0xFF) / 255, r = Double((argb >> 16) & 0xFF) / 255
        let g = Double((argb >> 8) & 0xFF) / 255, b = Double(argb & 0xFF) / 255
        return [a, r, g, b].map { NSNumber(value: $0) }
    }

    // MARK: - Audio track display names

    /// 10-foot menu label: localized language with its variant, codec + channel layout, the
    /// release tag, then the container's track title when it adds information. E.g.
    /// "Français (Canada) · Dolby Digital+ 5.1 · VFQ", "English · Dolby Atmos · Commentary".
    /// Same pieces as the mpv engine's rows (`MPVTrackFields`).
    static func audioTrackDisplayName(_ track: RemuxAudioTrack) -> String {
        var parts: [String] = []
        let title = track.title?.trimmingCharacters(in: .whitespaces) ?? ""
        // Shared formatter (contract C3, LANG-07/10): ISO 639-2/B codes ("fre") read "French", and
        // a title stating the variant ("VFQ", "French (Canada)") makes it "French (Canada)".
        let tag = TrackLabelFormatter.trackLanguageTag(language: track.language, title: title)
        if let language = TrackLabelFormatter.languageName(tag) {
            parts.append(language)
        } else if let raw = track.language?.lowercased(), !raw.isEmpty, raw != "und",
                  let language = Locale.current.localizedString(forLanguageCode: Self.iso639BtoT[raw] ?? raw) {
            parts.append(language)
        }
        let hasLanguage = !parts.isEmpty
        let atmos = TrackLabelFormatter.looksAtmos(title)
        let detail = TrackLabelFormatter.audioDetail(codec: track.codec, channels: track.channels, atmos: atmos)
            ?? "\(Self.audioCodecDisplay[track.codec] ?? track.codec.uppercased()) \(Self.channelText(track.channels))"
        parts.append(detail)
        // The release tag ("VFF", "VFQ"): two French dubs must read apart.
        if hasLanguage, let release = TrackLabelFormatter.releaseTag(title) {
            parts.append(release)
        }
        // The container title when it adds information ("Commentary"), not when it only repeats
        // the language, a release tag or the format ("French", "VFF 5.1", "Atmos").
        if let descriptor = TrackLabelFormatter.titleDescriptor(title, language: tag ?? track.language),
           descriptor.count <= 42, !detail.localizedCaseInsensitiveContains(descriptor) {
            parts.append(descriptor)
        }
        return parts.isEmpty ? String(localized: "Track \(track.streamIndex)") : parts.joined(separator: " \u{00B7} ")
    }

    /// MKV language tags are usually ISO 639-2/B; Locale wants /T for the codes where they differ.
    private static let iso639BtoT: [String: String] = [
        "fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho", "cze": "ces", "gre": "ell",
        "ice": "isl", "per": "fas", "rum": "ron", "slo": "slk", "arm": "hye", "geo": "kat",
        "may": "msa", "alb": "sqi", "baq": "eus", "bur": "mya", "mac": "mkd", "tib": "bod",
        "wel": "cym",
    ]

    private static let audioCodecDisplay: [String: String] = [
        "aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital+", "truehd": "TrueHD",
        "dts": "DTS", "flac": "FLAC", "alac": "ALAC", "mp3": "MP3", "opus": "Opus",
        "vorbis": "Vorbis",
    ]

    private static func channelText(_ channels: Int) -> String {
        switch channels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }
}
