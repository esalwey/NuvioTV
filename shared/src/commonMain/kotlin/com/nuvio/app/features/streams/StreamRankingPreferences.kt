package com.nuvio.app.features.streams

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Fork (STREAM-INSIGHT): what the viewer wants from a stream, for [StreamRecommender].
 *
 * Stored per profile as one JSON value (`stream_ranking_preferences`, see
 * [StreamRankingSettingsStorage]). Nothing here duplicates the player's own track languages: the
 * [AUDIO_AUTO] / [SUBTITLE_AUTO] defaults follow `PlayerSettingsRepository`'s
 * `preferred_audio_language` / `preferred_subtitle_language` (and their secondaries), so a viewer
 * who never opens the new settings gets recommendations in the language they already chose —
 * that is the migration: no stored value = "follow the player".
 *
 * Audio language values: [AUDIO_AUTO], [AUDIO_ORIGINAL], [AUDIO_FRENCH_FRANCE] ("fr-fr", VFF),
 * [AUDIO_FRENCH_QUEBEC] ("fr-ca", VFQ), "fr" (French, any version), "es-es", "es-419", "pt-br",
 * "pt-pt", or any other lower-case ISO code ("en", "it", "ja"…).
 */
@Serializable
data class StreamRankingPreferences(
    val enabled: Boolean = true,
    val audioLanguage: String = AUDIO_AUTO,
    /** Acceptable audio languages when the preferred one is missing, in order. */
    val fallbackAudioLanguages: List<String> = emptyList(),
    /** Accept original audio with subtitles in the subtitle language (VOSTFR) when no dub exists. */
    val acceptSubtitledOriginal: Boolean = true,
    /** Subtitle language for that case: [SUBTITLE_AUTO] (the player's), [SUBTITLE_NONE] or a code. */
    val subtitleLanguage: String = SUBTITLE_AUTO,
    /** Lines (2160, 1440, 1080, 720, 480); 0 = no limit. Higher streams are filtered out. */
    val maxResolution: Int = 0,
    /** [HDR_AUTO] (prefer HDR only when this TV can show it), [HDR_PREFER], [HDR_AVOID]. */
    val hdrMode: String = HDR_AUTO,
    /** 0 = no limit; larger files are filtered out. */
    val maxSizeGb: Int = 0,
    /** Rank debrid-cached / instant streams first. */
    val preferCached: Boolean = true,
    /** Filter out CAM / TS / TC / screener releases. */
    val avoidLowQuality: Boolean = true,
) {
    companion object {
        const val AUDIO_AUTO = "auto"
        const val AUDIO_ORIGINAL = "original"
        const val AUDIO_FRENCH_ANY = "fr"
        const val AUDIO_FRENCH_FRANCE = "fr-fr"
        const val AUDIO_FRENCH_QUEBEC = "fr-ca"
        const val SUBTITLE_AUTO = "auto"
        const val SUBTITLE_NONE = "none"
        const val HDR_AUTO = "auto"
        const val HDR_PREFER = "prefer"
        const val HDR_AVOID = "avoid"

        /** The resolution caps offered in Settings (0 = no limit). */
        val maxResolutionOptions: List<Int> = listOf(0, 2160, 1080, 720)

        /** The size caps offered in Settings, in GB (0 = no limit). */
        val maxSizeOptions: List<Int> = listOf(0, 5, 10, 20, 40, 60, 100)

        /** The curated stream-language choices shown first in Settings, in this order. */
        val curatedAudioLanguages: List<String> = listOf(
            AUDIO_AUTO,
            AUDIO_ORIGINAL,
            AUDIO_FRENCH_FRANCE,
            AUDIO_FRENCH_QUEBEC,
            AUDIO_FRENCH_ANY,
            "en",
            "es-es",
            "es-419",
            "pt-br",
            "pt-pt",
            "it",
            "de",
            "ja",
            "ko",
        )
    }
}

/** Persisted JSON payload of [StreamRankingPreferences] for the active profile. */
expect object StreamRankingSettingsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
    fun clear()
}

object StreamRankingSettingsRepository {
    private val _uiState = MutableStateFlow(StreamRankingPreferences())
    val uiState: StateFlow<StreamRankingPreferences> = _uiState.asStateFlow()

    @OptIn(ExperimentalSerializationApi::class)
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        _uiState.value = StreamRankingPreferences()
    }

    fun snapshot(): StreamRankingPreferences {
        ensureLoaded()
        return _uiState.value
    }

    fun setEnabled(enabled: Boolean) = update { it.copy(enabled = enabled) }

    fun setAudioLanguage(language: String) = update {
        it.copy(audioLanguage = normalizePreferenceCode(language) ?: StreamRankingPreferences.AUDIO_AUTO)
    }

    fun setFallbackAudioLanguages(languages: List<String>) = update { current ->
        val primary = current.audioLanguage
        current.copy(
            fallbackAudioLanguages = languages
                .mapNotNull(::normalizePreferenceCode)
                .filter { it != StreamRankingPreferences.AUDIO_AUTO && it != primary }
                .distinct(),
        )
    }

    /** Single fallback (what the tvOS picker edits); null or "" clears it. */
    fun setFallbackAudioLanguage(language: String?) =
        setFallbackAudioLanguages(listOfNotNull(language?.takeIf { it.isNotBlank() }))

    fun setAcceptSubtitledOriginal(accept: Boolean) = update { it.copy(acceptSubtitledOriginal = accept) }

    fun setSubtitleLanguage(language: String) = update {
        it.copy(subtitleLanguage = normalizePreferenceCode(language) ?: StreamRankingPreferences.SUBTITLE_AUTO)
    }

    fun setMaxResolution(lines: Int) = update { it.copy(maxResolution = lines.coerceAtLeast(0)) }

    fun setHdrMode(mode: String) = update {
        val normalized = when (mode.trim().lowercase()) {
            StreamRankingPreferences.HDR_PREFER -> StreamRankingPreferences.HDR_PREFER
            StreamRankingPreferences.HDR_AVOID -> StreamRankingPreferences.HDR_AVOID
            else -> StreamRankingPreferences.HDR_AUTO
        }
        it.copy(hdrMode = normalized)
    }

    fun setMaxSizeGb(gigabytes: Int) = update { it.copy(maxSizeGb = gigabytes.coerceAtLeast(0)) }

    fun setPreferCached(prefer: Boolean) = update { it.copy(preferCached = prefer) }

    fun setAvoidLowQuality(avoid: Boolean) = update { it.copy(avoidLowQuality = avoid) }

    fun resetToDefaults() {
        ensureLoaded()
        _uiState.value = StreamRankingPreferences()
        StreamRankingSettingsStorage.clear()
    }

    private fun update(transform: (StreamRankingPreferences) -> StreamRankingPreferences) {
        ensureLoaded()
        val next = transform(_uiState.value)
        if (next == _uiState.value) return
        _uiState.value = next
        runCatching { StreamRankingSettingsStorage.savePayload(json.encodeToString(next)) }
    }

    private fun loadFromDisk() {
        hasLoaded = true
        val payload = runCatching { StreamRankingSettingsStorage.loadPayload() }.getOrNull()
        _uiState.value = decode(payload)
    }

    /** Lenient decode: an unreadable or absent payload is the defaults (follow the player). */
    fun decode(payload: String?): StreamRankingPreferences {
        if (payload.isNullOrBlank()) return StreamRankingPreferences()
        return runCatching { json.decodeFromString<StreamRankingPreferences>(payload) }
            .getOrNull()
            ?.let { decoded ->
                decoded.copy(
                    audioLanguage = normalizePreferenceCode(decoded.audioLanguage) ?: StreamRankingPreferences.AUDIO_AUTO,
                    subtitleLanguage = normalizePreferenceCode(decoded.subtitleLanguage) ?: StreamRankingPreferences.SUBTITLE_AUTO,
                    fallbackAudioLanguages = decoded.fallbackAudioLanguages.mapNotNull(::normalizePreferenceCode).distinct(),
                )
            }
            ?: StreamRankingPreferences()
    }

    fun encode(preferences: StreamRankingPreferences): String = json.encodeToString(preferences)

    /** "FR-CA" → "fr-ca", "fr_FR" → "fr-fr", blank → null. Sentinels pass through. */
    internal fun normalizePreferenceCode(raw: String?): String? =
        raw?.trim()?.lowercase()?.replace('_', '-')?.takeIf { it.isNotEmpty() }
}
