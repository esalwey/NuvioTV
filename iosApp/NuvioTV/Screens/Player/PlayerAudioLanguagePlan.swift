import Foundation
import MediaAccessibility
import SharedCore
import UIKit

/// Pure decision logic for the audio-language preference (tvOS analogue of upstream 4f79bfe0's
/// proactive `alang`), plus the language defaults both engines share (spec §8.1). Kept free of
/// mpv so `NuvioTVTests` can cover it.
enum PlayerAudioLanguagePlan {
    /// mpv `alang` option value: the preferred language targets in priority order, comma-joined.
    /// A regional target ("fr-ca", "fr-fr") is followed by its base language: mpv cannot tell two
    /// "fre" tracks apart by code anyway, and the base keeps its first pick in the right language
    /// whatever its region matching does. The variant itself is then settled by `trackToForce`.
    static func alangValue(targets: [String]) -> String {
        var values: [String] = []
        for target in targets {
            let trimmed = target.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !values.contains(trimmed) { values.append(trimmed) }
            if let dash = trimmed.firstIndex(of: "-") {
                let base = String(trimmed[..<dash])
                if !base.isEmpty, !values.contains(base) { values.append(base) }
            }
        }
        return values.joined(separator: ",")
    }

    /// The track id to force after the track list is known, or `nil` when nothing should change.
    ///
    /// Walks `targets` in priority order. The first target that matches ANY track decides. Among
    /// its matches, the tracks of the target's exact variant come first (LANG-10: target "fr" —
    /// or the Apple TV's "fr-FR" — picks the "VFF" dub over the "VFQ" one, target "fr-CA" the
    /// reverse); if one of those is already `selected` (mpv's own `alang` pick satisfied it),
    /// return `nil` so the caller does not re-poke `aid` after the first frame; otherwise return the
    /// first one's id. No target matches at all → `nil` (leave mpv's default alone). A track with
    /// no language code is matched by its title ("Español", "VFQ"). The decision is the shared
    /// `preferredAudioTrackCandidates`, the same rule the native engine's remux pick uses.
    static func trackToForce(
        targets: [String],
        tracks: [(id: Int, lang: String, title: String, selected: Bool)]
    ) -> Int? {
        guard !targets.isEmpty, !tracks.isEmpty else { return nil }
        let shared = tracks.enumerated().map { index, track in
            AudioTrack(
                index: Int32(index),
                id: String(track.id),
                label: track.title,
                language: track.lang.isEmpty ? nil : track.lang,
                isSelected: track.selected
            )
        }
        let pool = PlayerTrackSelectionKt.preferredAudioTrackCandidates(tracks: shared, targets: targets)
            .map { Int($0.int32Value) }
            .filter { tracks.indices.contains($0) }
        guard let first = pool.first else { return nil }
        if pool.contains(where: { tracks[$0].selected }) { return nil }
        return tracks[first].id
    }

    /// The audio-language targets in priority order, for both engines: the language the viewer
    /// last picked for this title goes first (LANG-09: a switch to Japanese on E1 carries to E2),
    /// then the settings' targets. "Original" with an unknown original language falls back to the
    /// system's preferred languages inside the shared resolver (spec §8.1, gap 4).
    static func audioTargets(settings: PlayerSettingsUiState,
                             context: PlaybackContext,
                             persisted: PersistedPlayerTrackPreference?) -> [String] {
        var targets = PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
            preferredAudioLanguage: settings.preferredAudioLanguage,
            secondaryPreferredAudioLanguage: settings.secondaryPreferredAudioLanguage,
            deviceLanguages: DeviceLanguagePreferences.shared.preferredLanguageCodes(),
            contentOriginalLanguage: originalLanguage(for: context)
        )
        // The stream-recommendation audio choice (e.g. VFQ on a VF2 file) goes first; a track the
        // viewer picked for this show still wins below.
        targets = StreamPlaybackAudioHints.audioTargets(context: context, base: targets,
                                                        originalLanguage: originalLanguage(for: context))
        if let saved = persistedAudioTarget(persisted) {
            targets.removeAll { $0 == saved }
            targets.insert(saved, at: 0)
        }
        return targets
    }

    /// The saved audio choice as a target, with its variant (LANG-10): "fre" saved with the name
    /// "VFQ" is "fr-ca", so the next episode starts on the Québec dub again, not merely on French.
    /// Nil when nothing usable is saved.
    static func persistedAudioTarget(_ persisted: PersistedPlayerTrackPreference?) -> String? {
        guard let saved = persisted?.audioLanguage?.trimmingCharacters(in: .whitespaces), !saved.isEmpty
        else { return nil }
        let variant = SubtitleLanguageMatching.shared.detectTrackLanguageVariant(
            language: saved, name: persisted?.audioName, trackId: nil)
        let target = variant.isEmpty ? PlayerLanguagePreferencesKt.normalizeLanguageCode(language: saved) : variant
        guard let target, !target.isEmpty, target != "und", target != "unknown" else { return nil }
        return target
    }

    /// The system "Closed Captions + SDH" accessibility setting (spec §8.1): subtitles always on,
    /// SDH tracks preferred.
    static var closedCaptionsPreferred: Bool {
        UIAccessibility.isClosedCaptioningEnabled
            || MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
    }

    /// The shared subtitle plan with the tvOS defaults (spec §8.1): the "Forced" subtitle option,
    /// forced subtitles when the audio is in the device's language ("Use forced subtitles" on), and
    /// always-on subtitles when closed captions are on. Nil = leave the player's defaults alone.
    /// Both engines can call it; the mpv engine does.
    static func subtitlePlan(settings: PlayerSettingsUiState,
                             audio: AudioTrack?,
                             audioTargets: [String]) -> SubtitleAutoSelectionPlan? {
        let deviceLanguages = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let subtitleTargets = PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: settings.preferredSubtitleLanguage,
            secondaryPreferredSubtitleLanguage: settings.secondaryPreferredSubtitleLanguage,
            deviceLanguages: deviceLanguages
        )
        return PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlanWithDefaults(
            selectedAudioTrack: audio,
            preferredAudioTargets: audioTargets,
            preferredSubtitleTargets: subtitleTargets,
            useForcedSubtitles: settings.subtitleStyle.useForcedSubtitles,
            deviceLanguages: deviceLanguages,
            closedCaptionsEnabled: closedCaptionsPreferred
        )
    }

    /// The title's original language for the "Original" audio preference, or nil when unknown.
    /// Prefers the value carried on the launch context (filled by `PlaybackMeta.init(details:)` on
    /// the Detail / episode-shelf paths); falls back to the shared meta-details cache, which is warm
    /// whenever the title's Detail page was opened this session and cold on Home continue-watching
    /// or deep-link launches. Nil there is fine: the shared target resolver then uses the system's
    /// preferred languages (`DeviceLanguagePreferences`, i.e. `AppleLanguages`). Shared by both
    /// engines (mpv `MPVPlayerView`, native `NativePlaybackCoordinator`) so they cannot diverge.
    static func originalLanguage(for context: PlaybackContext) -> String? {
        if let fromContext = context.meta?.originalLanguage, !fromContext.isEmpty {
            return fromContext
        }
        guard let details = MetaDetailsRepository.shared.peek(type: context.contentType, id: context.parentMetaId)
        else { return nil }
        return PlayerLanguagePreferencesKt.resolveContentLanguage(language: details.language, country: details.country)
    }
}
