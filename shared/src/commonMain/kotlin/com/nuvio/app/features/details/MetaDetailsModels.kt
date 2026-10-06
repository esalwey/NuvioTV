package com.nuvio.app.features.details

import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.streams.StreamItem

data class MetaDetails(
    val id: String,
    val type: String,
    val name: String,
    /** Upstream 90054b7b9: the addon's own `imdb_id`, the enrichment fallback for non-IMDB ids. */
    val imdbId: String? = null,
    val poster: String? = null,
    val background: String? = null,
    val logo: String? = null,
    val description: String? = null,
    val releaseInfo: String? = null,
    /** TV: ISO last air date from TMDB (or addon) for year-range display. */
    val lastAirDate: String? = null,
    val status: String? = null,
    val imdbRating: String? = null,
    val ageRating: String? = null,
    val runtime: String? = null,
    val externalRatings: List<MetaExternalRating> = emptyList(),
    val genres: List<String> = emptyList(),
    val director: List<String> = emptyList(),
    val writer: List<String> = emptyList(),
    val cast: List<MetaPerson> = emptyList(),
    val productionCompanies: List<MetaCompany> = emptyList(),
    val networks: List<MetaCompany> = emptyList(),
    val country: String? = null,
    val awards: String? = null,
    val language: String? = null,
    val website: String? = null,
    val hasScheduledVideos: Boolean = false,
    val defaultVideoId: String? = null,
    val moreLikeThis: List<MetaPreview> = emptyList(),
    val moreLikeThisSource: MoreLikeThisSource? = null,
    val collectionName: String? = null,
    val collectionItems: List<MetaPreview> = emptyList(),
    val trailers: List<MetaTrailer> = emptyList(),
    val links: List<MetaLink> = emptyList(),
    /// Upstream f5726012/22096a1e: addon-supplied season art (`app_extras.seasonPosters`), keyed by
    /// season NUMBER (specials = 0), not by array position. A fallback for seasons whose episodes
    /// carry no `MetaVideo.seasonPoster` (TMDB enrichment or per-video addon field) — not an override.
    val seasonPosters: Map<Int, String> = emptyMap(),
    val videos: List<MetaVideo> = emptyList(),
)

enum class MoreLikeThisSource {
    TMDB,
    TRAKT,
}

data class MetaExternalRating(
    val source: String,
    val value: Double,
)

data class MetaTrailer(
    val id: String,
    val key: String,
    val name: String,
    val site: String,
    val size: Int? = null,
    val type: String = "Trailer",
    val official: Boolean = false,
    val publishedAt: String? = null,
    val seasonNumber: Int? = null,
    val displayName: String? = null,
    /** BUG-63: ISO 639-1 tag of the video itself (TMDB `iso_639_1`), lowercase; null when the
     *  source (addon meta) doesn't say. Used only to *prefer* the Metadata Language at selection. */
    val language: String? = null,
)

data class MetaPerson(
    val name: String,
    val role: String? = null,
    val photo: String? = null,
    val tmdbId: Int? = null,
)

data class MetaCompany(
    val name: String,
    val logo: String? = null,
    val tmdbId: Int? = null,
)

data class MetaLink(
    val name: String,
    val category: String,
    val url: String,
)

data class MetaVideo(
    val id: String,
    val title: String,
    val released: String? = null,
    val available: Boolean = true,
    val thumbnail: String? = null,
    val seasonPoster: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val overview: String? = null,
    val runtime: Int? = null,
    val rating: Double? = null,
    val streams: List<StreamItem> = emptyList(),
)

data class MetaDetailsUiState(
    val isLoading: Boolean = false,
    val meta: MetaDetails? = null,
    val errorMessage: String? = null,
    // Original "$type:$id" request key the emission belongs to (the catalog-preview id we were
    // asked to load, NOT the remapped/canonical meta id). Lets the UI match emissions to the
    // title it requested. Null for the initial/cleared empty state.
    val requestKey: String? = null,
)
