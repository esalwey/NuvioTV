package com.nuvio.app.features.mdblist

import com.nuvio.app.features.library.LibraryItem

internal class MdbListLibraryProjection(snapshot: MdbListLibrarySnapshot) {
    /** One entry per title, with the keys of every list it is in. */
    val entries: List<LibraryItem>
    private val identities = mutableMapOf<Pair<MdbListItemType, String>, String>()
    private val entriesByIdentity: Map<String, LibraryItem>
    private val memberships = mutableMapOf<Pair<MdbListItemType, String>, Set<String>>()

    /** Entry identities of each list, in the order the list is saved on mdblist.com. */
    private val orderByList = linkedMapOf<String, List<String>>()

    init {
        val index = MdbListMediaIndex(MdbListSyncSnapshot(0))
        snapshot.itemsByList.values.flatten().forEach { index.add(it.type, it.media) }
        val combined = linkedMapOf<String, LibraryItem>()
        snapshot.itemsByList.forEach { (listKey, items) ->
            val order = mutableListOf<String>()
            items.forEach { item ->
                val media = index.resolve(item.type, item.media.ids)
                val key = "${item.type}:${media.ids.key}"
                val previous = combined[key]
                val listKeys = previous?.listKeys.orEmpty() + listKey
                order += key
                combined[key] = LibraryItem(
                    id = media.ids.contentId,
                    type = if (item.type == MdbListItemType.MOVIE) "movie" else "series",
                    name = media.title ?: media.ids.contentId,
                    poster = media.poster,
                    banner = media.backdrop,
                    logo = null,
                    description = previous?.description ?: item.description,
                    releaseInfo = media.year?.toString(),
                    imdbRating = null,
                    genres = (previous?.genres.orEmpty() + item.genres).distinct(),
                    addonBaseUrl = null,
                    listKeys = listKeys,
                    savedAtEpochMs = maxOf(previous?.savedAtEpochMs ?: 0, item.listedAt),
                    imdbId = media.ids.imdb,
                    tmdbId = media.ids.tmdb?.takeIf { it <= Int.MAX_VALUE }?.toInt(),
                    traktId = media.ids.trakt?.takeIf { it <= Int.MAX_VALUE }?.toInt(),
                    trackingProviderId = "mdblist",
                    trackingProviderItemId = media.ids.mdblist,
                    trackingSourceUrl = media.sourceUrl(item.type)
                )
                media.ids.aliases().forEach { alias ->
                    memberships[item.type to alias] = listKeys
                    identities[item.type to alias] = key
                }
            }
            orderByList[listKey] = order.distinct()
        }
        entriesByIdentity = combined
        entries = combined.values.toList()
    }

    /**
     * The titles of one list in the order they are saved on mdblist.com (the provider order),
     * each carrying its position as [LibraryItem.traktRank] so the library's default sort keeps
     * that order.
     */
    fun section(listKey: String): List<LibraryItem> =
        orderByList[listKey].orEmpty().mapIndexedNotNull { position, key ->
            entriesByIdentity[key]?.copy(traktRank = position)
        }

    fun find(id: String, type: String? = null): LibraryItem? {
        val types = if (type == null) listOf(MdbListItemType.MOVIE, MdbListItemType.SHOW)
            else listOfNotNull(mdbListLibraryType(type))
        return types.firstNotNullOfOrNull { mediaType -> identities[mediaType to id]?.let(entriesByIdentity::get) }
    }

    fun membership(id: String, type: String): Set<String> = memberships[mdbListLibraryType(type) to id].orEmpty()
}
