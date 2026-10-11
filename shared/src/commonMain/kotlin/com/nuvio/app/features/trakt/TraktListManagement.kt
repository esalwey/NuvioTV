package com.nuvio.app.features.trakt

import com.nuvio.app.features.tracking.LibraryListPrivacy
import com.nuvio.app.features.tracking.TrackingListManagementCapabilities
import com.nuvio.app.features.tracking.TrackingListManager
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal const val TRAKT_PERSONAL_LIST_KEY_PREFIX = "trakt:list:"

/**
 * Trakt's own-list management, behind the provider-neutral [TrackingListManager] port.
 * Every call forwards to [TraktLibraryRepository], which owns the HTTP calls and the cached
 * list state (optimistic update, rollback on failure).
 */
internal object TraktListManager : TrackingListManager {
    override val capabilities = TrackingListManagementCapabilities(
        privacyOptions = LibraryListPrivacy.entries,
        supportsDescription = true,
        supportsReordering = true,
    )

    override suspend fun createList(name: String, description: String?, privacy: LibraryListPrivacy) =
        TraktLibraryRepository.createPersonalList(name, description, privacy)

    override suspend fun updateList(key: String, name: String, description: String?, privacy: LibraryListPrivacy) =
        TraktLibraryRepository.updatePersonalList(key, name, description, privacy)

    override suspend fun deleteList(key: String) = TraktLibraryRepository.deletePersonalList(key)

    override suspend fun reorderLists(keys: List<String>) = TraktLibraryRepository.reorderPersonalLists(keys)
}

/** The list id a personal list key addresses in `users/me/lists/{id}` (a Trakt id or a slug). */
internal fun traktPersonalListId(key: String): String {
    require(key.startsWith(TRAKT_PERSONAL_LIST_KEY_PREFIX)) { "Not a Trakt personal list: $key" }
    return key.removePrefix(TRAKT_PERSONAL_LIST_KEY_PREFIX).also { id ->
        require(id.isNotBlank()) { "Not a Trakt personal list: $key" }
    }
}

/**
 * JSON body of `POST users/me/lists` and `PUT users/me/lists/{id}`.
 *
 * [clearEmptyDescription] is for an update: a blank description is sent as an empty string, which
 * is how Trakt clears it (omitting the field would keep the old text).
 */
internal fun traktListRequestBody(
    name: String,
    description: String?,
    privacy: LibraryListPrivacy,
    clearEmptyDescription: Boolean,
): String {
    val fields = linkedMapOf<String, kotlinx.serialization.json.JsonElement>(
        "name" to JsonPrimitive(name.trim()),
    )
    val trimmedDescription = description?.trim().orEmpty()
    if (trimmedDescription.isNotEmpty() || clearEmptyDescription) {
        fields["description"] = JsonPrimitive(trimmedDescription)
    }
    fields["privacy"] = JsonPrimitive(privacy.apiValue)
    return JsonObject(fields).toString()
}

/** JSON body of `POST users/me/lists/reorder`: the numeric Trakt ids, in the wanted order. */
internal fun traktReorderRequestBody(orderedKeys: List<String>): String {
    val ids = orderedKeys.map { key ->
        traktPersonalListId(key).toLongOrNull()
            ?: throw IllegalArgumentException("Trakt can only reorder lists that have a numeric id: $key")
    }
    return JsonObject(mapOf("rank" to JsonArray(ids.map(::JsonPrimitive)))).toString()
}

/**
 * [tabs] with the personal lists rearranged to [orderedKeys]. Non-personal tabs (the watchlist)
 * keep their place at the front; a personal list [orderedKeys] does not mention keeps its
 * relative order after the ones it does.
 */
internal fun reorderedTraktTabs(tabs: List<TraktListTab>, orderedKeys: List<String>): List<TraktListTab> {
    val personal = tabs.filter { it.type == TraktListType.PERSONAL }
    val byKey = personal.associateBy { it.key }
    val ordered = orderedKeys.distinct().mapNotNull(byKey::get)
    val orderedKeySet = ordered.mapTo(hashSetOf()) { it.key }
    val rest = personal.filterNot { it.key in orderedKeySet }
    return tabs.filter { it.type != TraktListType.PERSONAL } + ordered + rest
}
