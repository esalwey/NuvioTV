package com.nuvio.app.features.details

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

enum class MetaScreenSectionKey {
    ACTIONS,
    OVERVIEW,
    PRODUCTION,
    CAST,
    COMMENTS,
    TRAILERS,
    EPISODES,
    DETAILS,
    COLLECTION,
    MORE_LIKE_THIS,
    ;

    
    val canBeTabbed: Boolean
        get() = this != ACTIONS && this != OVERVIEW
}

data class MetaScreenSectionItem(
    val key: MetaScreenSectionKey,
    val title: String,
    val description: String,
    val enabled: Boolean,
    val order: Int,
    val tabGroup: Int? = null,
)

data class MetaScreenSettingsUiState(
    val items: List<MetaScreenSectionItem> = emptyList(),
    val backgroundMode: MetaScreenBackgroundMode = MetaScreenBackgroundMode.Normal,
    val cinematicBackground: Boolean = false,
    val heroTrailerPlayback: Boolean = false,
    val tabLayout: Boolean = false,
    val episodeCardStyle: MetaEpisodeCardStyle = MetaEpisodeCardStyle.Horizontal,
    val blurUnwatchedEpisodes: Boolean = false,
    // Upstream 6fb46976b (SET-2): rating visibility. Carried in the synced payload so a save from
    // this client keeps the values another client set.
    val showOverallRatings: Boolean = true,
    val episodeRatingsVisibility: EpisodeRatingsVisibility = EpisodeRatingsVisibility.SHOW_ALL,
)

enum class MetaScreenBackgroundMode {
    Normal,
    Cinematic,
    DominantColor,
    ;

    val usesBackdropBackground: Boolean
        get() = this != Normal

    companion object {
        fun parse(raw: String?): MetaScreenBackgroundMode? = when (raw?.lowercase()) {
            "normal" -> Normal
            "cinematic" -> Cinematic
            "dominant_color" -> DominantColor
            else -> null
        }

        fun persist(mode: MetaScreenBackgroundMode): String = when (mode) {
            Normal -> "normal"
            Cinematic -> "cinematic"
            DominantColor -> "dominant_color"
        }

        fun fromLegacyCinematic(enabled: Boolean): MetaScreenBackgroundMode =
            if (enabled) Cinematic else Normal
    }
}

enum class MetaEpisodeCardStyle {
    Horizontal,
    List,
    ;

    companion object {
        fun parse(raw: String?): MetaEpisodeCardStyle? = when (raw?.lowercase()) {
            "horizontal" -> Horizontal
            "list" -> List
            else -> null
        }

        fun persist(style: MetaEpisodeCardStyle): String = when (style) {
            Horizontal -> "horizontal"
            List -> "list"
        }
    }
}

@Serializable
private data class StoredMetaScreenSectionPreference(
    val key: String,
    val enabled: Boolean = true,
    val order: Int = 0,
    val tabGroup: Int? = null,
)

@Serializable
private data class StoredMetaScreenSettingsPayload(
    val items: List<StoredMetaScreenSectionPreference> = emptyList(),
    @SerialName("background_mode")
    val backgroundMode: String? = null,
    val cinematicBackground: Boolean = false,
    @SerialName("hero_trailer_playback")
    val heroTrailerPlayback: Boolean = false,
    @SerialName("tvStyleLayout")
    val tabLayout: Boolean = false,
    val episodeCardStyle: String = "horizontal",
    @SerialName("blur_unwatched_episodes")
    val blurUnwatchedEpisodes: Boolean = false,
    @SerialName("show_overall_ratings")
    val showOverallRatings: Boolean = true,
    @SerialName("episode_ratings_visibility")
    val episodeRatingsVisibility: String = EpisodeRatingsVisibility.SHOW_ALL.name,
)

private data class MetaScreenSectionDefinition(
    val key: MetaScreenSectionKey,
    val titleKey: StringKey,
    val titleFallback: String,
    val descriptionKey: StringKey,
    val descriptionFallback: String,
)

object MetaScreenSettingsRepository {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val definitions = listOf(
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.ACTIONS,
            titleKey = StringKey.meta_section_actions_title,
            titleFallback = "Actions",
            descriptionKey = StringKey.meta_section_actions_description,
            descriptionFallback = "Play and save controls.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.OVERVIEW,
            titleKey = StringKey.meta_section_overview_title,
            titleFallback = "Overview",
            descriptionKey = StringKey.meta_section_overview_description,
            descriptionFallback = "Synopsis, ratings, genres, and core credits.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.PRODUCTION,
            titleKey = StringKey.meta_section_production_title,
            titleFallback = "Production",
            descriptionKey = StringKey.meta_section_production_description,
            descriptionFallback = "Studios and networks.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.CAST,
            titleKey = StringKey.settings_meta_cast,
            titleFallback = "Cast",
            descriptionKey = StringKey.meta_section_cast_description,
            descriptionFallback = "Principal cast list.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.COMMENTS,
            titleKey = StringKey.settings_meta_comments,
            titleFallback = "Comments",
            descriptionKey = StringKey.meta_section_comments_description,
            descriptionFallback = "Trakt comments section.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.TRAILERS,
            titleKey = StringKey.settings_meta_trailers,
            titleFallback = "Trailers",
            descriptionKey = StringKey.meta_section_trailers_description,
            descriptionFallback = "Trailer rail and playback shortcuts.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.EPISODES,
            titleKey = StringKey.settings_meta_episodes,
            titleFallback = "Episodes",
            descriptionKey = StringKey.meta_section_episodes_description,
            descriptionFallback = "Seasons and episode list for series.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.DETAILS,
            titleKey = StringKey.meta_section_details_title,
            titleFallback = "Details",
            descriptionKey = StringKey.meta_section_details_description,
            descriptionFallback = "Runtime, status, release, language, and related info.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.COLLECTION,
            titleKey = StringKey.meta_section_collection_title,
            titleFallback = "Collection",
            descriptionKey = StringKey.meta_section_collection_description,
            descriptionFallback = "Related collection or franchise rail.",
        ),
        MetaScreenSectionDefinition(
            key = MetaScreenSectionKey.MORE_LIKE_THIS,
            titleKey = StringKey.meta_section_more_like_this_title,
            titleFallback = "More Like This",
            descriptionKey = StringKey.meta_section_more_like_this_description,
            descriptionFallback = "Recommendation rail.",
        ),
    )

    private val _uiState = MutableStateFlow(MetaScreenSettingsUiState())
    val uiState: StateFlow<MetaScreenSettingsUiState> = _uiState.asStateFlow()

    private var hasLoaded = false
    private var preferences: MutableMap<MetaScreenSectionKey, StoredMetaScreenSectionPreference> = mutableMapOf()
    private var backgroundMode: MetaScreenBackgroundMode = MetaScreenBackgroundMode.Normal
    private var heroTrailerPlayback: Boolean = false
    private var tabLayout: Boolean = false
    private var episodeCardStyle: MetaEpisodeCardStyle = MetaEpisodeCardStyle.Horizontal
    private var blurUnwatchedEpisodes: Boolean = false
    private var showOverallRatings: Boolean = true
    private var episodeRatingsVisibility: EpisodeRatingsVisibility = EpisodeRatingsVisibility.SHOW_ALL

    fun ensureLoaded() {
        if (hasLoaded) return
        hasLoaded = true

        val payload = MetaScreenSettingsStorage.loadPayload().orEmpty().trim()
        if (payload.isNotEmpty()) {
            val parsed = runCatching {
                json.decodeFromString<StoredMetaScreenSettingsPayload>(payload)
            }.getOrNull()
            if (parsed != null) {
                backgroundMode = MetaScreenBackgroundMode.parse(parsed.backgroundMode)
                    ?: MetaScreenBackgroundMode.fromLegacyCinematic(parsed.cinematicBackground)
                heroTrailerPlayback = parsed.heroTrailerPlayback
                tabLayout = parsed.tabLayout
                episodeCardStyle = MetaEpisodeCardStyle.parse(parsed.episodeCardStyle)
                    ?: MetaEpisodeCardStyle.Horizontal
                blurUnwatchedEpisodes = parsed.blurUnwatchedEpisodes
                showOverallRatings = parsed.showOverallRatings
                episodeRatingsVisibility = EpisodeRatingsVisibility.parse(parsed.episodeRatingsVisibility)
                preferences = parsed.items.mapNotNull { item ->
                    val key = runCatching { MetaScreenSectionKey.valueOf(item.key) }.getOrNull() ?: return@mapNotNull null
                    key to item
                }.toMap().toMutableMap()
            }
        }

        normalizePreferences()
        publish()
        persist()
    }

    fun onProfileChanged() {
        hasLoaded = false
        preferences.clear()
        backgroundMode = MetaScreenBackgroundMode.Normal
        heroTrailerPlayback = false
        tabLayout = false
        episodeCardStyle = MetaEpisodeCardStyle.Horizontal
        blurUnwatchedEpisodes = false
        showOverallRatings = true
        episodeRatingsVisibility = EpisodeRatingsVisibility.SHOW_ALL
        _uiState.value = MetaScreenSettingsUiState()
        ensureLoaded()
    }

    fun setCinematicBackground(enabled: Boolean) {
        setBackgroundMode(MetaScreenBackgroundMode.fromLegacyCinematic(enabled))
    }

    fun setBackgroundMode(mode: MetaScreenBackgroundMode) {
        ensureLoaded()
        backgroundMode = mode
        publish()
        persist()
    }

    fun setHeroTrailerPlayback(enabled: Boolean) {
        ensureLoaded()
        heroTrailerPlayback = enabled
        publish()
        persist()
    }

    fun setTabLayout(enabled: Boolean) {
        ensureLoaded()
        tabLayout = enabled
        publish()
        persist()
    }

    fun setEpisodeCardStyle(style: MetaEpisodeCardStyle) {
        ensureLoaded()
        episodeCardStyle = style
        publish()
        persist()
    }

    fun setBlurUnwatchedEpisodes(enabled: Boolean) {
        ensureLoaded()
        blurUnwatchedEpisodes = enabled
        publish()
        persist()
    }

    fun setShowOverallRatings(enabled: Boolean) {
        ensureLoaded()
        showOverallRatings = enabled
        publish()
        persist()
    }

    fun setEpisodeRatingsVisibility(visibility: EpisodeRatingsVisibility) {
        ensureLoaded()
        episodeRatingsVisibility = visibility
        publish()
        persist()
    }

    fun setTabGroup(key: MetaScreenSectionKey, groupId: Int?) {
        ensureLoaded()
        if (!key.canBeTabbed) return
        if (groupId != null) {
            // Enforce max 3 sections per group
            val currentGroupCount = preferences.count { it.value.tabGroup == groupId && it.key != key }
            if (currentGroupCount >= 3) return
        }
        updatePreference(key) { preference ->
            preference.copy(tabGroup = groupId)
        }
    }

    fun clearLocalState() {
        hasLoaded = false
        preferences.clear()
        backgroundMode = MetaScreenBackgroundMode.Normal
        heroTrailerPlayback = false
        tabLayout = false
        episodeCardStyle = MetaEpisodeCardStyle.Horizontal
        blurUnwatchedEpisodes = false
        showOverallRatings = true
        episodeRatingsVisibility = EpisodeRatingsVisibility.SHOW_ALL
        _uiState.value = MetaScreenSettingsUiState()
    }

    fun applyFromSync(
        items: List<MetaScreenSectionItem>,
        cinematicBackground: Boolean,
        heroTrailerPlayback: Boolean = false,
        tabLayout: Boolean,
        episodeCardStyle: MetaEpisodeCardStyle = MetaEpisodeCardStyle.Horizontal,
        blurUnwatchedEpisodes: Boolean = false,
        backgroundMode: MetaScreenBackgroundMode? = null,
        showOverallRatings: Boolean = true,
        episodeRatingsVisibility: EpisodeRatingsVisibility = EpisodeRatingsVisibility.SHOW_ALL,
    ) {
        ensureLoaded()
        this.backgroundMode = backgroundMode ?: MetaScreenBackgroundMode.fromLegacyCinematic(cinematicBackground)
        this.heroTrailerPlayback = heroTrailerPlayback
        this.tabLayout = tabLayout
        this.episodeCardStyle = episodeCardStyle
        this.blurUnwatchedEpisodes = blurUnwatchedEpisodes
        this.showOverallRatings = showOverallRatings
        this.episodeRatingsVisibility = episodeRatingsVisibility
        preferences = items.associate { item ->
            item.key to StoredMetaScreenSectionPreference(
                key = item.key.name,
                enabled = item.enabled,
                order = item.order,
                tabGroup = item.tabGroup,
            )
        }.toMutableMap()
        normalizePreferences()
        publish()
        persist()
    }

    fun setEnabled(key: MetaScreenSectionKey, enabled: Boolean) {
        updatePreference(key) { preference ->
            preference.copy(enabled = enabled)
        }
    }

    fun resetToDefaults() {
        ensureLoaded()
        preferences.clear()
        backgroundMode = MetaScreenBackgroundMode.Normal
        heroTrailerPlayback = false
        tabLayout = false
        episodeCardStyle = MetaEpisodeCardStyle.Horizontal
        blurUnwatchedEpisodes = false
        showOverallRatings = true
        episodeRatingsVisibility = EpisodeRatingsVisibility.SHOW_ALL
        normalizePreferences()
        publish()
        persist()
    }

    fun moveByIndex(fromIndex: Int, toIndex: Int) {
        ensureLoaded()
        val orderedKeys = definitions
            .sortedBy { definition -> preferences[definition.key]?.order ?: Int.MAX_VALUE }
            .map { it.key }
            .toMutableList()
        if (fromIndex !in orderedKeys.indices || toIndex !in orderedKeys.indices) return
        if (fromIndex == toIndex) return
        orderedKeys.add(toIndex, orderedKeys.removeAt(fromIndex))
        orderedKeys.forEachIndexed { newIndex, sectionKey ->
            val current = preferences[sectionKey] ?: return@forEachIndexed
            preferences[sectionKey] = current.copy(order = newIndex)
        }
        publish()
        persist()
    }

    private fun updatePreference(
        key: MetaScreenSectionKey,
        transform: (StoredMetaScreenSectionPreference) -> StoredMetaScreenSectionPreference,
    ) {
        ensureLoaded()
        val current = preferences[key] ?: return
        preferences[key] = transform(current)
        publish()
        persist()
    }

    private fun normalizePreferences() {
        val normalized = mutableMapOf<MetaScreenSectionKey, StoredMetaScreenSectionPreference>()
        definitions.sortedBy { definition -> preferences[definition.key]?.order ?: Int.MAX_VALUE }
            .forEachIndexed { index, definition ->
                val stored = preferences[definition.key]
                normalized[definition.key] = StoredMetaScreenSectionPreference(
                    key = definition.key.name,
                    enabled = stored?.enabled ?: true,
                    order = index,
                    tabGroup = stored?.tabGroup,
                )
            }
        preferences = normalized
    }

    private fun publish() {
        _uiState.value = MetaScreenSettingsUiState(
            items = definitions
                .sortedBy { definition -> preferences[definition.key]?.order ?: Int.MAX_VALUE }
                .map { definition ->
                    val preference = preferences[definition.key]
                    MetaScreenSectionItem(
                        key = definition.key,
                        title = resourceString(definition.titleFallback, definition.titleKey),
                        description = resourceString(definition.descriptionFallback, definition.descriptionKey),
                        enabled = preference?.enabled ?: true,
                        order = preference?.order ?: 0,
                        tabGroup = preference?.tabGroup,
                    )
                },
            backgroundMode = backgroundMode,
            cinematicBackground = backgroundMode.usesBackdropBackground,
            heroTrailerPlayback = heroTrailerPlayback,
            tabLayout = tabLayout,
            episodeCardStyle = episodeCardStyle,
            blurUnwatchedEpisodes = blurUnwatchedEpisodes,
            showOverallRatings = showOverallRatings,
            episodeRatingsVisibility = episodeRatingsVisibility,
        )
    }

    private fun persist() {
        MetaScreenSettingsStorage.savePayload(
            json.encodeToString(
                StoredMetaScreenSettingsPayload(
                    items = preferences.values.sortedBy { it.order },
                    backgroundMode = MetaScreenBackgroundMode.persist(backgroundMode),
                    cinematicBackground = backgroundMode.usesBackdropBackground,
                    heroTrailerPlayback = heroTrailerPlayback,
                    tabLayout = tabLayout,
                    episodeCardStyle = MetaEpisodeCardStyle.persist(episodeCardStyle),
                    blurUnwatchedEpisodes = blurUnwatchedEpisodes,
                    showOverallRatings = showOverallRatings,
                    episodeRatingsVisibility = episodeRatingsVisibility.name,
                ),
            ),
        )
    }
}
