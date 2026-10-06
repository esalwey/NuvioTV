package com.nuvio.app.features.tmdb

import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.home.HomeRepository
import com.nuvio.app.features.player.DeviceLanguagePreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object TmdbSettingsRepository {
    private val _uiState = MutableStateFlow(TmdbSettings())
    val uiState: StateFlow<TmdbSettings> = _uiState.asStateFlow()

    private var hasLoaded = false

    private var enabled = false
    private var apiKey = ""
    private var language = "en"
    private var useTrailers = true
    private var useArtwork = true
    private var useBasicInfo = true
    private var useDetails = true
    private var useCredits = true
    private var useProductions = true
    private var useNetworks = true
    private var useEpisodes = true
    private var useSeasonPosters = true
    private var useMoreLikeThis = true
    private var useCollections = true

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun snapshot(): TmdbSettings {
        ensureLoaded()
        return _uiState.value
    }

    fun setEnabled(value: Boolean) {
        ensureLoaded()
        if (value && apiKey.isBlank()) return
        if (enabled == value) return
        enabled = value
        publish()
        TmdbSettingsStorage.saveEnabled(value)
        invalidateHeroEnrichment()
    }

    fun setApiKey(value: String) {
        ensureLoaded()
        val normalized = value.trim()
        if (apiKey == normalized) return
        apiKey = normalized
        if (apiKey.isBlank()) {
            enabled = false
            TmdbSettingsStorage.saveEnabled(false)
        }
        publish()
        TmdbSettingsStorage.saveApiKey(normalized)
        invalidateHeroEnrichment()
    }

    fun setLanguage(value: String) {
        ensureLoaded()
        val normalized = normalizeLanguage(value)
        if (language == normalized) return
        language = normalized
        publish()
        TmdbSettingsStorage.saveLanguage(normalized)
        invalidateHeroEnrichment()
        // BUG-63: `MetaDetailsRepository` keys `baseMeta` by type:id only, and the TMDB
        // enrichment (trailers included) is baked into it — without this a language flip keeps
        // serving the old language's trailer list until the next launch.
        MetaDetailsRepository.clear()
    }

    /**
     * Removes the stored metadata language so [TmdbSettings.language] falls back to the
     * device-derived default. The cleared state syncs as "no language key", so another device's
     * explicit choice (e.g. the phone's language field) can still re-apply one later.
     */
    fun clearLanguage() {
        ensureLoaded()
        TmdbSettingsStorage.clearLanguage()
        val derived = normalizeLanguage(DeviceLanguagePreferences.preferredLanguageCodes().firstOrNull() ?: "en")
        if (language == derived) return
        language = derived
        publish()
        invalidateHeroEnrichment()
        MetaDetailsRepository.clear() // BUG-63, same reason as setLanguage
    }

    /** True when a metadata language is explicitly stored (vs derived from the device language). */
    fun hasExplicitLanguage(): Boolean {
        ensureLoaded()
        return TmdbSettingsStorage.loadLanguage() != null
    }

    fun setUseTrailers(value: Boolean) = setBoolean(
        current = useTrailers,
        next = value,
        update = { useTrailers = it },
        persist = TmdbSettingsStorage::saveUseTrailers,
    )

    fun setUseArtwork(value: Boolean) = setBoolean(
        current = useArtwork,
        next = value,
        update = { useArtwork = it },
        persist = TmdbSettingsStorage::saveUseArtwork,
    )

    fun setUseBasicInfo(value: Boolean) = setBoolean(
        current = useBasicInfo,
        next = value,
        update = { useBasicInfo = it },
        persist = TmdbSettingsStorage::saveUseBasicInfo,
    )

    fun setUseDetails(value: Boolean) = setBoolean(
        current = useDetails,
        next = value,
        update = { useDetails = it },
        persist = TmdbSettingsStorage::saveUseDetails,
    )

    fun setUseCredits(value: Boolean) = setBoolean(
        current = useCredits,
        next = value,
        update = { useCredits = it },
        persist = TmdbSettingsStorage::saveUseCredits,
    )

    fun setUseProductions(value: Boolean) = setBoolean(
        current = useProductions,
        next = value,
        update = { useProductions = it },
        persist = TmdbSettingsStorage::saveUseProductions,
    )

    fun setUseNetworks(value: Boolean) = setBoolean(
        current = useNetworks,
        next = value,
        update = { useNetworks = it },
        persist = TmdbSettingsStorage::saveUseNetworks,
    )

    fun setUseEpisodes(value: Boolean) = setBoolean(
        current = useEpisodes,
        next = value,
        update = { useEpisodes = it },
        persist = TmdbSettingsStorage::saveUseEpisodes,
    )

    fun setUseSeasonPosters(value: Boolean) = setBoolean(
        current = useSeasonPosters,
        next = value,
        update = { useSeasonPosters = it },
        persist = TmdbSettingsStorage::saveUseSeasonPosters,
    )

    fun setUseMoreLikeThis(value: Boolean) = setBoolean(
        current = useMoreLikeThis,
        next = value,
        update = { useMoreLikeThis = it },
        persist = TmdbSettingsStorage::saveUseMoreLikeThis,
    )

    fun setUseCollections(value: Boolean) = setBoolean(
        current = useCollections,
        next = value,
        update = { useCollections = it },
        persist = TmdbSettingsStorage::saveUseCollections,
    )

    private fun setBoolean(
        current: Boolean,
        next: Boolean,
        update: (Boolean) -> Unit,
        persist: (Boolean) -> Unit,
    ) {
        ensureLoaded()
        if (current == next) return
        update(next)
        publish()
        persist(next)
    }

    private fun loadFromDisk() {
        val wasLoaded = hasLoaded
        val previousEnabled = enabled
        val previousApiKey = apiKey
        val previousLanguage = language
        hasLoaded = true
        apiKey = TmdbSettingsStorage.loadApiKey()?.trim().orEmpty()
        enabled = (TmdbSettingsStorage.loadEnabled() ?: false) && apiKey.isNotBlank()
        val storedLanguage = TmdbSettingsStorage.loadLanguage()
        language = if (storedLanguage == null) {
            normalizeLanguage(DeviceLanguagePreferences.preferredLanguageCodes().firstOrNull() ?: "en")
        } else {
            normalizeLanguage(storedLanguage)
        }
        useTrailers = TmdbSettingsStorage.loadUseTrailers() ?: true
        useArtwork = TmdbSettingsStorage.loadUseArtwork() ?: true
        useBasicInfo = TmdbSettingsStorage.loadUseBasicInfo() ?: true
        useDetails = TmdbSettingsStorage.loadUseDetails() ?: true
        useCredits = TmdbSettingsStorage.loadUseCredits() ?: true
        useProductions = TmdbSettingsStorage.loadUseProductions() ?: true
        useNetworks = TmdbSettingsStorage.loadUseNetworks() ?: true
        useEpisodes = TmdbSettingsStorage.loadUseEpisodes() ?: true
        useSeasonPosters = TmdbSettingsStorage.loadUseSeasonPosters() ?: true
        useMoreLikeThis = TmdbSettingsStorage.loadUseMoreLikeThis() ?: true
        useCollections = TmdbSettingsStorage.loadUseCollections() ?: true
        publish()
        if (wasLoaded && (previousEnabled != enabled || previousApiKey != apiKey || previousLanguage != language)) {
            invalidateHeroEnrichment()
        }
        // BUG-63: a profile switch can change the language through this path (not the setters);
        // the detail/trailer cache is keyed without language, so drop it here too.
        if (wasLoaded && previousLanguage != language) {
            MetaDetailsRepository.clear()
        }
    }

    private fun publish() {
        _uiState.value = TmdbSettings(
            enabled = enabled,
            apiKey = apiKey,
            language = language,
            useTrailers = useTrailers,
            useArtwork = useArtwork,
            useBasicInfo = useBasicInfo,
            useDetails = useDetails,
            useCredits = useCredits,
            useProductions = useProductions,
            useNetworks = useNetworks,
            useEpisodes = useEpisodes,
            useSeasonPosters = useSeasonPosters,
            useMoreLikeThis = useMoreLikeThis,
            useCollections = useCollections,
        )
    }

    private fun invalidateHeroEnrichment() {
        HomeRepository.onTmdbSettingsChanged()
    }
}

fun normalizeLanguage(value: String?): String {
    val trimmed = value?.trim()?.replace('_', '-') ?: return ""
    return trimmed.takeIf { it.isNotBlank() } ?: ""
}
