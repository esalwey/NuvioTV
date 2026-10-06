import Foundation
import MediaAccessibility
import SharedCore
import UIKit

/// Pure decision logic for the audio-language preference (tvOS analogue of upstream 4f79bfe0's
/// proactive `alang`), plus the language defaults both engines share (spec §8.1). Kept free of
/// mpv so `NuvioTVTests` can cover it.
enum PlayerAudioLanguagePlan {
    /// mpv `alang` option value: the preferred language targets in priority order, comma-joined.
    static func alangValue(targets: [String]) -> String {
        targets.joined(separator: ",")
    }

    /// The track id to force after the track list is known, or `nil` when nothing should change.
    ///
    /// Walks `targets` in priority order. The first target that matches ANY track decides. Among
    /// its matches, the tracks of the target's exact variant come first (LANG-10: target "fr" picks
    /// the "VFF" dub over the "VFQ" one, target "fr-CA" the reverse); if one of those is already
    /// `selected` (mpv's own `alang` pick satisfied it), return `nil` so the caller does not
    /// re-poke `aid` after the first frame; otherwise return the first one's id. No target matches
    /// at all → `nil` (leave mpv's default alone). A track with no language code is matched by its
    /// title ("Español", "VFQ"). Matching delegates to the shared Kotlin matcher so `jpn`/`ja`,
    /// `pt-BR`/`pt` etc. behave exactly as the rest of the app.
    static func trackToForce(
        targets: [String],
        tracks: [(id: Int, lang: String, title: String, selected: Bool)]
    ) -> Int? {
        for target in targets {
            let matches = tracks.filter { audioTrack(lang: $0.lang, title: $0.title, matches: target) }
            guard !matches.isEmpty else { continue }
            let wanted = SubtitleLanguageMatching.shared.normalizeLanguageCode(lang: target)
            let exact = matches.filter {
                SubtitleLanguageMatching.shared.detectTrackLanguageVariant(language: $0.lang, name: $0.title, trackId: nil)
                    == wanted
            }
            let pool = exact.isEmpty ? matches : exact
            if pool.contains(where: { $0.selected }) { return nil }
            return pool.first?.id
        }
        return nil
    }

    /// One audio track against one language target: its code, else (no usable code) its title.
    static func audioTrack(lang: String, title: String, matches target: String) -> Bool {
        if PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: lang, targetLanguage: target) {
            return true
        }
        let code = lang.trimmingCharacters(in: .whitespaces).lowercased()
        guard code.isEmpty || code == "und" || code == "unknown",
              let stated = PlayerLanguagePreferencesKt.languageFromTrackText(text: title)
        else { return false }
        return PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: stated, targetLanguage: target)
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
        if let saved = persisted?.audioLanguage,
           let normalized = PlayerLanguagePreferencesKt.normalizeLanguageCode(language: saved) {
            targets.removeAll { $0 == normalized }
            targets.insert(normalized, at: 0)
        }
        return targets
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
