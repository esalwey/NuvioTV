package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.plugins.PluginRepositoryItem
import com.nuvio.app.features.plugins.PluginRuntimeResult
import com.nuvio.app.features.plugins.PluginScraper
import kotlinx.coroutines.CancellationException
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

data class InstalledStreamAddonTarget(
    val addonName: String,
    val addonId: String,
    val manifest: AddonManifest,
    /**
     * BUG-74: the id to request from THIS addon, which is not always the id the caller asked with.
     * A `tmdb:`-namespaced request is served to `tt`-only addons under the remapped IMDb id, while
     * an addon that declares a `tmdb` prefix (or declares none at all, and so accepts anything)
     * still gets the original. Per-addon rather than one rewritten id for the whole fan-out,
     * because both kinds are routinely installed side by side — see [StreamVideoIdRemap].
     */
    val videoId: String,
)

/**
 * BUG-74 — the safety net for `tmdb:`-namespaced ids reaching a stream fetch.
 *
 * Stremio stream addons (Meteor, Torrentio and the rest of that class) declare
 * `idPrefixes: ["tt"]`. Both stream repositories filter every installed addon with
 * `resource.idPrefixes.any { videoId.startsWith(it) }`, so a `tmdb:`-prefixed id filters ALL of
 * them out at once and the fetch reports `NoCompatibleAddons` — indistinguishable, to the user,
 * from having installed no stream addons at all. That is the whole of BUG-74: a Vietnamese-metadata
 * reporter saw "no streams" on every title he opened from a TMDB-backed row, while the same titles
 * played fine on mobile.
 *
 * The real fix is at the call sites (`DetailView.streamVideoId` prefers the resolved meta's
 * canonical id over the catalog preview's). This exists because three id sources are NOT under a
 * call site's control:
 *  - Continue Watching entries, whose `videoId` is whatever was persisted when the title was played
 *    (including entries synced down from mobile);
 *  - Top Shelf / deep-link resume targets, same;
 *  - the race where Play is pressed before `MetaDetailsRepository` has resolved the meta, so the
 *    call site legitimately still holds the preview id.
 *
 * **Deliberate fork divergence.** Upstream's `composeApp` carries the identical defect (its
 * `StreamsRepository` filter is byte-for-byte ours) and no remap. Report it rather than letting the
 * two drift silently — same handling as the sync-reliability P1.
 */
object StreamVideoIdRemap {

    /**
     * The numeric TMDB id inside a `tmdb:`-prefixed video id, or null when [videoId] is not one.
     *
     * Mirrors `MetaRequestResolution.parseTmdbId` deliberately rather than importing it: that one
     * belongs to the details feature and is documented against the meta-lookup remap (BUG-7). Both
     * must keep accepting exactly the same shapes, so a change to either wants a look at the other.
     */
    fun parseTmdbId(videoId: String): Int? =
        videoId
            .takeIf { it.startsWith("tmdb:", ignoreCase = true) }
            ?.substringAfter(':')
            ?.substringBefore(':')
            ?.toIntOrNull()

    /**
     * Rebuilds [videoId] around [imdbId], preserving any episode coordinates.
     *
     * `tmdb:1399` -> `tt0944947`, and `tmdb:1399:1:5` -> `tt0944947:1:5` — the season/episode
     * suffix is what every stream addon keys an episode request on, so dropping it would trade one
     * empty stream list for another.
     */
    fun withImdbId(videoId: String, imdbId: String): String {
        val body = videoId.substringAfter(':')
        val suffix = body.substringAfter(':', missingDelimiterValue = "")
        return if (suffix.isEmpty()) imdbId else "$imdbId:$suffix"
    }

    /**
     * Whether an addon declaring [idPrefixes] will accept [videoId]. An empty list means the addon
     * declared no restriction and takes anything — that is the manifest convention, not a guess.
     */
    fun accepts(idPrefixes: List<String>, videoId: String): Boolean =
        idPrefixes.isEmpty() || idPrefixes.any { videoId.startsWith(it) }

    /**
     * Whether resolving [videoId] to an IMDb id could reach an addon the original cannot.
     *
     * The measured shape this exists for: a real profile with 11 addons installed, asked for
     * `tmdb:550`, matched exactly ONE — the single addon that declares no id prefixes. The other
     * ten were dropped in silence. Because only one still matched, a naive "retry when nothing
     * matched" net never fires, and the user simply gets a short stream list with no indication
     * that most of their sources were never asked. So the trigger is "some addon was excluded that
     * an IMDb id would reach", not "everything was excluded".
     */
    fun wouldReachMoreAddons(videoId: String, candidateIdPrefixes: List<List<String>>): Boolean {
        if (parseTmdbId(videoId) == null) return false
        // Any prefix list that rejects the tmdb id but accepts a `tt` one. The literal probe is
        // safe: `startsWith` is all `accepts` does, so any `tt`-shaped string answers identically.
        return candidateIdPrefixes.any { prefixes ->
            !accepts(prefixes, videoId) && accepts(prefixes, "tt0000000")
        }
    }
}

fun ManagedAddon.streamAddonInstanceId(manifestId: String): String =
    "addon:$manifestId:$manifestUrl"

data class PluginProviderGroup(
    val addonId: String,
    val addonName: String,
    val scrapers: List<PluginScraper>,
)

sealed interface StreamLoadCompletion {
    data class Addon(val group: AddonStreamGroup) : StreamLoadCompletion
    data class PluginScraper(
        val addonId: String,
        val streams: List<StreamItem>,
        val error: String?,
    ) : StreamLoadCompletion
}

fun List<PluginScraper>.toPluginProviderGroups(
    repositories: List<PluginRepositoryItem>,
    groupByRepository: Boolean,
): List<PluginProviderGroup> {
    if (!groupByRepository) {
        return map { scraper ->
            PluginProviderGroup(
                addonId = "plugin:${scraper.id}",
                addonName = scraper.name,
                scrapers = listOf(scraper),
            )
        }
    }

    val repoNameByUrl = repositories.associate { it.manifestUrl to it.name }
    return groupBy { it.repositoryUrl }
        .map { (repositoryUrl, scrapers) ->
            PluginProviderGroup(
                addonId = "plugin-repo:${repositoryUrl.lowercase()}",
                addonName = repoNameByUrl[repositoryUrl].orEmpty().ifBlank { repositoryUrl.fallbackRepositoryLabel() },
                scrapers = scrapers.sortedBy { it.name.lowercase() },
            )
        }
        .sortedBy { it.addonName.lowercase() }
}

fun List<AddonStreamGroup>.toEmptyStateReason(anyLoading: Boolean): StreamsEmptyStateReason? {
    if (anyLoading || any { it.streams.isNotEmpty() }) {
        return null
    }

    return if (isNotEmpty() && all { !it.error.isNullOrBlank() }) {
        StreamsEmptyStateReason.StreamFetchFailed
    } else {
        StreamsEmptyStateReason.NoStreamsFound
    }
}

suspend fun <T> runCatchingUnlessCancelled(block: suspend () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        Result.failure(error)
    }

fun PluginRuntimeResult.toStreamItem(
    scraper: PluginScraper,
    addonName: String = scraper.name,
    addonId: String = "plugin:${scraper.id}",
    includeScraperNameInSubtitle: Boolean = false,
): StreamItem {
    val subtitleParts = listOfNotNull(
        scraper.name.takeIf { includeScraperNameInSubtitle && it.isNotBlank() },
        quality?.takeIf { it.isNotBlank() },
        size?.takeIf { it.isNotBlank() },
        language?.takeIf { it.isNotBlank() },
    )
    val requestHeaders = headers
        .orEmpty()
        .mapNotNull { (key, value) ->
            val headerName = key.trim()
            val headerValue = value.trim()
            if (headerName.isBlank() || headerValue.isBlank() || headerName.equals("Range", ignoreCase = true)) {
                null
            } else {
                headerName to headerValue
            }
        }
        .toMap()

    return StreamItem(
        name = name ?: title,
        description = subtitleParts.joinToString(" • ").ifBlank { null },
        url = url,
        infoHash = infoHash,
        sourceName = scraper.name,
        addonName = addonName,
        addonId = addonId,
        streamType = normalizeStreamType(type),
        behaviorHints = if (requestHeaders.isEmpty()) {
            StreamBehaviorHints()
        } else {
            StreamBehaviorHints(
                notWebReady = true,
                proxyHeaders = StreamProxyHeaders(request = requestHeaders),
            )
        },
        externalSubtitles = subtitles?.map {
            StreamSubtitle(
                url = it.url,
                language = it.language,
                name = it.name,
                headers = it.headers
            )
        } ?: emptyList()
    )
}

fun List<StreamItem>.sortedForGroupedDisplay(): List<StreamItem> =
    sortedWith(
        compareBy<StreamItem>(
            { it.sourceName.orEmpty().lowercase() },
            { it.streamLabel.lowercase() },
            { it.streamSubtitle.orEmpty().lowercase() },
        ),
    )

private fun String.fallbackRepositoryLabel(): String {
    val withoutQuery = substringBefore("?")
    val withoutManifest = withoutQuery.removeSuffix("/manifest.json")
    val host = withoutManifest.substringAfter("://", withoutManifest).substringBefore('/')
    return host.ifBlank {
        withoutManifest.substringAfterLast('/').ifBlank {
            resourceString("Plugin repository", StringKey.streams_plugin_repository_fallback)
        }
    }
}
