package com.nuvio.app.features.search

import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.HomeCatalogSection

enum class SearchEmptyStateReason {
    NoActiveAddons,
    NoSearchCatalogs,
    NoResults,
    RequestFailed,
}

data class SearchUiState(
    val isLoading: Boolean = false,
    val sections: List<HomeCatalogSection> = emptyList(),
    val emptyStateReason: SearchEmptyStateReason? = null,
    val errorMessage: String? = null,
    /// BUG-33 defect 1 instrumentation: a compact, human-readable line describing the last
    /// `search()` call's fan-out — how many search-capable catalogs were queried vs. filtered
    /// out by Search Sources, and which ones (display names, not keys). Set by `search()`
    /// right after `buildSearchRequests`; null until the first search of this app session (or
    /// after `clear()`/`reset()`). Shown verbatim in Settings → Content Sources → Search
    /// Sources so a tester can screenshot one line instead of a device log capture.
    val lastFanOut: String? = null,
)

enum class DiscoverEmptyStateReason {
    NoActiveAddons,
    NoDiscoverCatalogs,
    NoResults,
    RequestFailed,
}

/// One search-capable catalog, as shown in the tvOS "Search Sources" settings (FEAT-10).
/// [key] is the stable identity persisted when the user disables a source — same
/// `manifestId:type:catalogId` shape as [DiscoverCatalogOption.key].
data class SearchCatalogOption(
    val key: String,
    val addonName: String,
    val catalogName: String,
    val type: String,
    /// Localized media-type label ("Movies", "Series", …) resolved at construction so UI
    /// layers can render it without reaching back into shared string helpers.
    val typeLabel: String,
)

data class DiscoverCatalogOption(
    val key: String,
    val addonName: String,
    val manifestUrl: String,
    val type: String,
    val catalogId: String,
    val catalogName: String,
    val genreOptions: List<String> = emptyList(),
    val genreRequired: Boolean = false,
    val supportsPagination: Boolean = false,
)

data class DiscoverUiState(
    val typeOptions: List<String> = emptyList(),
    val selectedType: String? = null,
    val catalogOptions: List<DiscoverCatalogOption> = emptyList(),
    val selectedCatalogKey: String? = null,
    val selectedGenre: String? = null,
    val items: List<MetaPreview> = emptyList(),
    val isLoading: Boolean = false,
    val nextSkip: Int? = null,
    val consecutiveDuplicatePages: Int = 0,
    val emptyStateReason: DiscoverEmptyStateReason? = null,
    val errorMessage: String? = null,
) {
    val selectedCatalog: DiscoverCatalogOption?
        get() = catalogOptions.firstOrNull { it.key == selectedCatalogKey }

    val genreOptions: List<String>
        get() = selectedCatalog?.genreOptions.orEmpty()

    val canLoadMore: Boolean
        get() = nextSkip != null
}
