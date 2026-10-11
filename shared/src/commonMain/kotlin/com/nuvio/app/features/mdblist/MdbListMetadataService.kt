package com.nuvio.app.features.mdblist

import com.nuvio.app.features.details.MetaDetails

object MdbListMetadataService {
    const val PROVIDER_IMDB = "imdb"
    const val PROVIDER_TMDB = "tmdb"
    const val PROVIDER_TOMATOES = "tomatoes"
    const val PROVIDER_METACRITIC = "metacritic"
    const val PROVIDER_TRAKT = "trakt"
    const val PROVIDER_LETTERBOXD = "letterboxd"
    const val PROVIDER_AUDIENCE = "audience"
    const val PROVIDER_MAL = "mal"

    val PROVIDER_PRIORITY_ORDER = listOf(
        PROVIDER_IMDB,
        PROVIDER_TMDB,
        PROVIDER_TOMATOES,
        PROVIDER_METACRITIC,
        PROVIDER_TRAKT,
        PROVIDER_LETTERBOXD,
        PROVIDER_AUDIENCE,
        PROVIDER_MAL,
    )

    private val ratingsRepository = MdbListRatingsRepository()
    private val imdbRegex = Regex("tt\\d+")

    fun shouldFetchForMeta(
        meta: MetaDetails,
        fallbackItemId: String,
        settings: MdbListSettings,
    ): Boolean {
        if (!settings.isActive) return false
        if (settings.enabledProvidersInPriorityOrder().isEmpty()) return false
        return extractImdbId(meta.id) != null ||
            extractImdbId(fallbackItemId) != null ||
            extractImdbId(meta.imdbId) != null
    }

    suspend fun enrichMeta(
        meta: MetaDetails,
        fallbackItemId: String,
        settings: MdbListSettings,
    ): MetaDetails {
        if (!shouldFetchForMeta(meta, fallbackItemId, settings)) {
            return meta.copy(externalRatings = emptyList())
        }
        val credential = settings.credential ?: return meta.copy(externalRatings = emptyList())

        val imdbId = extractImdbId(meta.id)
            ?: extractImdbId(fallbackItemId)
            // Upstream 90054b7b9: the addon's own IMDB id rates kitsu/mal/custom-id titles.
            ?: extractImdbId(meta.imdbId)
            ?: return meta.copy(externalRatings = emptyList())
        val mediaType = toMdbListMediaType(meta.type)
        val enabledProviders = settings.enabledProvidersInPriorityOrder()

        val ratings = ratingsRepository.getRatings(
            mediaType = mediaType,
            imdbId = imdbId,
            credential = credential,
            providers = enabledProviders,
        )

        return meta.copy(externalRatings = ratings)
    }

    fun clearCache() {
        ratingsRepository.clearCache()
    }

    private fun extractImdbId(value: String?): String? {
        if (value.isNullOrBlank()) return null
        return imdbRegex.find(value)?.value
    }

    private fun toMdbListMediaType(metaType: String): String {
        val normalized = metaType.trim().lowercase()
        return if (normalized == "movie") "movie" else "show"
    }
}
