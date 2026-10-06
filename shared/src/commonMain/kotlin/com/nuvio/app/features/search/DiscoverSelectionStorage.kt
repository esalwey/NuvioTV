package com.nuvio.app.features.search

expect object DiscoverSelectionStorage {
    fun loadCatalogKey(): String?
    fun saveCatalogKey(catalogKey: String)
}
