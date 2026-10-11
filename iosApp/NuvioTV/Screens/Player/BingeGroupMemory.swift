import Foundation
import SharedCore

/// The source group (the stream's binge group: same add-on, same release family and quality) a
/// series was last played from, kept between viewings in the shared `BingeGroupCacheRepository`
/// (profile scoped, the store the phone uses).
///
/// Up Next prefers the group of the episode that is playing (`PlaybackContext.bingeGroup`). The
/// remembered one (Settings > Playback > Remember the Source Group) covers the starts that carry no
/// group: resuming from Continue Watching, where the progress record has none. It is written every
/// time a stream is picked, whatever the setting, so turning the setting on finds the group of the
/// series already watched; reading it is what the setting decides.
enum BingeGroupMemory {
    /// A stream with this binge group is being played for `parentMetaId`.
    static func remember(parentMetaId: String, bingeGroup: String?) {
        let group = bingeGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !group.isEmpty, !parentMetaId.isEmpty else { return }
        BingeGroupCacheRepository.shared.save(contentId: parentMetaId, bingeGroup: group)
    }

    /// The group remembered for `parentMetaId`, nil when none is kept.
    static func remembered(parentMetaId: String) -> String? {
        guard !parentMetaId.isEmpty else { return nil }
        let group: String? = BingeGroupCacheRepository.shared.get(contentId: parentMetaId)
        guard let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The group Up Next should follow: the playing stream's own, else — with the setting on — the
    /// remembered one. nil = no preference.
    static func preferred(playing: String?, parentMetaId: String, reuseRemembered: Bool) -> String? {
        let own = (playing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return reuseRemembered ? remembered(parentMetaId: parentMetaId) : nil
    }
}
