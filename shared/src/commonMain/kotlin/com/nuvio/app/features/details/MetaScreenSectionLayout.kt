package com.nuvio.app.features.details

/**
 * Which detail-page sections an Apple TV shows, and in what order.
 *
 * The synced default order (`MetaScreenSectionKey` declaration order) is the phone's: Cast,
 * Comments and Trailers sit above Episodes. On a television the episode shelf is the heart of a
 * series page, so while the stored order is still that untouched default the TV uses its own
 * default instead. As soon as the order is changed (here or on another device) the stored order is
 * followed to the letter.
 */
object MetaScreenSectionLayout {
    /** The order every profile starts with (and the one a reset restores). */
    val syncedDefaultOrder: List<MetaScreenSectionKey> = MetaScreenSectionKey.entries.toList()

    /** The Apple TV's own default: episodes straight under the header, comments near the end. */
    val televisionDefaultOrder: List<MetaScreenSectionKey> = listOf(
        MetaScreenSectionKey.ACTIONS,
        MetaScreenSectionKey.OVERVIEW,
        MetaScreenSectionKey.PRODUCTION,
        MetaScreenSectionKey.EPISODES,
        MetaScreenSectionKey.CAST,
        MetaScreenSectionKey.COLLECTION,
        MetaScreenSectionKey.TRAILERS,
        MetaScreenSectionKey.MORE_LIKE_THIS,
        MetaScreenSectionKey.COMMENTS,
        MetaScreenSectionKey.DETAILS,
    )

    /** [items] (stored order) as the TV presents them. */
    fun effectiveItems(items: List<MetaScreenSectionItem>): List<MetaScreenSectionItem> {
        if (items.map { it.key } != syncedDefaultOrder) return items
        val byKey = items.associateBy { it.key }
        return televisionDefaultOrder.mapNotNull { byKey[it] }
    }

    /** Sections to render below the header, in order: enabled, minus the two header sections. */
    fun lowerSectionKeys(items: List<MetaScreenSectionItem>): List<MetaScreenSectionKey> =
        effectiveItems(items)
            .filter { it.enabled && it.key != MetaScreenSectionKey.ACTIONS && it.key != MetaScreenSectionKey.OVERVIEW }
            .map { it.key }

    /** Whether [key] is switched on (a key missing from [items] counts as on, the default). */
    fun isEnabled(items: List<MetaScreenSectionItem>, key: MetaScreenSectionKey): Boolean =
        items.firstOrNull { it.key == key }?.enabled ?: true

    /**
     * Full section order after moving [key] one step among the sections that are free to move
     * (everything except Actions and Overview, which stay in the header), as the input of
     * [MetaScreenSettingsRepository.setOrder]. Returns the unchanged order at either end.
     */
    fun orderAfterMoving(
        items: List<MetaScreenSectionItem>,
        key: MetaScreenSectionKey,
        up: Boolean,
    ): List<MetaScreenSectionKey> {
        val order = effectiveItems(items).map { it.key }
        val movable = order.filter { it != MetaScreenSectionKey.ACTIONS && it != MetaScreenSectionKey.OVERVIEW }
        val index = movable.indexOf(key)
        if (index < 0) return order
        val target = if (up) index - 1 else index + 1
        if (target !in movable.indices) return order
        val swapped = movable.toMutableList().also {
            it[index] = movable[target]
            it[target] = key
        }
        // Splice the reordered movable sections back into the slots the movable ones occupied.
        var cursor = 0
        return order.map { original ->
            if (original == MetaScreenSectionKey.ACTIONS || original == MetaScreenSectionKey.OVERVIEW) {
                original
            } else {
                swapped[cursor++]
            }
        }
    }
}
