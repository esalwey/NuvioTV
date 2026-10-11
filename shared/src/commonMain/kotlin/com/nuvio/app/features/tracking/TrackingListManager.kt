package com.nuvio.app.features.tracking

/** Who can see a user-managed list on its provider. Wire values match Trakt's `privacy` field. */
enum class LibraryListPrivacy(val apiValue: String) {
    PRIVATE("private"),
    LINK("link"),
    FRIENDS("friends"),
    PUBLIC("public");

    companion object {
        fun fromApi(value: String?): LibraryListPrivacy =
            entries.firstOrNull { it.apiValue.equals(value?.trim(), ignoreCase = true) } ?: PRIVATE
    }
}

/** What a provider's list management supports, so the UI only offers what will work. */
data class TrackingListManagementCapabilities(
    val privacyOptions: List<LibraryListPrivacy>,
    val supportsDescription: Boolean = false,
    val supportsReordering: Boolean = false,
)

/**
 * Create / rename / delete / reorder of the user's own lists on a tracking provider.
 *
 * Optional port: a [TrackingLibraryProvider] that returns null from `listManager` does not
 * support list management (Simkl lists are fixed watch statuses, not user lists).
 */
interface TrackingListManager {
    val capabilities: TrackingListManagementCapabilities
    suspend fun createList(name: String, description: String?, privacy: LibraryListPrivacy)
    suspend fun updateList(key: String, name: String, description: String?, privacy: LibraryListPrivacy)
    suspend fun deleteList(key: String)
    suspend fun reorderLists(keys: List<String>) {
        throw UnsupportedOperationException("This provider does not support list reordering")
    }
}
