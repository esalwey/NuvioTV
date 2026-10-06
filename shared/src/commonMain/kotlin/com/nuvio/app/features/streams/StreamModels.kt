package com.nuvio.app.features.streams

import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import kotlinx.serialization.Serializable

@Serializable
data class StreamSubtitle(
    val url: String,
    val language: String,
    val name: String? = null,
    val headers: Map<String, String>? = null
)

data class StreamItem(
    val name: String? = null,
    val title: String? = null,
    val description: String? = null,
    val url: String? = null,
    val infoHash: String? = null,
    val fileIdx: Int? = null,
    val externalUrl: String? = null,
    val sources: List<String> = emptyList(),
    val sourceName: String? = null,
    val addonName: String,
    val addonId: String,
    val addonLogo: String? = null,
    val streamType: String? = null,
    val behaviorHints: StreamBehaviorHints = StreamBehaviorHints(),
    val clientResolve: StreamClientResolve? = null,
    val debridCacheStatus: StreamDebridCacheStatus? = null,
    val externalSubtitles: List<StreamSubtitle> = emptyList(),
    val badges: List<StreamBadge> = emptyList(),
) {
    val streamLabel: String
        get() = name ?: resourceString("Stream", StringKey.stream_default_name)

    val streamSubtitle: String?
        get() = description

    val directPlaybackUrl: String?
        get() = url?.trim()?.takeIf { it.isNotEmpty() }

    /**
     * First URL that can be handed directly to a player or HTTP consumer.
     * `magnet:` and `torrent://` URLs are filtered out. `externalUrl` is not
     * a media URL in the Stremio SDK contract and must be opened externally.
     */
    val playableDirectUrl: String?
        get() = directPlaybackUrl?.takeIf { !it.isMagnetLink() && !it.isTorrentSchemeUrl() }

    val externalOpenUrl: String?
        get() = externalUrl
            ?.trim()
            ?.takeIf { it.isNotEmpty() && !it.isMagnetLink() && !it.isTorrentSchemeUrl() }

    val shouldOpenExternally: Boolean
        get() = url.isNullOrBlank() &&
            infoHash.isNullOrBlank() &&
            clientResolve == null &&
            externalOpenUrl != null

    val torrentMagnetUri: String?
        get() = listOfNotNull(url, externalUrl)
            .firstOrNull { it.isMagnetLink() }

    val torrentSchemeUri: String?
        get() = listOfNotNull(url, externalUrl)
            .firstOrNull { it.isTorrentSchemeUrl() }

    val isDirectDebridStream: Boolean
        get() = clientResolve?.isDirectDebridCandidate == true

    val isInstalledAddonStream: Boolean
        get() = addonId.startsWith("addon:")

    val isTorrentStream: Boolean
        get() = !isDirectDebridStream && (
            !infoHash.isNullOrBlank() ||
            url.isMagnetLink() ||
            externalUrl.isMagnetLink() ||
            url.isTorrentSchemeUrl() ||
            externalUrl.isTorrentSchemeUrl()
        )

    val isCachedDebridTorrentStream: Boolean
        get() = isTorrentStream && debridCacheStatus?.state == StreamDebridCacheState.CACHED

    val needsLocalDebridResolve: Boolean
        get() = isTorrentStream && playableDirectUrl == null

    val p2pInfoHash: String?
        get() = infoHash.normalizedInfoHash()
            ?: clientResolve?.infoHash.normalizedInfoHash()
            ?: torrentMagnetUri.extractBtihInfoHash()
            ?: torrentSchemeUri.extractTorrentSchemeInfoHash()

    val p2pFileIdx: Int?
        get() = fileIdx ?: torrentSchemeUri.extractTorrentSchemeFileIdx()

    val p2pTrackers: List<String>
        get() = sources
            .asSequence()
            .filter { it.startsWith("tracker:") }
            .map { it.removePrefix("tracker:").trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .toList()

    val isAddonDebridCandidate: Boolean
        get() = isInstalledAddonStream && (needsLocalDebridResolve || isDirectDebridStream)

    val hasPlayableSource: Boolean
        get() = url != null || infoHash != null || externalUrl != null || clientResolve != null
}

data class StreamBadge(
    val name: String,
    val imageURL: String = "",
    val tagColor: String = "",
    val tagStyle: String = "",
    val textColor: String = "",
    val borderColor: String = "",
)

fun normalizeStreamType(raw: String?): String? =
    raw?.trim()?.lowercase()?.takeIf { it.isNotBlank() }

private fun String?.isMagnetLink(): Boolean =
    this?.trimStart()?.startsWith("magnet:", ignoreCase = true) == true

private fun String?.isTorrentSchemeUrl(): Boolean =
    this?.trimStart()?.startsWith("torrent://", ignoreCase = true) == true

private fun String?.extractTorrentSchemeInfoHash(): String? {
    val raw = this?.trimStart()?.takeIf { it.isTorrentSchemeUrl() } ?: return null
    return raw.removeRange(0, "torrent://".length)
        .substringBefore('/')
        .substringBefore('?')
        .trim()
        .takeIf { it.isValidInfoHash() }
}

private fun String?.extractTorrentSchemeFileIdx(): Int? {
    val raw = this?.trimStart()?.takeIf { it.isTorrentSchemeUrl() } ?: return null
    val path = raw.removeRange(0, "torrent://".length).substringBefore('?')
    if ('/' !in path) return null
    return path.substringAfter('/')
        .trim()
        .takeIf { segment -> segment.isNotEmpty() && segment.all { it.isDigit() } }
        ?.toIntOrNull()
}

private fun String.isValidInfoHash(): Boolean =
    (length == 40 && all { it in '0'..'9' || it.lowercaseChar() in 'a'..'f' }) ||
        (length == 32 && all { it in '2'..'7' || it.lowercaseChar() in 'a'..'z' })

private fun String?.normalizedInfoHash(): String? =
    this
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

private fun String?.extractBtihInfoHash(): String? {
    val raw = this?.trim()?.takeIf { it.startsWith("magnet:", ignoreCase = true) } ?: return null
    val marker = "btih:"
    val markerIndex = raw.indexOf(marker, ignoreCase = true)
    if (markerIndex < 0) return null
    val start = markerIndex + marker.length
    val end = raw.indexOf('&', start).takeIf { it >= 0 } ?: raw.length
    return raw.substring(start, end)
        .trim()
        .takeIf { it.isNotEmpty() }
}

fun StreamItem.isSelectableForPlayback(debridEnabled: Boolean): Boolean =
    playableDirectUrl != null ||
        shouldOpenExternally ||
        (FeaturePolicyProvider.policy.p2pEnabled && needsLocalDebridResolve && p2pInfoHash != null) ||
        (debridEnabled && isAddonDebridCandidate)

/**
 * Sanitize addon-declared playback request headers (`behaviorHints.proxyHeaders.request`) before
 * handing them to a player's HTTP stack. Rules mirror upstream cmp-rewrite's
 * `PlayerEngine.sanitizePlaybackHeaders` (composeApp) verbatim: trim keys/values, drop blank
 * pairs, and drop any `Range` header — players own byte-range requests. Public (unlike the
 * composeApp-internal copy) so the native tvOS Swift layer can call it through SharedCore
 * (`StreamModelsKt.sanitizePlaybackHeaders`) when building a `PlaybackContext`.
 */
fun sanitizePlaybackHeaders(headers: Map<String, String>?): Map<String, String> {
    val rawHeaders = headers ?: return emptyMap()
    if (rawHeaders.isEmpty()) return emptyMap()

    val sanitized = LinkedHashMap<String, String>(rawHeaders.size)
    rawHeaders.forEach { (rawKey, rawValue) ->
        val key = rawKey.trim()
        val value = rawValue.trim()
        if (key.isEmpty() || value.isEmpty()) return@forEach
        if (key.equals("Range", ignoreCase = true)) return@forEach
        // Fork hardening beyond upstream's rules (Codex 2026-08-20 round 3): the consumers
        // serialize these into FFmpeg's CRLF-joined `headers` block and mpv's comma-delimited
        // `http-header-fields`, so a key that is not an RFC 7230 token, or any control character
        // in the value, would let an addon inject extra header fields (including the Range we
        // just refused) or produce malformed requests. Drop such entries outright.
        if (!key.all { it.isHeaderTokenChar() }) return@forEach
        if (value.any { it == '\r' || it == '\n' || it.code < 0x20 || it.code == 0x7F }) return@forEach
        sanitized[key] = value
    }
    return sanitized
}

/// RFC 7230 `tchar`: the characters legal in an HTTP header field name.
private fun Char.isHeaderTokenChar(): Boolean =
    this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9' ||
        this in "!#$%&'*+-.^_`|~"

data class StreamBehaviorHints(
    val bingeGroup: String? = null,
    val notWebReady: Boolean = false,
    val videoHash: String? = null,
    val videoSize: Long? = null,
    val filename: String? = null,
    val proxyHeaders: StreamProxyHeaders? = null,
)

data class StreamProxyHeaders(
    val request: Map<String, String>? = null,
    val response: Map<String, String>? = null,
)

enum class StreamDebridCacheState {
    CHECKING,
    CACHED,
    NOT_CACHED,
    UNKNOWN,
}

data class StreamDebridCacheStatus(
    val providerId: String,
    val providerName: String,
    val state: StreamDebridCacheState,
    val cachedName: String? = null,
    val cachedSize: Long? = null,
)

data class StreamClientResolve(
    val type: String? = null,
    val infoHash: String? = null,
    val fileIdx: Int? = null,
    val magnetUri: String? = null,
    val sources: List<String> = emptyList(),
    val torrentName: String? = null,
    val filename: String? = null,
    val mediaType: String? = null,
    val mediaId: String? = null,
    val mediaOnlyId: String? = null,
    val title: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val service: String? = null,
    val serviceIndex: Int? = null,
    val serviceExtension: String? = null,
    val isCached: Boolean? = null,
    val stream: StreamClientResolveStream? = null,
) {
    val isDirectDebridCandidate: Boolean
        get() = type.equals("debrid", ignoreCase = true) &&
            !service.isNullOrBlank() &&
            isCached == true
}

data class StreamClientResolveStream(
    val raw: StreamClientResolveRaw? = null,
)

data class StreamClientResolveRaw(
    val torrentName: String? = null,
    val filename: String? = null,
    val size: Long? = null,
    val folderSize: Long? = null,
    val tracker: String? = null,
    val indexer: String? = null,
    val network: String? = null,
    val parsed: StreamClientResolveParsed? = null,
)

data class StreamClientResolveParsed(
    val rawTitle: String? = null,
    val parsedTitle: String? = null,
    val year: Int? = null,
    val resolution: String? = null,
    val seasons: List<Int> = emptyList(),
    val episodes: List<Int> = emptyList(),
    val quality: String? = null,
    val hdr: List<String> = emptyList(),
    val codec: String? = null,
    val audio: List<String> = emptyList(),
    val channels: List<String> = emptyList(),
    val languages: List<String> = emptyList(),
    val group: String? = null,
    val network: String? = null,
    val edition: String? = null,
    val duration: Long? = null,
    val bitDepth: String? = null,
    val extended: Boolean? = null,
    val theatrical: Boolean? = null,
    val remastered: Boolean? = null,
    val unrated: Boolean? = null,
)

data class AddonStreamGroup(
    val addonName: String,
    val addonId: String,
    val streams: List<StreamItem>,
    val isLoading: Boolean = false,
    val error: String? = null,
)

enum class StreamsEmptyStateReason {
    NoAddonsInstalled,
    NoCompatibleAddons,

    /**
     * BUG-74: the title reached us under a `tmdb:` id and we could not turn it into the IMDb id
     * that `tt`-only stream addons require, so no addon was ever asked. Distinct from
     * [NoCompatibleAddons] on purpose — that one means "you have no addon for this", this one means
     * "you probably do, but we could not address this title to it". Conflating them is what made
     * BUG-74 invisible for three weeks: the user was told to install addons he already had.
     */
    IncompatibleContentId,
    NoStreamsFound,
    StreamFetchFailed,
}

data class StreamsUiState(
    val requestToken: String? = null,
    val groups: List<AddonStreamGroup> = emptyList(),
    val activeAddonIds: Set<String> = emptySet(),
    /// Fork addition (upstream 58864ec1 port): the installed-addon group ids of this fan-out, so a
    /// consumer can apply [areAutoPlaySourcesLoaded] to [groups] without re-deriving the fork's
    /// `streamAddonInstanceId` shape — tvOS's up-next engine reads it through SharedCore. Plugin
    /// groups are everything NOT in this set.
    val installedAddonIds: Set<String> = emptySet(),
    val selectedFilter: String? = null,
    val isAnyLoading: Boolean = false,
    val emptyStateReason: StreamsEmptyStateReason? = null,
    val autoPlayStream: StreamItem? = null,
    val autoPlayCandidates: List<StreamItem> = emptyList(),
    val isDirectAutoPlayFlow: Boolean = false,
    val showDirectAutoPlayOverlay: Boolean = false,
    val overlayMessage: String? = null,
) {
    val filteredGroups: List<AddonStreamGroup>
        get() = if (selectedFilter == null) groups
                else groups.filter { it.addonId == selectedFilter }

    val allStreams: List<StreamItem>
        get() = filteredGroups.flatMap { it.streams }

    val hasAnyStreams: Boolean
        get() = groups.any { it.streams.isNotEmpty() }
}
