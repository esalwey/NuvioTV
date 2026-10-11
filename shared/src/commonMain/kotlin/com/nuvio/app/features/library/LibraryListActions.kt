package com.nuvio.app.features.library

import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.toggleTrackingLibraryMembership
import com.nuvio.app.features.tracking.trackingMembershipDestinations

/** One row of the "Lists" picker: a connected tracking provider's list and whether the title is on it. */
data class LibraryListChoice(
    val key: String,
    val title: String,
    val isMember: Boolean,
)

/** The picker rows for [tabs] (membership destinations only), in the providers' own order. */
fun libraryListChoices(
    tabs: List<TrackingLibraryTab>,
    membership: Map<String, Boolean>,
): List<LibraryListChoice> =
    trackingMembershipDestinations(tabs).map { tab ->
        LibraryListChoice(
            key = tab.key,
            title = tab.title,
            isMember = membership[tab.key] == true,
        )
    }

/**
 * Entry points the tvOS poster context menu calls to add a title to, or remove it from, the lists of
 * a connected tracking provider (Trakt watchlist and personal lists today).
 *
 * The suspend functions are `@Throws(Throwable)`: a network failure reaches the Swift completion
 * handler as an `NSError` instead of terminating the process, which is what an exported suspend
 * function without `@Throws` does with any exception other than cancellation.
 */
object LibraryListActions {
    /** True when a connected provider offers at least one list this title can be put on. */
    fun isAvailable(item: LibraryItem): Boolean {
        LibraryRepository.ensureLoaded()
        return trackingMembershipDestinations(LibraryRepository.libraryListTabs(item)).isNotEmpty()
    }

    /** The lists the title can be put on, each with its current membership. */
    @Throws(Throwable::class)
    suspend fun choices(item: LibraryItem): List<LibraryListChoice> {
        val tabs = LibraryRepository.libraryListTabs(item)
        return libraryListChoices(tabs, LibraryRepository.getMembershipSnapshot(item))
    }

    /**
     * Flips the title's membership of the list [key] (a single-choice group such as a status list
     * deselects its siblings), applies it, and returns the rows as they stand afterwards.
     */
    @Throws(Throwable::class)
    suspend fun toggle(item: LibraryItem, key: String): List<LibraryListChoice> {
        val tabs = LibraryRepository.libraryListTabs(item)
        val current = LibraryRepository.getMembershipSnapshot(item)
        val desired = toggleTrackingLibraryMembership(tabs = tabs, membership = current, key = key)
        if (desired != current) {
            LibraryRepository.applyMembershipChanges(item, desired)
        }
        return libraryListChoices(tabs, LibraryRepository.getMembershipSnapshot(item))
    }
}
