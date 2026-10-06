package com.nuvio.app.features.player.skip

import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.player.PlayerSettingsRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

object SkipIntroRepository {

    private val cache = HashMap<String, List<SkipInterval>>()
    private val animeSkipShowIdCache = HashMap<String, String>()
    private const val NO_ID = "__none__"

    private val introDbConfigured: Boolean
        get() = IntroDbConfig.URL.isNotBlank()

    suspend fun getSkipIntervals(
        imdbId: String?,
        season: Int,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
    ): List<SkipInterval> = coroutineScope {
        if (imdbId == null) return@coroutineScope emptyList()
        val settings = PlayerSettingsRepository.uiState.value
        if (requireSkipIntroEnabled && !settings.skipIntroEnabled) return@coroutineScope emptyList()

        val cacheKey = "$imdbId:$season:$episode"
        cache[cacheKey]?.let { return@coroutineScope it }

        val introDbDeferred = async {
            if (introDbConfigured) fetchFromIntroDb(imdbId, season, episode) else emptyList()
        }
        // Season-aware (Codex r2, upstream aa748fa8b): an IMDb series spanning several anime seasons
        // resolves to the Simkl entry for THIS season, so AniSkip/Anime-Skip get the right MAL/AniList
        // ids.
        val simklIdsDeferred = async { SimklIdResolver.resolveIdsForImdbEpisode(imdbId, season, episode) }
        val simklIds = simklIdsDeferred.await()
        val malId = simklIds?.mal
        val anilistId = simklIds?.anilist
        // Upstream aa748fa8b: AniSkip / Anime-Skip index an entry's own episodes, so the TVDB episode
        // is remapped to the entry-local number. Fork: only fetched when an anime provider will be
        // asked, so a regular show costs no extra Simkl request.
        val animeEpisode = if (simklIds != null && (malId != null || anilistId != null)) {
            SimklIdResolver.getEpisodeMapping(simklIds.simklId, simklIds.type)
                .firstOrNull { it.tvdbSeason == season && it.tvdbEpisode == episode }
                ?.animeEpisode
                ?: episode
        } else {
            episode
        }
        val aniSkipDeferred = async {
            if (malId != null) fetchFromAniSkip(malId, animeEpisode) else emptyList()
        }
        val animeSkipDeferred = async {
            if (anilistId != null) fetchFromAnimeSkip(anilistId, animeEpisode, season = null) else emptyList()
        }

        return@coroutineScope mergeByPriority(
            introDbDeferred.await(),
            animeSkipDeferred.await(),
            aniSkipDeferred.await(),
        ).also { cache[cacheKey] = it }
    }

    suspend fun getSkipIntervalsForMal(
        malId: String,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
        imdbId: String? = null,
        imdbSeason: Int? = null,
        imdbEpisode: Int? = null,
        fallbackImdbId: String? = null,
    ): List<SkipInterval> = coroutineScope {
        val settings = PlayerSettingsRepository.uiState.value
        if (requireSkipIntroEnabled && !settings.skipIntroEnabled) return@coroutineScope emptyList()

        // Codex r1: the IMDB hint tuple changes which IntroDB coordinates are queried, so hinted and
        // unhinted lookups for the same episode must not share a cache slot (upstream shares it).
        val cacheKey = animeCacheKey("mal", malId, episode, imdbId, imdbSeason, imdbEpisode, fallbackImdbId)
        cache[cacheKey]?.let { return@coroutineScope it }

        val aniSkipDeferred = async { fetchFromAniSkip(malId, episode) }

        val simklIdsDeferred = async { SimklIdResolver.resolveIds("mal", malId) }
        val simklIds = simklIdsDeferred.await()
        // The addon's IMDB id only stands in when Simkl has none: Simkl's own id is the one its TVDB
        // episode mapping below is expressed in. It needs that mapping all the same: when Simkl
        // knows nothing of the entry, IntroDB is not asked. Upstream would query the franchise's
        // IMDB id at the entry's own season and episode, but a Kitsu/MAL entry numbers its episodes
        // from 1 in every season, so a later season would get the first season's segments, which
        // also time the Up Next card.
        val resolvedImdbId = imdbId ?: simklIds?.imdb ?: fallbackImdbId

        val anilistId = simklIds?.anilist
        val animeSkipDeferred = async {
            if (anilistId != null) fetchFromAnimeSkip(anilistId, episode, season = null) else emptyList()
        }

        // Only reach for Simkl's TVDB episode map when IntroDB will actually be queried and the
        // caller gave no season hint.
        val tvdbDeferred = async {
            if (introDbConfigured && resolvedImdbId != null && imdbSeason == null && simklIds != null) {
                SimklIdResolver.resolveEpisodeTvdb("mal", malId, episode)
            } else null
        }
        // Fork deviation from upstream f212242a (Codex r1): a missing TVDB mapping only removes the
        // IntroDB lookup — upstream returned early here and dropped the Anime-Skip result too.
        val introDbDeferred = async {
            if (!introDbConfigured || resolvedImdbId == null) return@async emptyList()
            val tvdb = tvdbDeferred.await()
            val introDbSeason = imdbSeason ?: tvdb?.first ?: return@async emptyList()
            val introDbEpisode = imdbEpisode ?: tvdb?.second ?: episode
            fetchFromIntroDb(resolvedImdbId, introDbSeason, introDbEpisode)
        }

        return@coroutineScope mergeByPriority(
            introDbDeferred.await(),
            animeSkipDeferred.await(),
            aniSkipDeferred.await(),
        ).also { cache[cacheKey] = it }
    }

    suspend fun getSkipIntervalsForKitsu(
        kitsuId: String,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
        imdbId: String? = null,
        imdbSeason: Int? = null,
        imdbEpisode: Int? = null,
        fallbackImdbId: String? = null,
    ): List<SkipInterval> = coroutineScope {
        val settings = PlayerSettingsRepository.uiState.value
        if (requireSkipIntroEnabled && !settings.skipIntroEnabled) return@coroutineScope emptyList()

        // Codex r1: the IMDB hint tuple changes which IntroDB coordinates are queried, so hinted and
        // unhinted lookups for the same episode must not share a cache slot (upstream shares it).
        val cacheKey = animeCacheKey("kitsu", kitsuId, episode, imdbId, imdbSeason, imdbEpisode, fallbackImdbId)
        cache[cacheKey]?.let { return@coroutineScope it }

        val simklIdsDeferred = async { SimklIdResolver.resolveIds("kitsu", kitsuId) }
        val simklIds = simklIdsDeferred.await()
        val malIdStr = simklIds?.mal
        // The addon's IMDB id only stands in when Simkl has none, and only with Simkl's TVDB
        // mapping (see getSkipIntervalsForMal).
        val resolvedImdbId = imdbId ?: simklIds?.imdb ?: fallbackImdbId

        val aniSkipDeferred = async {
            if (malIdStr != null) fetchFromAniSkip(malIdStr, episode) else emptyList()
        }

        val anilistId = simklIds?.anilist
        val animeSkipDeferred = async {
            if (anilistId != null) fetchFromAnimeSkip(anilistId, episode, season = null) else emptyList()
        }

        // Only reach for Simkl's TVDB episode map when IntroDB will actually be queried and the
        // caller gave no season hint.
        val tvdbDeferred = async {
            if (introDbConfigured && resolvedImdbId != null && imdbSeason == null && simklIds != null) {
                SimklIdResolver.resolveEpisodeTvdb("kitsu", kitsuId, episode)
            } else null
        }
        // Fork deviation from upstream f212242a (Codex r1): a missing TVDB mapping only removes the
        // IntroDB lookup — upstream returned early here and dropped the Anime-Skip result too.
        val introDbDeferred = async {
            if (!introDbConfigured || resolvedImdbId == null) return@async emptyList()
            val tvdb = tvdbDeferred.await()
            val introDbSeason = imdbSeason ?: tvdb?.first ?: return@async emptyList()
            val introDbEpisode = imdbEpisode ?: tvdb?.second ?: episode
            fetchFromIntroDb(resolvedImdbId, introDbSeason, introDbEpisode)
        }

        return@coroutineScope mergeByPriority(
            introDbDeferred.await(),
            animeSkipDeferred.await(),
            aniSkipDeferred.await(),
        ).also { cache[cacheKey] = it }
    }

    /**
     * Route a content id to the right lookup. Anime served by a Kitsu/MAL-backed addon carries a
     * `kitsu:`/`mal:` id that the IMDB-mapped path can never resolve, so those go to the anime
     * providers directly; everything else keeps the IMDB behaviour.
     *
     * Mirrors mobile's routing in `PlayerScreenRuntimeEffects`. It lives here rather than in the
     * tvOS Swift callers so the prefix parsing exists once instead of once per player screen.
     *
     * `season` is IMDB-space and only used on the IMDB branch. The anime branches carry no IMDB id
     * to hint with, so they leave `getSkipIntervalsForMal`/`ForKitsu`'s `imdbId`/`imdbSeason`/
     * `imdbEpisode` at their defaults and let [SimklIdResolver.resolveEpisodeTvdb] map the anime
     * episode onto TVDB season/episode for IntroDB (upstream f212242a's behaviour for that case).
     * The Swift-facing signature is deliberately unchanged — adding parameters would rewrite the
     * exported ObjC selector both player screens call.
     */
    suspend fun getSkipIntervalsForContentId(
        contentId: String?,
        season: Int,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
    ): List<SkipInterval> {
        if (contentId == null) return emptyList()
        // Upstream 90054b7b9: the `imdb_id` the addon supplied for a kitsu/mal/custom-id title, read
        // from the loaded details so the Swift-facing signature stays unchanged.
        val addonImdbId = runCatching { MetaDetailsRepository.addonImdbId(contentId) }.getOrNull()
        return when {
            contentId.startsWith("mal:") -> getSkipIntervalsForMal(
                malId = contentId.removePrefix("mal:").substringBefore(':'),
                episode = episode,
                requireSkipIntroEnabled = requireSkipIntroEnabled,
                fallbackImdbId = addonImdbId,
            )
            contentId.startsWith("kitsu:") -> getSkipIntervalsForKitsu(
                kitsuId = contentId.removePrefix("kitsu:").substringBefore(':'),
                episode = episode,
                requireSkipIntroEnabled = requireSkipIntroEnabled,
                fallbackImdbId = addonImdbId,
            )
            else -> getSkipIntervals(
                imdbId = contentId.takeIf { it.startsWith("tt", ignoreCase = true) } ?: addonImdbId ?: contentId,
                season = season,
                episode = episode,
                requireSkipIntroEnabled = requireSkipIntroEnabled,
            )
        }
    }

    private fun animeCacheKey(
        source: String,
        id: String,
        episode: Int,
        imdbId: String?,
        imdbSeason: Int?,
        imdbEpisode: Int?,
        fallbackImdbId: String? = null,
    ): String = buildString {
        append(source).append(':').append(id).append(':').append(episode)
        if (imdbId != null || imdbSeason != null || imdbEpisode != null) {
            append(":hint:").append(imdbId ?: "").append(':').append(imdbSeason ?: "").append(':').append(imdbEpisode ?: "")
        }
        if (fallbackImdbId != null) append(":fallback:").append(fallbackImdbId)
    }

    /**
     * Merge provider results into one best-of: fill each segment category (opening / ending /
     * recap) from the highest-priority provider that has it. Arguments MUST be passed in priority
     * order (IntroDB has the broadest coverage, then Anime-Skip, then AniSkip), so a partial
     * result from one provider never shadows a complete segment from another.
     */
    private fun mergeByPriority(vararg providerResults: List<SkipInterval>): List<SkipInterval> {
        val chosen = LinkedHashMap<String, SkipInterval>()
        for (result in providerResults) {
            for (interval in result) {
                val category = segmentCategory(interval.type) ?: continue
                if (category !in chosen) chosen[category] = interval
            }
        }
        return chosen.values.toList()
    }

    private fun segmentCategory(type: String): String? = when (type.lowercase()) {
        "intro", "op", "mixed-op" -> "opening"
        "outro", "ed", "mixed-ed", "credits", "ending" -> "ending"
        "recap" -> "recap"
        else -> null
    }

    private suspend fun fetchFromIntroDb(imdbId: String, season: Int, episode: Int): List<SkipInterval> {
        return try {
            val data = SkipIntroApi.getIntroDbSegments(imdbId, season, episode)
            if (data == null) return emptyList()
            listOfNotNull(
                data.intro.toSkipIntervalOrNull("intro"),
                data.recap.toSkipIntervalOrNull("recap"),
                data.outro.toSkipIntervalOrNull("outro"),
            )
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun IntroDbSegment?.toSkipIntervalOrNull(type: String): SkipInterval? {
        if (this == null) return null
        val start = startSec ?: startMs?.let { it / 1000.0 }
        val end = endSec ?: endMs?.let { it / 1000.0 }
        if (start == null || end == null || end <= start) return null
        return SkipInterval(startTime = start, endTime = end, type = type, provider = "introdb")
    }

    private suspend fun fetchFromAniSkip(malId: String, episode: Int): List<SkipInterval> {
        return try {
            val response = SkipIntroApi.getAniSkipTimes(malId, episode)
            if (response == null) return emptyList()
            if (!response.found) return emptyList()
            response.results?.map { result ->
                SkipInterval(
                    startTime = result.interval.startTime,
                    endTime = result.interval.endTime,
                    type = result.skipType,
                    provider = "aniskip",
                )
            } ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun fetchFromAnimeSkip(anilistId: String, episode: Int, season: Int?): List<SkipInterval> {
        val settings = PlayerSettingsRepository.uiState.value
        val clientId = settings.animeSkipClientId.trim()
        if (clientId.isBlank()) return emptyList()
        if (!settings.animeSkipEnabled) return emptyList()

        return try {
            val showIds = resolveAnimeSkipShowIds(anilistId, clientId)
            if (showIds.isEmpty()) return emptyList()

            for (showId in showIds) {
                val query = "{ findEpisodesByShowId(showId: \"$showId\") { season number timestamps { at type { name } } } }"
                val response = SkipIntroApi.queryAnimeSkip(clientId, query) ?: continue
                val episodes = response.data?.findEpisodesByShowId ?: continue

                val targetEpisode = episodes.firstOrNull { ep ->
                    ep.number?.toIntOrNull() == episode &&
                        (season == null || ep.season?.toIntOrNull() == season)
                } ?: continue

                val sorted = (targetEpisode.timestamps ?: continue).sortedBy { it.at }
                val result = sorted.mapIndexedNotNull { i, ts ->
                    val endTime = sorted.getOrNull(i + 1)?.at ?: Double.MAX_VALUE
                    val type = when (ts.type.name.lowercase()) {
                        "intro", "new intro" -> "op"
                        "credits" -> "ed"
                        "recap" -> "recap"
                        else -> return@mapIndexedNotNull null
                    }
                    SkipInterval(startTime = ts.at, endTime = endTime, type = type, provider = "animeskip")
                }
                if (result.isNotEmpty()) return result
            }
            emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun resolveAnimeSkipShowIds(anilistId: String, clientId: String): List<String> {
        animeSkipShowIdCache[anilistId]?.let { cached ->
            return if (cached == NO_ID) emptyList() else listOf(cached)
        }
        val query = "{ findShowsByExternalId(service: ANILIST, serviceId: \"$anilistId\") { id } }"
        val showIds = try {
            SkipIntroApi.queryAnimeSkip(clientId, query)
                ?.data?.findShowsByExternalId?.map { it.id } ?: emptyList()
        } catch (_: Exception) { emptyList() }

        if (showIds.size == 1) animeSkipShowIdCache[anilistId] = showIds[0]
        else if (showIds.isEmpty()) animeSkipShowIdCache[anilistId] = NO_ID
        return showIds
    }

    suspend fun submitIntro(
        imdbId: String,
        season: Int,
        episode: Int,
        startSec: Double,
        endSec: Double,
        segmentType: String,
    ): Boolean {
        val settings = PlayerSettingsRepository.uiState.value
        val apiKey = settings.introDbApiKey.trim()
        if (!settings.introSubmitEnabled || apiKey.isBlank()) return false

        val request = SubmitIntroRequest(
            imdbId = imdbId,
            season = season,
            episode = episode,
            startSec = startSec,
            endSec = endSec,
            startMs = (startSec * 1000).toLong(),
            endMs = (endSec * 1000).toLong(),
            segmentType = segmentType,
        )

        return SkipIntroApi.submitIntro(apiKey, request)
    }

    suspend fun verifyIntroDbApiKey(apiKey: String): Boolean {
        return SkipIntroApi.verifyIntroDbApiKey(apiKey)
    }

    fun clearCache() {
        cache.clear()
        animeSkipShowIdCache.clear()
        SimklIdResolver.clearCache()
    }
}
