package com.nuvio.app.features.mdblist

import com.nuvio.app.features.library.LibrarySortOption
import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.library.availableLibrarySortOptions
import com.nuvio.app.features.library.sortLibraryItems
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.tracking.effectiveLibrarySourceMode
import com.nuvio.app.features.tracking.effectiveWatchProgressSource
import com.nuvio.app.features.tracking.librarySourceModeFromStorage
import com.nuvio.app.features.tracking.parseTrackingExternalIds
import com.nuvio.app.features.tracking.providerId
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** How MDBList plugs into the shared sources, settings, library ordering and next-up rules. */
class MdbListIntegrationTest {
    // -- Ratings credential: a typed API key overrides the connected account ---------------------

    private val connected = MdbListAuthState(scope = MdbListAuthScope(1, 3), isAuthenticated = true)

    @Test
    fun `ratings need an api key or a connected account`() {
        assertFalse(MdbListSettings(enabled = true).isActive)
        assertNull(MdbListSettings(enabled = true).credential)

        val account = MdbListSettings(enabled = true).withAccount(connected, profileId = 1)
        assertTrue(account.isActive)
        assertEquals(MdbListRatingsCredential.Account(MdbListAuthScope(1, 3)), account.credential)

        assertFalse(MdbListSettings(enabled = false).withAccount(connected, profileId = 1).isActive)
    }

    @Test
    fun `an api key overrides the connected account and clearing it falls back to the account`() {
        val keyed = MdbListSettings(enabled = true, apiKey = " abc ").withAccount(connected, profileId = 1)
        assertEquals(MdbListRatingsCredential.ApiKey("abc"), keyed.credential)

        val cleared = keyed.copy(apiKey = "")
        assertIs<MdbListRatingsCredential.Account>(cleared.credential)
    }

    @Test
    fun `the account only counts for its own profile while authenticated`() {
        assertNull(MdbListSettings(enabled = true).withAccount(connected, profileId = 2).accountScope)
        assertNull(
            MdbListSettings(enabled = true)
                .withAccount(connected.copy(isAuthenticated = false), profileId = 1)
                .accountScope,
        )
    }

    @Test
    fun `credential cache ids never contain the key`() {
        val id = MdbListRatingsCredential.ApiKey("super-secret-key").cacheId
        assertFalse("super-secret-key" in id)
        assertEquals("ApiKey()", MdbListRatingsCredential.ApiKey("super-secret-key").toString())
    }

    // -- Sources -------------------------------------------------------------------------------

    @Test
    fun `mdblist is its own library source and watch progress source`() {
        assertEquals(TrackingProviderId.MDBLIST, LibrarySourceMode.MDBLIST.providerId)
        assertEquals(TrackingProviderId.MDBLIST, WatchProgressSource.MDBLIST.providerId)
        assertEquals(LibrarySourceMode.MDBLIST, librarySourceModeFromStorage("MDBLIST"))
        assertEquals(WatchProgressSource.MDBLIST, WatchProgressSource.fromStorage("MDBLIST"))
        assertEquals(TrackingProviderId.MDBLIST, TrackingProviderId.fromStorage("mdblist"))

        assertEquals(LibrarySourceMode.LOCAL, effectiveLibrarySourceMode(LibrarySourceMode.MDBLIST) { false })
        assertEquals(
            LibrarySourceMode.MDBLIST,
            effectiveLibrarySourceMode(LibrarySourceMode.MDBLIST) { it == TrackingProviderId.MDBLIST },
        )
        assertEquals(WatchProgressSource.NUVIO_SYNC, effectiveWatchProgressSource(WatchProgressSource.MDBLIST) { false })
        assertEquals(
            WatchProgressSource.MDBLIST,
            effectiveWatchProgressSource(WatchProgressSource.MDBLIST) { it == TrackingProviderId.MDBLIST },
        )
    }

    @Test
    fun `mdblist ids round trip through the tracking id parser`() {
        assertEquals("abc12", parseTrackingExternalIds("mdblist:abc12").mdblist)
        assertEquals("abc12", MdbListIds(mdblist = "abc12").aliases().first { it.startsWith("mdblist:") }.removePrefix("mdblist:"))
    }

    // -- Library ordering ----------------------------------------------------------------------

    @Test
    fun `a list keeps the order saved on mdblist and sorts by added date and title`() {
        fun item(title: String, imdb: String, listedAt: Long) = MdbListLibraryItem(
            MdbListItemType.MOVIE, MdbListMedia(MdbListIds(imdb = imdb), title, year = 2000), listedAt = listedAt,
        )
        val projection = MdbListLibraryProjection(
            MdbListLibrarySnapshot(
                itemsByList = mapOf(
                    MDBLIST_TEST_LIST_KEY to listOf(item("Zulu", "tt3", 10), item("Alpha", "tt1", 30), item("Mike", "tt2", 20)),
                ),
            ),
        )
        val section = projection.section(MDBLIST_TEST_LIST_KEY)

        assertTrue(LibrarySortOption.DEFAULT in availableLibrarySortOptions(LibrarySourceMode.MDBLIST))
        assertEquals(
            listOf("Zulu", "Alpha", "Mike"),
            sortLibraryItems(section.shuffled(), LibrarySortOption.DEFAULT, LibrarySourceMode.MDBLIST).map { it.name },
        )
        assertEquals(
            listOf("Alpha", "Mike", "Zulu"),
            sortLibraryItems(section, LibrarySortOption.ADDED_DESC, LibrarySourceMode.MDBLIST).map { it.name },
        )
        assertEquals(
            listOf("Alpha", "Mike", "Zulu"),
            sortLibraryItems(section, LibrarySortOption.TITLE_ASC, LibrarySourceMode.MDBLIST).map { it.name },
        )
    }

    @Test
    fun `library items carry the release year for release sorting`() {
        val projection = MdbListLibraryProjection(
            MdbListLibrarySnapshot(
                itemsByList = mapOf(
                    MDBLIST_WATCHLIST_KEY to listOf(
                        MdbListLibraryItem(
                            MdbListItemType.SHOW, MdbListMedia(MdbListIds(imdb = "tt9"), "Show", year = 2019),
                            releaseDate = "2019-03-01",
                        ),
                    ),
                ),
            ),
        )
        assertEquals("2019", projection.entries.single().releaseInfo)
        assertEquals("series", projection.entries.single().type)
    }

    // -- Next up -------------------------------------------------------------------------------

    @Test
    fun `next up skips episodes of a dropped season but not other seasons`() {
        val episode = mdbListTestEpisode(season = 2, episode = 4)
        fun seeds(dropped: MdbListDroppedRecord) = MdbListProgressProjection(
            MdbListSyncSnapshot(42, watched = listOf(episode), dropped = listOf(dropped)),
        ).nextUpSeeds

        assertTrue(seeds(MdbListDroppedRecord(episode.media.ids, season = 2)).isEmpty())
        assertTrue(seeds(MdbListDroppedRecord(episode.media.ids, season = null)).isEmpty())
        assertEquals(1, seeds(MdbListDroppedRecord(episode.media.ids, season = 3)).size)
    }

    @Test
    fun `local rows with ids mdblist cannot address stay visible in continue watching`() = runTest {
        val h = MdbListSyncTestHarness(backgroundScope)
        val progress = MdbListTrackingProgressProvider(
            h.repository, MdbListScrobbleService(h.http.api, h.repository), h.http.store, h.activeProfile, {},
        )
        assertTrue(progress.canRepresentContentId("tt0111161"))
        assertTrue(progress.canRepresentContentId("tmdb:1396"))
        assertTrue(progress.canRepresentContentId("mdblist:abc"))
        assertFalse(progress.canRepresentContentId("kitsu:42"))
        assertFalse(progress.canRepresentContentId("mal:7"))
    }

    // -- Messages ------------------------------------------------------------------------------

    @Test
    fun `failures map to a readable message`() {
        assertEquals(
            MdbListAuthError.AUTHORIZATION_REVOKED.userMessage(),
            MdbListAuthException(MdbListAuthError.AUTHORIZATION_REVOKED).mdbListUserMessage(),
        )
        assertEquals(
            MdbListSyncError.RATE_LIMIT.userMessage(),
            MdbListApiException(429, "rate_limited").mdbListUserMessage(),
        )
        assertEquals(MdbListSyncError.UNAVAILABLE.userMessage(), IllegalStateException().mdbListUserMessage())
    }
}
