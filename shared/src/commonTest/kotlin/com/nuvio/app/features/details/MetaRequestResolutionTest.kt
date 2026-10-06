package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Regression coverage for BUG-7: the tvOS detail page hung forever because the addon-returned
 * meta id (tt…) differed from the preview id (tmdb:…), desyncing the stale-publish guard from
 * the request the UI was actually waiting on. The fix threads a `requestKey` built from the
 * ORIGINAL id through every [MetaDetailsUiState] publish, guarded by comparing against
 * `activeRequestKey`. These tests cover the pure logic extracted into [MetaRequestResolution].
 */
class MetaRequestResolutionTest {

    // ---- requestKey construction ----

    @Test
    fun `requestKey combines type and id with a colon`() {
        assertEquals("movie:tt1234567", MetaRequestResolution.requestKey("movie", "tt1234567"))
    }

    @Test
    fun `requestKey is built from the original id and not any remapped lookup id`() {
        // The whole point of BUG-7's fix: the preview arrives as tmdb:603, the addon later
        // returns tt0133093 as the canonical meta id — but the requestKey used to correlate the
        // in-flight load() with its eventual publish must stay pinned to the ORIGINAL id the
        // caller asked for, so it never drifts once resolveMetaLookupId() remaps it internally.
        val originalId = "tmdb:603"
        val remappedLookupId = "tt0133093"

        val requestKey = MetaRequestResolution.requestKey("movie", originalId)

        assertEquals("movie:tmdb:603", requestKey)
        assertTrue(originalId != remappedLookupId)
        assertFalse(requestKey.contains(remappedLookupId))
    }

    @Test
    fun `requestKey differs for different types with the same id`() {
        val movieKey = MetaRequestResolution.requestKey("movie", "tt1234567")
        val seriesKey = MetaRequestResolution.requestKey("series", "tt1234567")
        assertTrue(movieKey != seriesKey)
    }

    // ---- tmdb-prefix detection / parsing ----

    @Test
    fun `parseTmdbId parses a valid tmdb-prefixed id`() {
        assertEquals(603, MetaRequestResolution.parseTmdbId("tmdb:603"))
    }

    @Test
    fun `parseTmdbId is case-insensitive on the prefix`() {
        assertEquals(603, MetaRequestResolution.parseTmdbId("TMDB:603"))
        assertEquals(603, MetaRequestResolution.parseTmdbId("Tmdb:603"))
    }

    @Test
    fun `parseTmdbId stops at a second colon for a tmdb id with trailing season-episode suffix`() {
        assertEquals(603, MetaRequestResolution.parseTmdbId("tmdb:603:1:2"))
    }

    @Test
    fun `parseTmdbId returns null for a blank id after the prefix`() {
        assertNull(MetaRequestResolution.parseTmdbId("tmdb:"))
    }

    @Test
    fun `parseTmdbId returns null for a non-numeric id after the prefix`() {
        assertNull(MetaRequestResolution.parseTmdbId("tmdb:abc"))
    }

    @Test
    fun `parseTmdbId returns null for a non-tmdb id`() {
        assertNull(MetaRequestResolution.parseTmdbId("tt1234567"))
    }

    @Test
    fun `parseTmdbId returns null for a prefix-like substring that is not a leading prefix`() {
        assertNull(MetaRequestResolution.parseTmdbId("nottmdb:603"))
    }

    @Test
    fun `parseTmdbId returns null for an empty string`() {
        assertNull(MetaRequestResolution.parseTmdbId(""))
    }

    @Test
    fun `needsRemap mirrors parseTmdbId success`() {
        assertTrue(MetaRequestResolution.needsRemap("tmdb:603"))
        assertFalse(MetaRequestResolution.needsRemap("tt1234567"))
        assertFalse(MetaRequestResolution.needsRemap("tmdb:"))
    }

    // ---- stale-guard predicate semantics ----

    @Test
    fun `isActiveRequest is true when active key matches own key`() {
        val key = MetaRequestResolution.requestKey("movie", "tmdb:603")
        assertTrue(MetaRequestResolution.isActiveRequest(activeRequestKey = key, ownRequestKey = key))
    }

    @Test
    fun `isActiveRequest is false once a newer load call changes the active key`() {
        // Simulates the exact BUG-7 race: this request's own key was captured at load() time;
        // by the time its async publish runs, a newer load() call (e.g. the user navigated to
        // a different title) has overwritten activeRequestKey. The stale publish must be dropped.
        val ownKey = MetaRequestResolution.requestKey("movie", "tmdb:603")
        val newerActiveKey = MetaRequestResolution.requestKey("series", "tt9999999")

        assertFalse(
            MetaRequestResolution.isActiveRequest(activeRequestKey = newerActiveKey, ownRequestKey = ownKey),
        )
    }

    @Test
    fun `isActiveRequest is false when active key has been cleared to null`() {
        val ownKey = MetaRequestResolution.requestKey("movie", "tmdb:603")
        assertFalse(MetaRequestResolution.isActiveRequest(activeRequestKey = null, ownRequestKey = ownKey))
    }

    @Test
    fun `isActiveRequest compares requestKeys and is unaffected by internal lookup id remapping`() {
        // requestKey is always built from the original id (see above), so even though
        // resolveMetaLookupId() may swap tmdb:603 for tt0133093 behind the scenes for the addon
        // fetch, the requestKey used in the stale-guard never reflects that remap.
        val originalRequestKey = MetaRequestResolution.requestKey("movie", "tmdb:603")
        val sameOriginalRequestKeyAgain = MetaRequestResolution.requestKey("movie", "tmdb:603")

        assertTrue(
            MetaRequestResolution.isActiveRequest(
                activeRequestKey = originalRequestKey,
                ownRequestKey = sameOriginalRequestKeyAgain,
            ),
        )
    }
}
