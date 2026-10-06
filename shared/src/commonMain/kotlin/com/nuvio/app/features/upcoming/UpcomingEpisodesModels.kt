package com.nuvio.app.features.upcoming

import com.nuvio.app.features.home.MetaPreview

// Fork: tvOS-first Home "Upcoming" row (no upstream twin). Everything here is public because the
// native tvOS SwiftUI Home screen consumes it through the SharedCore framework.

/**
 * One card in the Home "Upcoming" row: a followed show's next episode that airs today or within
 * the horizon. Exactly one item per show.
 */
data class UpcomingEpisodeItem(
    val showId: String,
    /** Normalized series type ("series") so Detail navigation resolves the same meta addons. */
    val showType: String,
    val showTitle: String,
    /** Leading 4-digit year of the show's releaseInfo (e.g. "2024"), for the caption line. */
    val showYear: String?,
    val showPoster: String?,
    val showBackground: String?,
    val showLogo: String?,
    val episodeId: String,
    val season: Int,
    val episode: Int,
    val episodeTitle: String?,
    val episodeThumbnail: String?,
    /** Local calendar air date, ISO yyyy-MM-dd. */
    val airDateIso: String,
    /** Whole days from "today" to [airDateIso]; 0 = airs today. */
    val daysUntilAir: Int,
) {
    val showKey: String get() = "$showType:$showId"

    /** Card artwork: episode still first (matches the reference design), then show backdrop/poster. */
    val imageUrl: String? get() = episodeThumbnail ?: showBackground ?: showPoster

    /**
     * Navigation payload for the show's Detail page. Built here (not in Swift) because Kotlin
     * default arguments are not exported to the ObjC/Swift surface.
     */
    fun toMetaPreview(): MetaPreview = MetaPreview(
        id = showId,
        type = showType,
        name = showTitle,
        poster = showPoster,
        banner = showBackground,
        logo = showLogo,
        releaseInfo = showYear,
    )
}

data class UpcomingEpisodesUiState(
    val items: List<UpcomingEpisodeItem> = emptyList(),
    val isLoading: Boolean = false,
    /** True once the first full pass has published (even if it found nothing). */
    val hasLoaded: Boolean = false,
)

/** A followed show to resolve; ordering input for the fan-out cap. */
data class UpcomingShowRef(
    val type: String,
    val id: String,
    val lastTouchedEpochMs: Long,
) {
    val key: String get() = "$type:$id"
}
