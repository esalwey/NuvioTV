package com.nuvio.app.features.catalog

import com.nuvio.app.features.library.LibrarySortOption
import kotlinx.serialization.Serializable

sealed interface CatalogTarget {
    val contentType: String
    val supportsPagination: Boolean

    data class Addon(
        val manifestUrl: String,
        override val contentType: String,
        val catalogId: String,
        val genre: String? = null,
        /// BUG-48 (beta.12): the search term the catalog was queried with, threaded through to
        /// `fetchCatalogPage` so an expanded search-result row fetches the SEARCHED catalog. It
        /// was silently dropped here before: search-only addon catalogs returned nothing
        /// unfiltered (the empty grid behind BUG-47's tab-bar eject on tvOS), and browsable ones
        /// showed unfiltered titles under a searched row's name. Part of the data class, so
        /// request identity/equality — including UX-13's cross-push restoration keying, which
        /// compares `CatalogRequest`s — distinguishes queries for free. Null = a plain
        /// (non-search) catalog fetch, byte-identical to prior behavior.
        val search: String? = null,
        override val supportsPagination: Boolean = false,
    ) : CatalogTarget

    data class Library(
        override val contentType: String,
        val sectionType: String,
        val sortOption: LibrarySortOption = LibrarySortOption.DEFAULT,
    ) : CatalogTarget {
        override val supportsPagination: Boolean = false
    }

    data class CollectionSource(
        val collectionId: String,
        val folderId: String,
        val sourceKey: String,
        override val contentType: String,
        override val supportsPagination: Boolean = false,
    ) : CatalogTarget
}

@Serializable
enum class CatalogTargetKind {
    ADDON,
    LIBRARY,
    COLLECTION_SOURCE,
}
