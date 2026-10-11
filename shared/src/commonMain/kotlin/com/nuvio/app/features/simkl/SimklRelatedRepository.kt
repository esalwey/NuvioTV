package com.nuvio.app.features.simkl

import co.touchlab.kermit.Logger
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.PosterShape
import com.nuvio.app.features.player.skip.SimklIdResolver
import com.nuvio.app.features.tracking.TrackingSettingsRepository
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private const val RELATED_LIMIT = 20
private const val RELATED_CACHE_TTL_MS = 10 * 60_000L

private val SIMKL_REDIRECT_SOURCES = setOf(
    "tmdb", "tvdb", "mal", "anidb", "anilist", "kitsu", "simkl", "imdb",
)

@Serializable
internal data class SimklRelatedItemDto(
    @SerialName("title") val title: String? = null,
    @SerialName("en_title") val enTitle: String? = null,
    @SerialName("year") val year: Int? = null,
    @SerialName("poster") val poster: String? = null,
    @SerialName("fanart") val fanart: String? = null,
    @SerialName("type") val type: String? = null,
    @SerialName("anime_type") val animeType: String? = null,
    @SerialName("ids") val ids: SimklRelatedIdsDto? = null,
)

@Serializable
internal data class SimklRelatedIdsDto(
    @SerialName("simkl") val simkl: Long? = null,
    @SerialName("slug") val slug: String? = null,
    @SerialName("imdb") val imdb: String? = null,
    @SerialName("tmdb") val tmdb: String? = null,
    @SerialName("tvdb") val tvdb: String? = null,
    @SerialName("mal") val mal: String? = null,
    @SerialName("anidb") val anidb: String? = null,
    @SerialName("anilist") val anilist: String? = null,
    @SerialName("kitsu") val kitsu: String? = null,
)

@Serializable
internal data class SimklRelatedDetailDto(
    @SerialName("similar") val similar: List<SimklRelatedItemDto>? = null,
    @SerialName("users_recommendations") val usersRecommendations: List<SimklRelatedItemDto>? = null,
)

/**
 * Simkl as a "More Like This" source (port of upstream af1298eb4 / 1b2f7a99b / 317bf2dcc): the
 * title's Simkl detail page lists user recommendations and similar titles, mapped here to
 * [MetaPreview]s keyed by the best id the app can open (IMDb first, anime ids per the user's
 * anime-id preference).
 */
object SimklRelatedRepository {
    private val log = Logger.withTag("SimklRelated")
    private val json = Json { ignoreUnknownKeys = true }
    private val cache = mutableMapOf<String, TimedCache>()

    suspend fun getRelated(
        meta: MetaDetails,
        fallbackItemId: String? = null,
        fallbackItemType: String? = null,
        forceRefresh: Boolean = false,
    ): List<MetaPreview> {
        val (source, id) = parseSimklRedirectParam(meta.id)
            ?: meta.imdbId?.takeIf(String::isNotBlank)?.let { "imdb" to it }
            ?: parseSimklRedirectParam(fallbackItemId)
            ?: return emptyList()

        val contentTypeHint = meta.type.takeIf { it.isNotBlank() } ?: fallbackItemType
        val resolved = SimklIdResolver.resolveIds(
            source = source,
            id = id,
            contentTypeHint = contentTypeHint,
        ) ?: return emptyList()
        val cacheKey = "${resolved.type}|${resolved.simklId}"

        if (!forceRefresh) {
            cache[cacheKey]?.let { cached ->
                if (currentTimeMs() - cached.updatedAtMs <= RELATED_CACHE_TTL_MS) return cached.items
            }
        } else {
            cache.remove(cacheKey)
        }

        val detail = fetchDetail(resolved.type, resolved.simklId) ?: return emptyList()
        val items = mapRelatedItems(
            detail = detail,
            animeIdPreference = TrackingSettingsRepository.uiState.value.simklAnimeIdPreference,
        )
        cache[cacheKey] = TimedCache(items, currentTimeMs())
        return items
    }

    fun clearCache() {
        cache.clear()
    }

    private suspend fun fetchDetail(type: String, simklId: Long): SimklRelatedDetailDto? = try {
        val response = SimklApi.client.execute(
            SimklApiRequest(
                method = SimklHttpMethod.GET,
                path = "/$type/$simklId",
                requiresAuthentication = false,
                retryPolicy = SimklRetryPolicy.TRANSIENT_FAILURES,
            ),
        )
        if (response.status in 200..299) json.decodeFromString<SimklRelatedDetailDto>(response.body) else null
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        log.w { "Failed to fetch Simkl detail $type/$simklId: ${e.message}" }
        null
    }

    private data class TimedCache(val items: List<MetaPreview>, val updatedAtMs: Long)

    private fun currentTimeMs(): Long = SimklPlatformClock.nowEpochMs()
}

/** User recommendations first, then similar titles not already listed, capped and de-duplicated. */
internal fun mapRelatedItems(
    detail: SimklRelatedDetailDto,
    animeIdPreference: SimklAnimeIdPreference,
): List<MetaPreview> {
    val rawItems = buildList {
        detail.usersRecommendations.orEmpty().forEach { add(it) }
        detail.similar.orEmpty().forEach { item ->
            if (none { existing -> existing.ids?.simkl == item.ids?.simkl }) add(item)
        }
    }.take(RELATED_LIMIT)

    return rawItems
        .mapNotNull { simklRelatedItemToMetaPreview(it, animeIdPreference) }
        .distinctBy { "${it.type}:${it.id}" }
}

internal fun simklRelatedItemToMetaPreview(
    item: SimklRelatedItemDto,
    animeIdPreference: SimklAnimeIdPreference,
): MetaPreview? {
    val title = item.enTitle?.takeIf(String::isNotBlank)
        ?: item.title?.takeIf(String::isNotBlank)
        ?: return null
    val contentId = resolveSimklRelatedContentId(item.ids, item.type, animeIdPreference) ?: return null
    val year = item.year ?: return null

    return MetaPreview(
        id = contentId,
        type = resolveSimklRelatedContentType(item.type, item.animeType),
        name = title,
        poster = simklPosterUrl(item.poster),
        // Landscape banner (upstream 1b2f7a99b): the fanart, else the poster cropped wide.
        banner = simklFanartUrl(item.fanart) ?: simklPosterLandscapeUrl(item.poster),
        posterShape = PosterShape.Poster,
        description = null,
        releaseInfo = year.toString(),
        imdbRating = null,
        genres = emptyList(),
    )
}

/** `tt123` -> imdb; `tmdb:603` / `mal:5114` -> that source; anything else -> null. */
internal fun parseSimklRedirectParam(contentId: String?): Pair<String, String>? {
    val raw = contentId?.trim()?.takeIf(String::isNotBlank) ?: return null
    if (raw.startsWith("tt")) return "imdb" to raw.substringBefore(':')
    val colon = raw.indexOf(':')
    if (colon <= 0) return null
    val prefix = raw.substring(0, colon).lowercase()
    val value = raw.substring(colon + 1).takeIf(String::isNotBlank) ?: return null
    return if (prefix in SIMKL_REDIRECT_SOURCES) prefix to value else null
}

internal fun resolveSimklRelatedContentType(type: String?, animeType: String?): String =
    when (type?.trim()?.lowercase()) {
        "movie" -> "movie"
        else -> if (animeType == "movie") "movie" else "series"
    }

internal fun resolveSimklRelatedContentId(
    ids: SimklRelatedIdsDto?,
    type: String?,
    animeIdPreference: SimklAnimeIdPreference,
): String? {
    if (ids == null) return null
    if (type?.trim()?.lowercase() == "anime") {
        when (animeIdPreference) {
            SimklAnimeIdPreference.MAL -> {
                ids.mal?.takeIf(String::isNotBlank)?.let { return "mal:$it" }
                ids.kitsu?.takeIf(String::isNotBlank)?.let { return "kitsu:$it" }
                ids.anidb?.takeIf(String::isNotBlank)?.let { return "anidb:$it" }
            }
            SimklAnimeIdPreference.KITSU -> {
                ids.kitsu?.takeIf(String::isNotBlank)?.let { return "kitsu:$it" }
                ids.mal?.takeIf(String::isNotBlank)?.let { return "mal:$it" }
                ids.anidb?.takeIf(String::isNotBlank)?.let { return "anidb:$it" }
            }
            SimklAnimeIdPreference.TVDB -> ids.tvdb?.takeIf(String::isNotBlank)?.let { return "tvdb:$it" }
            SimklAnimeIdPreference.IMDB -> Unit
        }
    }
    return when {
        !ids.imdb.isNullOrBlank() -> ids.imdb
        !ids.tmdb.isNullOrBlank() -> "tmdb:${ids.tmdb}"
        !ids.tvdb.isNullOrBlank() -> "tvdb:${ids.tvdb}"
        !ids.mal.isNullOrBlank() -> "mal:${ids.mal}"
        !ids.anilist.isNullOrBlank() -> "anilist:${ids.anilist}"
        !ids.kitsu.isNullOrBlank() -> "kitsu:${ids.kitsu}"
        !ids.anidb.isNullOrBlank() -> "anidb:${ids.anidb}"
        ids.simkl != null -> "simkl:${ids.simkl}"
        else -> null
    }
}

private fun simklFanartUrl(path: String?): String? = path?.trim()?.trim('/')
    ?.takeIf(String::isNotBlank)
    ?.let { "https://wsrv.nl/?url=https://simkl.in/fanart/${it}_w.webp&q=90" }

private fun simklPosterLandscapeUrl(path: String?): String? = path?.trim()?.trim('/')
    ?.takeIf(String::isNotBlank)
    ?.let { "https://wsrv.nl/?url=https://simkl.in/posters/${it}_w.webp&q=90" }
