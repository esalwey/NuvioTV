package com.nuvio.app.features.plugins

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

internal const val PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS = 6 * 60 * 60 * 1_000L

internal fun isPluginRepositoryRefreshDue(
    lastUpdatedEpochMs: Long,
    nowEpochMs: Long,
): Boolean {
    val elapsedMs = nowEpochMs - lastUpdatedEpochMs
    // Fork divergence from upstream 0e9a1ebe (Codex 2026-08-24): a FUTURE lastUpdated (clock
    // rollback, or persisted state from a device whose clock ran ahead) makes elapsed negative,
    // which upstream reads as "not due" until real time catches up — treat it as due instead.
    return lastUpdatedEpochMs <= 0L || elapsedMs < 0L || elapsedMs >= PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS
}

@Serializable
data class PluginManifest(
    val name: String,
    val version: String,
    val description: String? = null,
    val author: String? = null,
    val scrapers: List<PluginManifestScraper> = emptyList(),
)

@Serializable
data class PluginManifestScraper(
    val id: String,
    val name: String,
    val description: String? = null,
    val version: String,
    val filename: String,
    @SerialName("supportedTypes") val supportedTypes: List<String> = listOf("movie", "tv"),
    val enabled: Boolean = true,
    val hasSettings: Boolean = false,
    val logo: String? = null,
    @SerialName("contentLanguage") val contentLanguage: List<String>? = null,
    @SerialName("supportedPlatforms") val supportedPlatforms: List<String>? = null,
    @SerialName("disabledPlatforms") val disabledPlatforms: List<String>? = null,
    val formats: List<String>? = null,
    @SerialName("supportedFormats") val supportedFormats: List<String>? = null,
    @SerialName("supportsExternalPlayer") val supportsExternalPlayer: Boolean? = null,
    val limited: Boolean? = null,
)

data class PluginRepositoryItem(
    val manifestUrl: String,
    val name: String,
    val description: String? = null,
    val version: String? = null,
    val scraperCount: Int = 0,
    val lastUpdated: Long = 0L,
    val isRefreshing: Boolean = false,
    val errorMessage: String? = null,
)

/**
 * One row of the `sync_push_plugins` RPC payload. Lives in commonMain (rather than next to the
 * tvosMain producer) so [buildPluginPushSnapshot] is unit-testable from commonTest.
 */
@Serializable
internal data class PluginPushItem(
    val url: String,
    val name: String = "",
    val enabled: Boolean = true,
    @SerialName("sort_order") val sortOrder: Int = 0,
)

/**
 * A push payload paired with the profile row it was computed under. Both halves must be captured
 * in the same synchronous frame as the mutation that triggered the push — the upload coroutine
 * runs later, and a profile switch can reset the repository state in between, so a push that
 * re-reads live state at execution time uploads the new profile's (or the empty transitional)
 * list over whichever remote row the current profile id points at by then.
 */
internal data class PluginPushSnapshot(
    val profileId: Int,
    val items: List<PluginPushItem>,
)

internal fun buildPluginPushSnapshot(
    profileId: Int,
    repositories: List<PluginRepositoryItem>,
): PluginPushSnapshot = PluginPushSnapshot(
    profileId = profileId,
    items = repositories.mapIndexed { index, repo ->
        PluginPushItem(
            url = repo.manifestUrl,
            name = repo.name,
            enabled = true,
            sortOrder = index,
        )
    },
)

data class PluginScraper(
    val id: String,
    val repositoryUrl: String,
    val name: String,
    val description: String,
    val version: String,
    val filename: String,
    val supportedTypes: List<String>,
    val enabled: Boolean,
    val manifestEnabled: Boolean,
    val hasSettings: Boolean = false,
    val logo: String? = null,
    val contentLanguage: List<String> = emptyList(),
    val formats: List<String>? = null,
    val code: String,
) {
    fun supportsType(type: String): Boolean {
        val normalizedType = normalizePluginType(type)
        return supportedTypes.map { normalizePluginType(it) }.contains(normalizedType)
    }
}

data class PluginRuntimeResult(
    val title: String,
    val name: String? = null,
    val url: String,
    val quality: String? = null,
    val size: String? = null,
    val language: String? = null,
    val provider: String? = null,
    val type: String? = null,
    val seeders: Int? = null,
    val peers: Int? = null,
    val infoHash: String? = null,
    val headers: Map<String, String>? = null,
    val subtitles: List<PluginSubtitleResult>? = null,
)

@Serializable
data class PluginSubtitleResult(
    val url: String,
    val language: String,
    val name: String? = null,
    val headers: Map<String, String>? = null
)

data class PluginsUiState(
    val pluginsEnabled: Boolean = true,
    val groupStreamsByRepository: Boolean = false,
    val repositories: List<PluginRepositoryItem> = emptyList(),
    val scrapers: List<PluginScraper> = emptyList(),
)

sealed interface AddPluginRepositoryResult {
    data class Success(val repository: PluginRepositoryItem) : AddPluginRepositoryResult
    data class Error(val message: String) : AddPluginRepositoryResult
}

@Serializable
data class StoredPluginsState(
    val pluginsEnabled: Boolean = true,
    val groupStreamsByRepository: Boolean = false,
    val repositories: List<StoredPluginRepository> = emptyList(),
    val scrapers: List<StoredPluginScraper> = emptyList(),
)

@Serializable
data class StoredPluginRepository(
    val manifestUrl: String,
    val name: String,
    val description: String? = null,
    val version: String? = null,
    val scraperCount: Int = 0,
    val lastUpdated: Long = 0L,
)

@Serializable
data class StoredPluginScraper(
    val id: String,
    val repositoryUrl: String,
    val name: String,
    val description: String,
    val version: String,
    val filename: String,
    val supportedTypes: List<String>,
    val enabled: Boolean,
    val manifestEnabled: Boolean,
    val hasSettings: Boolean = false,
    val logo: String? = null,
    val contentLanguage: List<String> = emptyList(),
    val formats: List<String>? = null,
    val code: String,
)

fun normalizePluginType(value: String): String =
    when (value.lowercase()) {
        "series", "show", "other" -> "tv"
        else -> value.lowercase()
    }
