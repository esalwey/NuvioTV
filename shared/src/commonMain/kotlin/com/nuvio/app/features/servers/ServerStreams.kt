package com.nuvio.app.features.servers

import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamBehaviorHints
import com.nuvio.app.features.streams.StreamItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

class ServerStreamSource(
    val addonId: String,
    val addonName: String,
    val preferred: Boolean,
    private val loader: suspend () -> List<StreamItem>,
) {
    fun loadingGroup(): AddonStreamGroup =
        AddonStreamGroup(addonName = addonName, addonId = addonId, streams = emptyList(), isLoading = true)

    suspend fun load(): AddonStreamGroup = try {
        AddonStreamGroup(addonName = addonName, addonId = addonId, streams = loader(), isLoading = false)
    } catch (error: Throwable) {
        if (error is CancellationException) currentCoroutineContext().ensureActive()
        AddonStreamGroup(
            addonName = addonName,
            addonId = addonId,
            streams = emptyList(),
            isLoading = false,
            error = error.serverFailure().message(),
        )
    }
}

object ServerStreams {
    fun isNativeRequest(videoId: String): Boolean = ServerItemRef.isServerId(videoId)

    fun canServe(type: String, videoId: String): Boolean {
        ServerItemRef.parse(videoId)?.let { ref -> return ServerRepository.connection(ref.connectionId)?.enabled == true }
        EpisodeProgressKey.parse(videoId)?.let { key ->
            return ServerRepository.connection(key.series.connectionId)?.enabled == true
        }
        val connections = ServerRepository.enabledConnections().ifEmpty { return false }
        val request = ServerMatcher.request(type, videoId, season = null, episode = null) ?: return false
        return connections.any { ServerMatcher.supports(it, request.kind) }
    }

    fun isServerSourceId(addonId: String?): Boolean = addonId?.startsWith(GROUP_PREFIX) == true

    fun sources(
        type: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        forceRefresh: Boolean = false,
    ): List<ServerStreamSource> {
        ServerItemRef.parse(videoId)?.let { ref ->
            val connection = ServerRepository.connection(ref.connectionId) ?: return emptyList()
            return listOf(source(connection, preferred = true) { candidates(ref) })
        }
        // The in-player Sources panel and a Continue Watching resume ask with the watch-progress key
        // of a server episode, `<series>:<season>:<episode>`; the episode is looked up on its server.
        EpisodeProgressKey.parse(videoId)?.let { key ->
            val connection = ServerRepository.connection(key.series.connectionId) ?: return emptyList()
            return listOf(source(connection, preferred = true) {
                val episodeRef = ServerRepository.call(connection.id) { provider, session ->
                    provider.findEpisode(session, key.series.itemId, key.season, key.episode)
                }?.let { ServerItemRef(connection.id, it.itemId) }
                if (episodeRef == null) emptyList() else candidates(episodeRef)
            })
        }
        val connections = ServerRepository.enabledConnections().ifEmpty { return emptyList() }
        val request = ServerMatcher.request(type, videoId, season, episode) ?: return emptyList()
        return connections
            .filter { ServerMatcher.supports(it, request.kind) }
            .map { connection ->
                source(connection, preferred = connection.useCatalogMetadata) {
                    ServerMatcher.match(connection, request, forceRefresh).flatMap { candidates(it) }
                }
            }
    }

    private fun source(
        connection: ServerConnection,
        preferred: Boolean,
        loader: suspend () -> List<StreamItem>,
    ): ServerStreamSource =
        ServerStreamSource(
            addonId = groupId(connection.id),
            addonName = ServerRepository.sourceLabel(connection),
            preferred = preferred,
            loader = loader,
        )

    suspend fun candidates(ref: ServerItemRef): List<StreamItem> {
        val connection = ServerRepository.connection(ref.connectionId) ?: throw ServerException(ServerFailure.NOT_FOUND)
        val label = ServerRepository.sourceLabel(connection)
        return ServerRepository.call(ref.connectionId) { provider, session -> provider.candidates(session, ref.itemId) }
            .map { candidate ->
                StreamItem(
                    name = candidate.title,
                    description = candidate.description,
                    sourceName = label,
                    addonName = label,
                    addonId = groupId(connection.id),
                    behaviorHints = StreamBehaviorHints(
                        filename = candidate.filename,
                        videoSize = candidate.sizeBytes,
                    ),
                    serverTarget = candidate.target,
                )
            }
    }

    private fun groupId(connectionId: String) = "$GROUP_PREFIX$connectionId"

    private const val GROUP_PREFIX = "server:"
}

/** The watch-progress key of a server episode: the series' [ServerItemRef] plus the season and episode numbers. */
internal class EpisodeProgressKey(val series: ServerItemRef, val season: Int, val episode: Int) {
    companion object {
        fun parse(videoId: String): EpisodeProgressKey? {
            if (!ServerItemRef.isServerId(videoId)) return null
            val parts = videoId.split(':')
            if (parts.size < MIN_PARTS) return null
            val episode = parts[parts.lastIndex].toIntOrNull() ?: return null
            val season = parts[parts.lastIndex - 1].toIntOrNull() ?: return null
            val series = ServerItemRef.parse(parts.dropLast(2).joinToString(":")) ?: return null
            return EpisodeProgressKey(series, season, episode)
        }

        // prefix, connection, item, season, episode
        private const val MIN_PARTS = 5
    }
}
