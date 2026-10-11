package com.nuvio.app.features.mdblist

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.httpPostJson
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaExternalRating
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

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

    private val log = Logger.withTag("MdbListMetadata")
    private val json = Json { ignoreUnknownKeys = true }
    private val ratingsCache = mutableMapOf<String, List<MetaExternalRating>>()
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

        val ratings = fetchRatings(
            imdbId = imdbId,
            mediaType = mediaType,
            credential = credential,
            providers = enabledProviders,
        )

        return meta.copy(externalRatings = ratings)
    }

    fun clearCache() {
        ratingsCache.clear()
    }

    private suspend fun fetchRatings(
        imdbId: String,
        mediaType: String,
        credential: MdbListRatingsCredential,
        providers: List<String>,
    ): List<MetaExternalRating> = withContext(Dispatchers.Default) {
        val cacheKey = "$mediaType:$imdbId:${credential.cacheId}:${providers.joinToString(",")}"
        ratingsCache[cacheKey]?.let { return@withContext it }

        val ratings = coroutineScope {
            providers.map { providerId ->
                async {
                    fetchProviderRating(
                        imdbId = imdbId,
                        mediaType = mediaType,
                        providerId = providerId,
                        credential = credential,
                    )
                }
            }.awaitAll().filterNotNull()
        }

        ratingsCache[cacheKey] = ratings
        ratings
    }

    private suspend fun fetchProviderRating(
        imdbId: String,
        mediaType: String,
        providerId: String,
        credential: MdbListRatingsCredential,
    ): MetaExternalRating? {
        val requestBody = json.encodeToString(
            RatingRequest(
                ids = listOf(imdbId),
                provider = PROVIDER_IMDB,
            ),
        )

        return runCatching {
            val payload = when (credential) {
                is MdbListRatingsCredential.ApiKey -> httpPostJson(
                    url = "https://api.mdblist.com/rating/$mediaType/$providerId?apikey=${credential.value}",
                    body = requestBody,
                )
                // The connected account is the default; a typed API key (above) overrides it.
                is MdbListRatingsCredential.Account -> MdbListTracker.api.post(
                    path = "/rating/$mediaType/$providerId",
                    body = requestBody,
                    scope = credential.scope,
                ).body
            }
            val parsed = json.decodeFromString<RatingResponse>(payload)
            val rating = parsed.ratings.firstOrNull()?.rating ?: return@runCatching null
            MetaExternalRating(source = providerId, value = rating)
        }.onFailure { error ->
            // An account switch cancels the request without cancelling this coroutine: that is
            // "no ratings", not a cancellation of the caller.
            if (error is CancellationException) currentCoroutineContext().ensureActive()
            log.w { "MDBList request failed for $providerId/$imdbId: ${error.message}" }
        }.getOrNull()
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

@Serializable
private data class RatingRequest(
    val ids: List<String>,
    val provider: String,
)

@Serializable
private data class RatingResponse(
    val ratings: List<RatingItem> = emptyList(),
)

@Serializable
private data class RatingItem(
    val rating: Double? = null,
)
