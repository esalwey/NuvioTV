package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.ContainerTrack
import com.nuvio.app.features.streams.ContainerTrackKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * Fork (VERIFIED-LANGUAGES): audio/subtitle track lists a debrid service documents for a file it
 * serves — a verified source next to reading the file itself.
 *
 * Real-Debrid only: `GET /streaming/mediaInfos/{id}` (id from `/unrestrict/link`) lists
 * `details.audio` / `details.subtitles` with `lang_iso`. The others have nothing usable: AllDebrid
 * documents no track languages, Premiumize marks `audio_track_names` "do not use", and TorBox only
 * exposes tracks by opening a (Pro-only) HLS stream session, which is not a metadata read.
 */
object DebridTrackMetadata {
    private const val MAX_REMEMBERED = 200

    private data class MediaFile(val providerId: String, val fileId: String)

    /** Download link → the provider file it was unrestricted from (filled at resolve time). */
    private val files = MutableStateFlow<Map<String, MediaFile>>(emptyMap())

    fun remember(url: String, providerId: String, fileId: String?) {
        val id = fileId?.trim()?.takeIf { it.isNotEmpty() } ?: return
        files.update { current ->
            val next = current + (url to MediaFile(providerId, id))
            if (next.size > MAX_REMEMBERED) next.entries.drop(next.size - MAX_REMEMBERED).associate { it.key to it.value } else next
        }
    }

    /** The provider's track list for [url], or null when it has none (or no key, or an error). */
    suspend fun tracksFor(url: String): List<ContainerTrack>? {
        val file = files.value[url] ?: return null
        if (file.providerId != DebridProviders.REAL_DEBRID_ID) return null
        val apiKey = DebridSettingsRepository.snapshot().apiKeyFor(DebridProviders.REAL_DEBRID_ID).trim()
        if (apiKey.isEmpty()) return null
        return try {
            val response = RealDebridApiClient.mediaInfos(apiKey, file.fileId)
            if (!response.isSuccessful) return null
            val body = response.body as? JsonObject ?: return null
            realDebridTracks(body).takeIf { tracks -> tracks.any { it.language != null } }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }
    }

    /** `details.audio` / `details.subtitles` of a mediaInfos answer (objects keyed "fre1", or arrays). */
    fun realDebridTracks(body: JsonObject): List<ContainerTrack> {
        val details = body["details"] as? JsonObject ?: return emptyList()
        fun entries(element: JsonElement?): List<JsonObject> = when (element) {
            is JsonObject -> element.values.mapNotNull { it as? JsonObject }
            is JsonArray -> element.flatMap { item ->
                when {
                    item !is JsonObject -> emptyList()
                    "lang_iso" in item || "lang" in item -> listOf(item)
                    else -> item.values.mapNotNull { it as? JsonObject }
                }
            }
            else -> emptyList()
        }
        fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
        val audio = entries(details["audio"]).map { track ->
            ContainerTrack(
                kind = ContainerTrackKind.AUDIO,
                language = track.text("lang_iso")?.takeIf { !it.equals("und", ignoreCase = true) },
                name = track.text("lang"),
                codec = track.text("codec"),
                channels = (track["channels"] as? JsonPrimitive)?.doubleOrNull?.let { channelCount(it) },
            )
        }
        val subtitles = entries(details["subtitles"]).map { track ->
            ContainerTrack(
                kind = ContainerTrackKind.SUBTITLE,
                language = track.text("lang_iso")?.takeIf { !it.equals("und", ignoreCase = true) },
                name = track.text("lang"),
                codec = track.text("type"),
            )
        }
        return audio + subtitles
    }

    /** 5.1 → 6, 7.1 → 8, 2 → 2. */
    private fun channelCount(value: Double): Int {
        val whole = value.toInt()
        val fraction = ((value - whole) * 10 + 0.5).toInt()
        return whole + fraction
    }
}
