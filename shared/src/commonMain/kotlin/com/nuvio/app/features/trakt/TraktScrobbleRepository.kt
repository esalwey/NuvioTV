package com.nuvio.app.features.trakt

import co.touchlab.kermit.Logger
import com.nuvio.app.core.build.AppVersionConfig
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.TrackingScrobbler
import com.nuvio.app.features.tracking.TrackingSeekScrobblePolicy
import com.nuvio.app.features.watchprogress.TrackerOptimisticFailedStopRetentionMs
import com.nuvio.app.features.watchprogress.TrackerOptimisticStopInFlightHoldMs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.math.abs

private const val BASE_URL = "https://api.trakt.tv"

sealed interface TraktScrobbleItem {
    val itemKey: String

    data class Movie(
        val title: String?,
        val year: Int?,
        val ids: TraktExternalIds,
    ) : TraktScrobbleItem {
        override val itemKey: String =
            "movie:${ids.imdb ?: ids.tmdb ?: ids.trakt ?: title.orEmpty()}:${year ?: 0}"
    }

    data class Episode(
        val showTitle: String?,
        val showYear: Int?,
        val showIds: TraktExternalIds,
        val season: Int,
        val number: Int,
        val episodeTitle: String?,
    ) : TraktScrobbleItem {
        override val itemKey: String =
            "episode:${showIds.imdb ?: showIds.tmdb ?: showIds.trakt ?: showTitle.orEmpty()}:$season:$number"
    }
}

// Fork: public (upstream: internal) — shared tests consume these cross-module.
data class TraktEpisodeMappingInput(
    val contentId: String,
    val contentType: String,
    val videoId: String?,
    val season: Int,
    val episode: Int,
    val episodeTitle: String?,
)

fun TrackingMediaReference.toTraktEpisodeMappingInput(): TraktEpisodeMappingInput? {
    val episodeReference = episode ?: return null
    val season = episodeReference.season ?: return null
    val contentId = catalog?.contentId?.takeIf(String::isNotBlank)
        ?: ids.imdb?.takeIf(String::isNotBlank)
        ?: ids.tmdb?.let { value -> "tmdb:$value" }
        ?: ids.trakt?.let { value -> "trakt:$value" }
        ?: return null
    return TraktEpisodeMappingInput(
        contentId = contentId,
        contentType = catalog?.contentType?.takeIf(String::isNotBlank) ?: "series",
        videoId = catalog?.videoId?.takeIf(String::isNotBlank),
        season = season,
        episode = episodeReference.number,
        episodeTitle = episodeReference.title,
    )
}

object TraktScrobbleRepository : TrackingScrobbler {
    override val providerId: TrackingProviderId = TrackingProviderId.TRAKT
    override val seekScrobblePolicy: TrackingSeekScrobblePolicy =
        TrackingSeekScrobblePolicy.STOP_AND_RESTART

    private data class ScrobbleStamp(
        val profileId: Int,
        val action: String,
        val itemKey: String,
        val progress: Float,
        val timestampMs: Long,
    )

    private val log = Logger.withTag("TraktScrobble")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        explicitNulls = false
    }

    private var lastScrobbleStamp: ScrobbleStamp? = null
    private val minSendIntervalMs = 8_000L
    private val progressWindow = 1.5f
    private val maxStopRetries = 2
    private val retryDelayMs = 1_500L
    private val serverOverloadedRetryDelayMs = 5_000L

    init {
        TrackingProviderRegistry.registerScrobbler(this)
    }

    /** Forces this object's initializer (and therefore its registry registration) to run. */
    fun ensureRegistered() = Unit

    /**
     * Provider-neutral scrobble entry point used by [TrackingScrobbleCoordinator].
     *
     * The tvOS players call [scrobbleStart]/[scrobbleStop] directly. The coordinator's live path,
     * `TrackingScrobbleCoordinator.scrobbleOtherTrackers` (Simkl), deliberately skips Trakt
     * (`DirectPathScrobbleProviderIds`), so this override is only reached through
     * `TrackingScrobbleCoordinator.scrobble`, which nothing on tvOS calls. Both funnel into the same
     * [sendScrobble] dedupe/retry machinery.
     */
    override suspend fun scrobble(
        profileId: Int,
        action: TrackingScrobbleAction,
        event: TrackingScrobbleEvent,
    ) {
        val item = buildItem(event.media) ?: return
        sendScrobble(
            profileId = profileId,
            action = action.wireValue,
            item = item,
            progressPercent = event.progressPercent.toFloat(),
        )
    }

    private suspend fun buildItem(media: TrackingMediaReference): TraktScrobbleItem? {
        val ids = TraktExternalIds(
            trakt = media.ids.trakt?.toTraktIntOrNull(),
            imdb = media.ids.imdb?.takeIf(String::isNotBlank),
            tmdb = media.ids.tmdb?.toTraktIntOrNull(),
        )
        if (!ids.hasAnyId()) return null
        if (media.kind == TrackingMediaKind.MOVIE) {
            return TraktScrobbleItem.Movie(
                title = media.title,
                year = media.year,
                ids = ids,
            )
        }

        val mappingInput = media.toTraktEpisodeMappingInput() ?: return null
        val mappedEpisode = TraktEpisodeMappingService.resolveEpisodeMapping(
            contentId = mappingInput.contentId,
            contentType = mappingInput.contentType,
            videoId = mappingInput.videoId,
            season = mappingInput.season,
            episode = mappingInput.episode,
            episodeTitle = mappingInput.episodeTitle,
        )
        return TraktScrobbleItem.Episode(
            showTitle = media.title,
            showYear = media.year,
            showIds = ids,
            season = mappedEpisode?.season ?: mappingInput.season,
            number = mappedEpisode?.episode ?: mappingInput.episode,
            episodeTitle = mappingInput.episodeTitle,
        )
    }

    /** Called from Swift: nothing but cancellation may escape (it would abort the app). */
    suspend fun scrobbleStart(profileId: Int, item: TraktScrobbleItem, progressPercent: Float) {
        try {
            sendScrobble(profileId = profileId, action = "start", item = item, progressPercent = progressPercent)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Trakt scrobble start failed for ${item.itemKey}" }
        }
    }

    /** Called from Swift: nothing but cancellation may escape (it would abort the app). */
    suspend fun scrobbleStop(profileId: Int, item: TraktScrobbleItem, progressPercent: Float) {
        try {
            sendScrobble(profileId = profileId, action = "stop", item = item, progressPercent = progressPercent)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            reportUndeliveredStop(item, progressPercent.coerceIn(0f, 100f), "error: ${error.message}", error)
        }
    }

    suspend fun buildItem(
        contentType: String,
        parentMetaId: String,
        videoId: String?,
        title: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeTitle: String?,
        releaseInfo: String? = null,
    ): TraktScrobbleItem? {
        val normalizedType = contentType.trim().lowercase()
        var ids = parseTraktContentIds(parentMetaId)

        // Fallback: if parentMetaId doesn't resolve to valid Trakt IDs, try videoId.
        // Some addons use non-standard contentId (e.g. "tun_tt7821582") but set a
        // valid IMDB/TMDB videoId (e.g. "tt7821582:3:7").
        if (!ids.hasAnyId() && !videoId.isNullOrBlank() && videoId != parentMetaId) {
            ids = parseTraktContentIds(videoId)
        }

        // Don't send scrobble if we still have no valid Trakt IDs — would cause
        // title-based fuzzy match on Trakt API resulting in wrong show matched.
        if (!ids.hasAnyId()) return null

        val parsedYear = extractTraktYear(releaseInfo)

        return if (
            normalizedType in listOf("series", "tv", "show", "tvshow") &&
            seasonNumber != null &&
            episodeNumber != null
        ) {
            val mappedEpisode = TraktEpisodeMappingService.resolveEpisodeMapping(
                contentId = parentMetaId,
                contentType = contentType,
                videoId = videoId,
                season = seasonNumber,
                episode = episodeNumber,
                episodeTitle = episodeTitle,
            )
            TraktScrobbleItem.Episode(
                showTitle = title,
                showYear = parsedYear,
                showIds = ids,
                season = mappedEpisode?.season ?: seasonNumber,
                number = mappedEpisode?.episode ?: episodeNumber,
                episodeTitle = episodeTitle,
            )
        } else {
            TraktScrobbleItem.Movie(
                title = title,
                year = parsedYear,
                ids = ids,
            )
        }
    }

    private suspend fun sendScrobble(
        profileId: Int,
        action: String,
        item: TraktScrobbleItem,
        progressPercent: Float,
    ) {
        if (ActiveProfileProvider.activeProfileId != profileId) return
        val clampedProgress = progressPercent.coerceIn(0f, 100f)
        // The same scrobble reached Trakt moments ago: nothing to send, and nothing to hold.
        if (shouldSkip(profileId, action, item.itemKey, clampedProgress)) return
        val isStop = action == "stop"
        // CW sync #4: the title's optimistic rows outlive this stop's retries and timeouts, so a
        // stop that fails slowly still finds them to keep (reportUndeliveredStop). A delivered stop
        // releases exactly this hold again.
        val heldUntilEpochMs = TraktPlatformClock.nowEpochMs() + TrackerOptimisticStopInFlightHoldMs
        if (isStop) {
            TraktProgressRepository.holdOptimisticProgress(item = item, untilEpochMs = heldUntilEpochMs)
        }
        val headers = TraktAuthRepository.authorizedHeaders() ?: run {
            // Disconnected: nothing to report. Connected without a usable token (the refresh
            // failed): the stop is lost like any failed one.
            if (isStop && TraktAuthRepository.isAuthenticated.value) {
                reportUndeliveredStop(item, clampedProgress, "no usable Trakt token (the refresh failed)")
            }
            return
        }
        if (ActiveProfileProvider.activeProfileId != profileId) return

        val url = "$BASE_URL/scrobble/$action"
        val requestBody = json.encodeToString(buildRequestBody(item, clampedProgress))
        val requestHeaders = mapOf(
            "Accept" to "application/json",
            "Content-Type" to "application/json",
        ) + headers

        log.d {
            buildString {
                append("Trakt scrobble ")
                append(action)
                append(" request")
                append('\n')
                append("url=")
                append(url)
                append('\n')
                append("headers=")
                append(requestHeaders.redactedForLogs().formatForLog())
                append('\n')
                append("body=")
                append(requestBody.ifBlank { "<empty>" })
            }
        }

        val attempts = if (action == "stop") maxStopRetries + 1 else 1
        var wasSent = false
        for (attempt in 1..attempts) {
            val response = runCatching {
                httpRequestRaw(
                    method = "POST",
                    url = url,
                    body = requestBody,
                    headers = requestHeaders,
                )
            }.onFailure { error ->
                if (error is CancellationException) throw error
                log.w(error) {
                    "Trakt scrobble $action transport failure on attempt $attempt/$attempts"
                }
            }.getOrNull()

            if (response == null) {
                if (attempt < attempts) {
                    delay(retryDelayMs * attempt)
                    continue
                }
                if (isStop) reportUndeliveredStop(item, clampedProgress, "transport failure after $attempts attempts")
                return
            }

            log.d {
                buildString {
                    append("Trakt scrobble ")
                    append(action)
                    append(" response")
                    append('\n')
                    append("status=")
                    append(response.status)
                    append(' ')
                    append(response.statusText.ifBlank { "<no-status-text>" })
                    append('\n')
                    append("url=")
                    append(response.url)
                    append('\n')
                    append("headers=")
                    append(response.headers.formatForLog())
                    append('\n')
                    append("body=")
                    append(response.body.ifBlank { "<empty>" })
                }
            }

            if (response.status in 200..299 || response.status == 409) {
                wasSent = true
                break
            }

            if (response.status in 500..599 && attempt < attempts) {
                val delayMs = if (response.status in 502..504) serverOverloadedRetryDelayMs else retryDelayMs * attempt
                delay(delayMs)
                continue
            }

            log.w {
                "Failed Trakt scrobble $action: HTTP ${response.status} ${response.statusText.ifBlank { "<no-status-text>" }}"
            }
            if (isStop) reportUndeliveredStop(item, clampedProgress, "HTTP ${response.status}")
            return
        }

        if (!wasSent) return

        lastScrobbleStamp = ScrobbleStamp(
            profileId = profileId,
            action = action,
            itemKey = item.itemKey,
            progress = clampedProgress,
            timestampMs = TraktPlatformClock.nowEpochMs(),
        )

        if (action == "stop") {
            // Delivered: the in-flight hold above is released (CW sync #4).
            TraktProgressRepository.releaseOptimisticProgressHold(item = item, heldUntilEpochMs = heldUntilEpochMs)
            runCatching { TraktProgressRepository.invalidateAndRefresh() }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    log.w { "Failed to refresh Trakt progress after stop: ${error.message}" }
                }
        }
    }

    /**
     * CW sync #4: a scrobble stop that never reached Trakt. Trakt does not know about this viewing —
     * an autoplayed episode stays unwatched there and its playback row stays wherever it was — so
     * with Trakt as the Watch Progress Source, Continue Watching would silently go back to that state
     * once the title's optimistic rows expire. They are kept for up to a day instead
     * ([TraktProgressRepository.holdOptimisticProgress]; a Trakt snapshot that confirms or supersedes
     * them still wins), and the loss is logged as an error with what Home keeps.
     */
    private fun reportUndeliveredStop(
        item: TraktScrobbleItem,
        progressPercent: Float,
        reason: String,
        cause: Throwable? = null,
    ) {
        val kept = runCatching {
            TraktProgressRepository.holdOptimisticProgress(
                item = item,
                untilEpochMs = TraktPlatformClock.nowEpochMs() + TrackerOptimisticFailedStopRetentionMs,
            )
        }.getOrDefault(0)
        log.e(cause) {
            val consequence = if (kept > 0) {
                "Continue Watching keeps its $kept local row(s) for up to 24 h, until Trakt confirms or " +
                    "supersedes them"
            } else {
                "no local row of it is on Continue Watching (Trakt is not the Watch Progress Source, " +
                    "or the rows expired)"
            }
            "Trakt scrobble stop NOT delivered for ${item.itemKey} at $progressPercent% ($reason): Trakt did " +
                "not record this viewing; $consequence"
        }
    }

    private fun buildRequestBody(
        item: TraktScrobbleItem,
        clampedProgress: Float,
    ): TraktScrobbleRequest {
        return when (item) {
            is TraktScrobbleItem.Movie -> TraktScrobbleRequest(
                movie = TraktMovieBody(
                    title = item.title,
                    year = item.year,
                    ids = item.ids.toRequestBodyOrNull(),
                ),
                progress = clampedProgress,
                appVersion = AppVersionConfig.VERSION_NAME,
            )

            is TraktScrobbleItem.Episode -> TraktScrobbleRequest(
                show = TraktShowBody(
                    title = item.showTitle,
                    year = item.showYear,
                    ids = item.showIds.toRequestBodyOrNull(),
                ),
                episode = TraktEpisodeBody(
                    title = item.episodeTitle,
                    season = item.season,
                    number = item.number,
                ),
                progress = clampedProgress,
                appVersion = AppVersionConfig.VERSION_NAME,
            )
        }
    }

    private fun shouldSkip(profileId: Int, action: String, itemKey: String, progress: Float): Boolean {
        val last = lastScrobbleStamp ?: return false
        val now = TraktPlatformClock.nowEpochMs()
        val isSameWindow = now - last.timestampMs < minSendIntervalMs
        val isSameProfile = last.profileId == profileId
        val isSameAction = last.action == action
        val isSameItem = last.itemKey == itemKey
        val isNearProgress = abs(last.progress - progress) <= progressWindow
        if (action == "stop" && last.action == "start" && isSameItem && isSameProfile) {
            return false
        }
        return isSameWindow && isSameProfile && isSameAction && isSameItem && isNearProgress
    }

    private fun Map<String, String>.redactedForLogs(): Map<String, String> =
        entries.associate { (key, value) ->
            key to when {
                key.equals("authorization", ignoreCase = true) -> redactBearerValue(value)
                key.equals("trakt-api-key", ignoreCase = true) -> "<redacted>"
                else -> value
            }
        }

    private fun Map<String, String>.formatForLog(): String =
        entries
            .sortedBy { it.key.lowercase() }
            .joinToString(prefix = "{", postfix = "}") { (key, value) -> "$key=$value" }

    private fun redactBearerValue(value: String): String {
        val tokenPrefix = "Bearer "
        if (!value.startsWith(tokenPrefix, ignoreCase = true)) return "<redacted>"
        val token = value.removePrefix(tokenPrefix).trim()
        if (token.isBlank()) return "Bearer <redacted>"
        val prefix = token.take(6)
        val suffix = token.takeLast(4)
        return "Bearer ${prefix}...${suffix}"
    }

    private fun TraktExternalIds.toRequestBodyOrNull(): TraktIdsBody? {
        if (trakt == null && imdb.isNullOrBlank() && tmdb == null) return null
        return TraktIdsBody(
            trakt = trakt,
            imdb = imdb,
            tmdb = tmdb,
        )
    }
}

private fun Long.toTraktIntOrNull(): Int? = takeIf { value -> value in 1L..Int.MAX_VALUE.toLong() }?.toInt()

@Serializable
private data class TraktScrobbleRequest(
    @SerialName("movie") val movie: TraktMovieBody? = null,
    @SerialName("show") val show: TraktShowBody? = null,
    @SerialName("episode") val episode: TraktEpisodeBody? = null,
    @SerialName("progress") val progress: Float,
    @SerialName("app_version") val appVersion: String? = null,
)

@Serializable
private data class TraktMovieBody(
    @SerialName("title") val title: String? = null,
    @SerialName("year") val year: Int? = null,
    @SerialName("ids") val ids: TraktIdsBody? = null,
)

@Serializable
private data class TraktShowBody(
    @SerialName("title") val title: String? = null,
    @SerialName("year") val year: Int? = null,
    @SerialName("ids") val ids: TraktIdsBody? = null,
)

@Serializable
private data class TraktEpisodeBody(
    @SerialName("title") val title: String? = null,
    @SerialName("season") val season: Int? = null,
    @SerialName("number") val number: Int? = null,
)

@Serializable
private data class TraktIdsBody(
    @SerialName("trakt") val trakt: Int? = null,
    @SerialName("imdb") val imdb: String? = null,
    @SerialName("tmdb") val tmdb: Int? = null,
)
