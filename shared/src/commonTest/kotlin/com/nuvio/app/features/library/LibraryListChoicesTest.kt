package com.nuvio.app.features.library

import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlin.test.Test
import kotlin.test.assertEquals

class LibraryListChoicesTest {
    @Test
    fun `choices follow the tab order and carry the title membership`() {
        val tabs = listOf(
            tab("trakt:watchlist", "Watchlist", TrackingLibraryTabKind.WATCHLIST),
            tab("trakt:list:1", "Favourites", TrackingLibraryTabKind.PERSONAL),
        )

        val choices = libraryListChoices(
            tabs = tabs,
            membership = mapOf("trakt:watchlist" to false, "trakt:list:1" to true),
        )

        assertEquals(
            listOf(
                LibraryListChoice("trakt:watchlist", "Watchlist", isMember = false),
                LibraryListChoice("trakt:list:1", "Favourites", isMember = true),
            ),
            choices,
        )
    }

    @Test
    fun `a list missing from the snapshot reads as not a member`() {
        val choices = libraryListChoices(
            tabs = listOf(tab("trakt:list:2", "Weekend", TrackingLibraryTabKind.PERSONAL)),
            membership = emptyMap(),
        )

        assertEquals(false, choices.single().isMember)
    }

    @Test
    fun `tabs that are not membership destinations are left out`() {
        val hidden = tab("trakt:completed", "Completed", TrackingLibraryTabKind.STATUS)
            .copy(isMembershipDestination = false)

        val choices = libraryListChoices(
            tabs = listOf(tab("trakt:watchlist", "Watchlist", TrackingLibraryTabKind.WATCHLIST), hidden),
            membership = mapOf("trakt:watchlist" to true, "trakt:completed" to true),
        )

        assertEquals(listOf("trakt:watchlist"), choices.map(LibraryListChoice::key))
    }

    private fun tab(key: String, title: String, kind: TrackingLibraryTabKind) = TrackingLibraryTab(
        key = key,
        title = title,
        providerId = TrackingProviderId.TRAKT,
        kind = kind,
    )
}
