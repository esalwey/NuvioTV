package com.nuvio.app.features.tracking

import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.trakt.TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * BUG-75: the presence-gated decode of the shared tracking-source namespace. Modeled on
 * `HomeCatalogSettingsSyncServiceTest`. The local selection deliberately differs from the shipped
 * defaults so "preserved local" and "fell back to the default" cannot be confused. The
 * cached-remote push merge this class used to cover lives in
 * [com.nuvio.app.core.sync.SharedSettingsSyncSupportTest] since the helper was deduplicated.
 */
class TrackingSourceSettingsSyncServiceTest {

    private val local = TrackingSourceSelection(
        watchProgressSource = WatchProgressSource.SIMKL,
        librarySourceMode = LibrarySourceMode.SIMKL,
        continueWatchingDaysCap = 60,
    )

    @Test
    fun `present remote keys override the local selection`() {
        val remote = buildJsonObject {
            put("watch_progress_source", "TRAKT")
            put("library_source_mode", "LOCAL")
            put("continue_watching_days_cap", 30)
        }

        val decoded = decodeTrackingSourceSelectionPreservingLocal(remote, local)

        assertEquals(
            TrackingSourceSelection(
                watchProgressSource = WatchProgressSource.TRAKT,
                librarySourceMode = LibrarySourceMode.LOCAL,
                continueWatchingDaysCap = 30,
            ),
            decoded,
        )
    }

    @Test
    fun `absent library source mode preserves the local one`() {
        val remote = buildJsonObject {
            put("watch_progress_source", "NUVIO_SYNC")
            put("continue_watching_days_cap", TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL)
        }

        val decoded = decodeTrackingSourceSelectionPreservingLocal(remote, local)

        assertEquals(WatchProgressSource.NUVIO_SYNC, decoded?.watchProgressSource)
        assertEquals(LibrarySourceMode.SIMKL, decoded?.librarySourceMode)
        assertEquals(TRAKT_CONTINUE_WATCHING_DAYS_CAP_ALL, decoded?.continueWatchingDaysCap)
    }

    @Test
    fun `absent days cap preserves the local one`() {
        val remote = buildJsonObject {
            put("watch_progress_source", "TRAKT")
            put("library_source_mode", "LOCAL")
        }

        val decoded = decodeTrackingSourceSelectionPreservingLocal(remote, local)

        assertEquals(LibrarySourceMode.LOCAL, decoded?.librarySourceMode)
        assertEquals(local.continueWatchingDaysCap, decoded?.continueWatchingDaysCap)
    }

    @Test
    fun `a remote blob modelling none of the keys preserves everything`() {
        val remote = buildJsonObject {
            put("future_setting", "preserved")
        }

        assertEquals(local, decodeTrackingSourceSelectionPreservingLocal(remote, local))
    }

    @Test
    fun `days cap out of range is normalized`() {
        val remote = buildJsonObject {
            put("continue_watching_days_cap", 9999)
        }

        assertEquals(365, decodeTrackingSourceSelectionPreservingLocal(remote, local)?.continueWatchingDaysCap)
    }

    @Test
    fun `malformed enum strings fall back through the storage decoders`() {
        val remote = buildJsonObject {
            put("watch_progress_source", "not-a-source")
            put("library_source_mode", "not-a-mode")
        }

        val decoded = decodeTrackingSourceSelectionPreservingLocal(remote, local)

        assertEquals(DEFAULT_WATCH_PROGRESS_SOURCE, decoded?.watchProgressSource)
        assertEquals(DEFAULT_LIBRARY_SOURCE_MODE, decoded?.librarySourceMode)
    }
}
