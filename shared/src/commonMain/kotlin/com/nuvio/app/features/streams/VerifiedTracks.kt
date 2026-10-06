package com.nuvio.app.features.streams

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.player.languageFromTrackText
import com.nuvio.app.features.player.normalizeLanguageCode
import com.nuvio.app.features.player.stripLanguageDiacritics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/*
 * Fork (VERIFIED-LANGUAGES): what a file's audio and subtitle tracks really are — read from the
 * file itself ([TrackProbe]), from the debrid service's media info, or recorded by the player when
 * the stream was played — remembered per file ([VerifiedTrackStore]) and laid over the title's
 * guess ([VerifiedTrackLanguages.applyRecord]). A title that names no language says nothing about the
 * audio; a verified track list says everything.
 */

enum class VerifiedTrackSource { PROBE, PLAYBACK, DEBRID }

/** One track as stored: the raw container facts, mapped to languages when applied. */
@Serializable
data class VerifiedTrack(
    /** "a" = audio, "s" = subtitle. */
    val kind: String,
    val language: String? = null,
    val languageTag: String? = null,
    val name: String? = null,
    val forced: Boolean = false,
) {
    val isAudio: Boolean get() = kind == KIND_AUDIO

    companion object {
        const val KIND_AUDIO = "a"
        const val KIND_SUBTITLE = "s"

        fun from(track: ContainerTrack): VerifiedTrack = VerifiedTrack(
            kind = if (track.kind == ContainerTrackKind.AUDIO) KIND_AUDIO else KIND_SUBTITLE,
            language = track.language,
            languageTag = track.languageTag,
            name = track.name?.take(80),
            forced = track.isForced,
        )
    }
}

@Serializable
data class VerifiedTrackRecord(
    val tracks: List<VerifiedTrack>,
    /** [VerifiedTrackSource] name. */
    val source: String = VerifiedTrackSource.PROBE.name,
    val verifiedAtMs: Long = 0,
    val lastUsedMs: Long = 0,
) {
    val audio: List<VerifiedTrack> get() = tracks.filter { it.isAudio }
    val subtitles: List<VerifiedTrack> get() = tracks.filter { !it.isAudio }
}

object VerifiedTrackLanguages {

    private val SKIPPED_TRACK_WORDS = setOf(
        "commentary", "commentaire", "commentaires", "comentario", "kommentar",
        "description", "descriptive", "audiodescription", "audiodescriptive",
    )
    private val QUEBEC_WORDS = setOf("vfq", "quebec", "quebecois", "quebecoise", "canada", "canadian", "canadien")
    private val FRANCE_WORDS = setOf("vff", "truefrench", "france", "parisian")
    private val UNDETERMINED = setOf("und", "unk", "unknown", "zxx", "mul", "mis", "qaa", "xx", "none")

    /**
     * The language a track stands for, in the parser's variant model: "fre" → VF, "fr-CA" or a
     * "VFQ" / "French (Canada)" title → VFQ, "VFF" / "TrueFrench" → VFF, "pt-BR" → PT-BR, "es-419"
     * or "Latino" → LAT. Null for an undetermined track, a commentary or an audio description.
     */
    fun languageOf(track: VerifiedTrack): StreamLanguage? {
        val name = track.name?.trim().orEmpty()
        val words = words(name)
        if (words.any { it in SKIPPED_TRACK_WORDS }) return null
        val tag = track.languageTag?.trim()?.takeIf { it.isNotEmpty() && it.lowercase() !in UNDETERMINED }
        val raw = tag ?: track.language?.trim()?.takeIf { it.isNotEmpty() && it.lowercase() !in UNDETERMINED }
        val fromCode = raw?.let(::normalizeLanguageCode)?.takeIf { it.lowercase() !in UNDETERMINED }
        val code = fromCode ?: languageFromTrackText(name) ?: return null
        val primary = code.substringBefore('-').lowercase()
        if (primary.length !in 2..3 || !primary.all { it in 'a'..'z' } || primary in UNDETERMINED) return null
        val region = code.substringAfter('-', "").lowercase()
        val variant = when (primary) {
            "fr" -> when {
                words.any { it in QUEBEC_WORDS } || region == "ca" -> StreamLanguageVariant.QUEBEC
                words.any { it in FRANCE_WORDS } || (tag != null && region == "fr") -> StreamLanguageVariant.FRANCE
                "vfi" in words -> StreamLanguageVariant.INTERNATIONAL
                else -> StreamLanguageVariant.UNSPECIFIED
            }
            "es" -> when {
                region == "419" || words.any { it == "latino" || it == "latin" || it == "latam" } -> StreamLanguageVariant.LATIN_AMERICA
                region.length == 2 && region != "es" -> StreamLanguageVariant.LATIN_AMERICA
                region == "es" || words.any { it == "castellano" || it == "castilian" || it == "espana" } -> StreamLanguageVariant.SPAIN
                else -> StreamLanguageVariant.UNSPECIFIED
            }
            "pt" -> when {
                region == "br" || words.any { it == "brazil" || it == "brasil" || it == "brazilian" || it == "brasileiro" } ->
                    StreamLanguageVariant.BRAZIL
                region == "pt" || words.any { it == "portugal" || it == "european" } -> StreamLanguageVariant.PORTUGAL
                else -> StreamLanguageVariant.UNSPECIFIED
            }
            else -> StreamLanguageVariant.UNSPECIFIED
        }
        return StreamLanguage(
            language = primary,
            variant = variant,
            confidence = StreamConfidence.HIGH,
            evidence = listOf(listOfNotNull(track.languageTag ?: track.language, name.takeIf { it.isNotEmpty() }).joinToString(" ")),
        )
    }

    /** The audio languages of [record], in track order, one per language + version. */
    fun audioLanguages(record: VerifiedTrackRecord): List<StreamLanguage> =
        distinct(record.audio.mapNotNull(::languageOf))

    /** Subtitle languages of the file (forced-only tracks left out: they are not a VOST). */
    fun subtitleLanguages(record: VerifiedTrackRecord): List<StreamLanguage> =
        distinct(record.subtitles.filter { !it.forced }.mapNotNull(::languageOf))

    /**
     * [insight] with the file's real tracks. The audio languages are replaced (when the file tags
     * at least one); a version the title states ("VFF") refines a file track that only says "fre"
     * when that is the only French track. Embedded subtitles are added to the title's.
     */
    fun applyRecord(insight: StreamInsight, record: VerifiedTrackRecord?): StreamInsight {
        if (record == null) return insight
        val subtitles = subtitleLanguages(record)
        val mergedSubtitles = (subtitles + insight.subtitleLanguages.filter { title ->
            subtitles.none { it.language == title.language }
        })
        var result = insight.copy(
            subtitleLanguages = mergedSubtitles,
            subtitlesVerified = record.subtitles.isNotEmpty() || insight.subtitlesVerified,
        )
        val audio = audioLanguages(record)
        if (audio.isEmpty()) return result
        val refined = audio.map { track ->
            if (track.variant != StreamLanguageVariant.UNSPECIFIED) return@map track
            if (audio.count { it.language == track.language } != 1) return@map track
            val stated = insight.audioLanguages
                .filter { it.language == track.language && it.variant != StreamLanguageVariant.UNSPECIFIED }
                .map { it.variant }
                .distinct()
            if (stated.size == 1) track.copy(variant = stated.first(), evidence = track.evidence + "title") else track
        }
        val final = distinct(refined)
        result = result.copy(
            audioLanguages = final,
            audioVerified = true,
            isMultiAudio = final.size > 2 || insight.isMultiAudio && final.size > 1,
            isDualAudio = final.size == 2,
            isDubbed = false,
        )
        return result
    }

    private fun distinct(languages: List<StreamLanguage>): List<StreamLanguage> {
        val seen = HashSet<Pair<String, StreamLanguageVariant>>()
        return languages.filter { seen.add(it.language to it.variant) }
    }

    private fun words(value: String): List<String> {
        val folded = stripLanguageDiacritics(value.lowercase())
        val result = mutableListOf<String>()
        val current = StringBuilder()
        for (char in folded) {
            if (char.isLetterOrDigit()) current.append(char) else if (current.isNotEmpty()) {
                result += current.toString()
                current.clear()
            }
        }
        if (current.isNotEmpty()) result += current.toString()
        return result
    }
}

/** The identities a file is remembered under, most specific first (hashed: no URL is stored). */
object VerifiedTrackKeys {

    private val INFO_HASH_REGEX = Regex("(?i)(?<![0-9a-f])([0-9a-f]{40})(?![0-9a-f])")

    fun forStream(stream: StreamItem): List<String> {
        val keys = mutableListOf<String>()
        val resolve = stream.clientResolve
        val hash = (stream.p2pInfoHash ?: resolve?.infoHash ?: stream.playableDirectUrl?.let(::infoHashInUrl))
            ?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        val fileIdx = stream.p2pFileIdx ?: resolve?.fileIdx
        val filename = listOfNotNull(stream.behaviorHints.filename, resolve?.filename, resolve?.stream?.raw?.filename)
            .firstOrNull { it.isNotBlank() }
            ?: stream.playableDirectUrl?.let(::fileNameInUrl)
        val name = filename?.let(::normalizeFileName)?.takeIf { it.length >= 6 }
        val size = stream.behaviorHints.videoSize?.takeIf { it > 0 }
            ?: stream.debridCacheStatus?.cachedSize?.takeIf { it > 0 }
            ?: resolve?.stream?.raw?.size?.takeIf { it > 0 }
        if (hash != null && fileIdx != null) keys += "ih:$hash:$fileIdx"
        if (hash != null && name != null) keys += "ihn:$hash:$name"
        if (name != null && size != null) keys += "fs:$name:$size"
        stream.playableDirectUrl?.let { keys += forUrl(it) }
        return keys.distinct().map(::hashKey)
    }

    fun forUrl(url: String): String = "u:" + url.trim()

    /** "Movie.2020.1080p.MULTi.mkv" and "movie 2020 1080p multi.mkv" are the same file. */
    fun normalizeFileName(value: String): String {
        val decoded = value.substringAfterLast('/').lowercase()
        val builder = StringBuilder()
        var lastWasSeparator = false
        for (char in decoded) {
            if (char.isLetterOrDigit()) {
                builder.append(char)
                lastWasSeparator = false
            } else if (!lastWasSeparator && builder.isNotEmpty()) {
                builder.append('.')
                lastWasSeparator = true
            }
        }
        return builder.toString().trimEnd('.')
    }

    internal fun infoHashInUrl(url: String): String? = INFO_HASH_REGEX.find(url.substringBefore('?'))?.groupValues?.get(1)

    private fun fileNameInUrl(url: String): String? {
        val segment = url.substringBefore('?').substringBefore('#').substringAfterLast('/')
        val decoded = runCatching { percentDecode(segment) }.getOrDefault(segment)
        return decoded.takeIf { it.contains('.') && it.substringAfterLast('.').lowercase() in VIDEO_EXTENSIONS }
    }

    private val VIDEO_EXTENSIONS = setOf("mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts")

    private fun percentDecode(value: String): String {
        if ('%' !in value) return value
        val bytes = ArrayList<Byte>(value.length)
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%' && index + 2 < value.length) {
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes += hex.toByte()
                    index += 3
                    continue
                }
            }
            char.toString().encodeToByteArray().forEach { bytes += it }
            index++
        }
        return bytes.toByteArray().decodeToString()
    }

    /** FNV-1a 64: short, stable, and no link or file name kept on disk. */
    fun hashKey(value: String): String {
        var hash = 0xcbf29ce484222325uL
        for (byte in value.encodeToByteArray()) {
            hash = hash xor (byte.toUByte().toULong())
            hash *= 0x100000001b3uL
        }
        return hash.toString(16)
    }
}

/** Persisted JSON payload of [VerifiedTrackStore] (device-wide: tracks are facts about files). */
expect object VerifiedTrackStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
    fun clear()
}

/**
 * Verified track lists by file identity: 90-day TTL, at most [MAX_ENTRIES] keys (least recently
 * used dropped first), saved a moment after the last change. Every record lands under all the keys
 * of its stream (info hash + file index, file name + size, link) so another add-on listing the
 * same file finds it too.
 */
object VerifiedTrackStore {
    const val MAX_ENTRIES = 5_000
    const val TTL_MS = 90L * 24 * 60 * 60 * 1000
    private const val SAVE_DELAY_MS = 2_000L
    private const val TOUCH_INTERVAL_MS = 24L * 60 * 60 * 1000

    @Serializable
    private data class Payload(val entries: Map<String, VerifiedTrackRecord> = emptyMap())

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val state = MutableStateFlow<Map<String, VerifiedTrackRecord>>(emptyMap())
    private var loaded = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("VerifiedTrackStore"))
    private var saveJob: Job? = null

    /** Link → the stream keys it was played from (set by the picker, read by [recordPlayback]). */
    private val playbackKeys = MutableStateFlow<Map<String, List<String>>>(emptyMap())

    /** Tests: in-memory only. */
    var persistenceEnabled = true

    var clock: () -> Long = ::epochMs

    fun ensureLoaded() {
        if (loaded) return
        loaded = true
        if (!persistenceEnabled) return
        val payload = runCatching { VerifiedTrackStorage.loadPayload() }.getOrNull() ?: return
        val decoded = runCatching { json.decodeFromString<Payload>(payload) }.getOrNull() ?: return
        val now = clock()
        state.value = decoded.entries.filterValues { now - it.verifiedAtMs in 0..TTL_MS }
    }

    fun size(): Int = state.value.size

    fun lookup(stream: StreamItem): VerifiedTrackRecord? = lookupKeys(VerifiedTrackKeys.forStream(stream))

    fun lookupKeys(keys: List<String>): VerifiedTrackRecord? {
        ensureLoaded()
        val now = clock()
        val entries = state.value
        for (key in keys) {
            val record = entries[key] ?: continue
            if (now - record.verifiedAtMs !in 0..TTL_MS) continue
            if (now - record.lastUsedMs > TOUCH_INTERVAL_MS) {
                state.update { it + (key to record.copy(lastUsedMs = now)) }
                scheduleSave()
            }
            return record
        }
        return null
    }

    fun record(stream: StreamItem, tracks: List<ContainerTrack>, source: VerifiedTrackSource) =
        recordKeys(VerifiedTrackKeys.forStream(stream), tracks, source)

    /** Records [tracks] under [keys]; ignored when no track carries a language. */
    fun recordKeys(keys: List<String>, tracks: List<ContainerTrack>, source: VerifiedTrackSource): VerifiedTrackRecord? {
        if (keys.isEmpty()) return null
        val stored = tracks.map(VerifiedTrack::from)
        val now = clock()
        val record = VerifiedTrackRecord(stored, source.name, now, now)
        if (VerifiedTrackLanguages.audioLanguages(record).isEmpty() && VerifiedTrackLanguages.subtitleLanguages(record).isEmpty()) {
            return null
        }
        ensureLoaded()
        state.update { current ->
            val next = LinkedHashMap(current)
            keys.forEach { next[it] = record }
            if (next.size > MAX_ENTRIES) {
                next.entries.sortedBy { it.value.lastUsedMs }
                    .take(next.size - MAX_ENTRIES)
                    .map { it.key }
                    .forEach { next.remove(it) }
            }
            next
        }
        scheduleSave()
        return record
    }

    /** The picker: [url] is about to play [stream] (so the player's track list lands on its keys). */
    fun registerPlayback(url: String, stream: StreamItem) {
        val keys = VerifiedTrackKeys.forStream(stream)
        playbackKeys.update { current ->
            val next = current + (url to keys)
            if (next.size > 32) next.entries.drop(next.size - 32).associate { it.key to it.value } else next
        }
    }

    /** The player learned the file's tracks: remember them for the stream it was picked from. */
    fun recordPlayback(url: String, tracks: List<ContainerTrack>) {
        val keys = (playbackKeys.value[url].orEmpty() + VerifiedTrackKeys.hashKey(VerifiedTrackKeys.forUrl(url))).distinct()
        recordKeys(keys, tracks, VerifiedTrackSource.PLAYBACK)
    }

    fun clearAll() {
        state.value = emptyMap()
        playbackKeys.value = emptyMap()
        if (persistenceEnabled) runCatching { VerifiedTrackStorage.clear() }
    }

    private fun scheduleSave() {
        if (!persistenceEnabled) return
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(SAVE_DELAY_MS)
            val payload = json.encodeToString(Payload(state.value))
            runCatching { VerifiedTrackStorage.savePayload(payload) }
        }
    }
}
