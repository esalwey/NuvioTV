import SharedCore

/// Subtitle choice memory for both engines (upstream c9d6f5f63, "restore subtitles for each
/// episode"): the viewer's pick is saved per title — series-wide, profile-scoped, in the shared
/// `PlayerTrackPreferenceStorage` mobile uses — and restored when the next episode (or the next
/// session) starts: Off stays off, an embedded track is matched by language / forced flag / name
/// (`findPersistedSubtitleTrackIndex`), an addon subtitle by the saved file on the same episode,
/// else by this episode's subtitle in the saved language from the saved provider
/// (`findPersistedAddonSubtitle`). The subtitle saves leave the audio half of the stored preference
/// as it is; `saveAudio` writes it (and leaves the subtitle half).
enum PlayerSubtitleMemory {
    static func load(parentMetaId: String) -> PersistedPlayerTrackPreference? {
        PlayerTrackPreferenceStorage.shared.load(contentId: parentMetaId)
    }

    /// Subtitles turned off.
    @discardableResult
    static func saveOff(parentMetaId: String,
                        keeping current: PersistedPlayerTrackPreference?) -> PersistedPlayerTrackPreference {
        save(parentMetaId: parentMetaId, preference(
            type: PersistedSubtitleSelectionType.shared.DISABLED,
            language: nil, name: nil, trackId: nil, forced: nil, addon: nil, keeping: current))
    }

    /// A track of the file itself (or a subtitle file the stream came with).
    @discardableResult
    static func saveInternal(parentMetaId: String, language: String?, name: String?, trackId: String?,
                             forced: Bool, keeping current: PersistedPlayerTrackPreference?) -> PersistedPlayerTrackPreference {
        save(parentMetaId: parentMetaId, preference(
            type: PersistedSubtitleSelectionType.shared.INTERNAL,
            language: language, name: name, trackId: trackId, forced: forced, addon: nil, keeping: current))
    }

    /// A subtitle from a subtitle addon.
    @discardableResult
    static func saveAddon(parentMetaId: String, subtitle: AddonSubtitle,
                          keeping current: PersistedPlayerTrackPreference?) -> PersistedPlayerTrackPreference {
        save(parentMetaId: parentMetaId, preference(
            type: PersistedSubtitleSelectionType.shared.ADDON,
            language: subtitle.language, name: subtitle.display, trackId: nil, forced: nil,
            addon: subtitle, keeping: current))
    }

    /// The viewer picked an audio track (LANG-09, STAB-05, contract C4): remembered for the title
    /// like the subtitle choice. The subtitle half of `current` is kept as it is. On the next file,
    /// the saved language goes first in the audio targets and `findPersistedAudioTrackIndex`
    /// chooses between same-language variants by name.
    @discardableResult
    static func saveAudio(parentMetaId: String, language: String?, name: String?, trackId: String?,
                          keeping current: PersistedPlayerTrackPreference?) -> PersistedPlayerTrackPreference {
        save(parentMetaId: parentMetaId, PersistedPlayerTrackPreference(
            subtitleType: current?.subtitleType,
            subtitleLanguage: current?.subtitleLanguage,
            subtitleName: current?.subtitleName,
            subtitleTrackId: current?.subtitleTrackId,
            addonSubtitleId: current?.addonSubtitleId,
            addonSubtitleUrl: current?.addonSubtitleUrl,
            addonSubtitleAddonName: current?.addonSubtitleAddonName,
            audioLanguage: language,
            audioName: name,
            audioTrackId: trackId,
            subtitleIsForced: current?.subtitleIsForced
        ))
    }

    /// `preference` without its track id: another file's track numbering must not decide the match.
    static func withoutTrackId(_ preference: PersistedPlayerTrackPreference) -> PersistedPlayerTrackPreference {
        PersistedPlayerTrackPreference(
            subtitleType: preference.subtitleType,
            subtitleLanguage: preference.subtitleLanguage,
            subtitleName: preference.subtitleName,
            subtitleTrackId: nil,
            addonSubtitleId: preference.addonSubtitleId,
            addonSubtitleUrl: preference.addonSubtitleUrl,
            addonSubtitleAddonName: preference.addonSubtitleAddonName,
            audioLanguage: preference.audioLanguage,
            audioName: preference.audioName,
            audioTrackId: preference.audioTrackId,
            subtitleIsForced: preference.subtitleIsForced
        )
    }

    private static func save(parentMetaId: String,
                             _ preference: PersistedPlayerTrackPreference) -> PersistedPlayerTrackPreference {
        PlayerTrackPreferenceStorage.shared.save(contentId: parentMetaId, preference: preference)
        return preference
    }

    private static func preference(type: String, language: String?, name: String?, trackId: String?,
                                   forced: Bool?, addon: AddonSubtitle?,
                                   keeping current: PersistedPlayerTrackPreference?) -> PersistedPlayerTrackPreference {
        PersistedPlayerTrackPreference(
            subtitleType: type,
            subtitleLanguage: language,
            subtitleName: name,
            subtitleTrackId: trackId,
            addonSubtitleId: addon?.id,
            addonSubtitleUrl: addon?.url,
            addonSubtitleAddonName: addon?.addonName,
            audioLanguage: current?.audioLanguage,
            audioName: current?.audioName,
            audioTrackId: current?.audioTrackId,
            subtitleIsForced: forced.map { KotlinBoolean(bool: $0) }
        )
    }
}
