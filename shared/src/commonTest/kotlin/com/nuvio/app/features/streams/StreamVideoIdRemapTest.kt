package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertNull

/**
 * BUG-74. The defect these pin is not subtle once stated — a `tmdb:` id reaches a stream fetch and
 * every `tt`-only addon is filtered out — but it survived three weeks in the wild because the
 * symptom ("no streams, only for some titles, only for me") pointed at addons, metadata language
 * and the reporter's locale before it pointed at an id.
 *
 * Two properties matter and are easy to get wrong:
 *  - **what counts as remappable** — over-matching would send `tt…` ids through a pointless TMDB
 *    round trip, and worse, would make the retry in `StreamsRepository` unbounded, since that
 *    recursion is bounded *only* by `parseTmdbId` refusing the id it re-enters with;
 *  - **the episode suffix survives** — dropping `:1:5` trades an empty stream list for a
 *    different empty stream list, which would have looked like the fix simply not working.
 */
class StreamVideoIdRemapTest {

    @Test
    fun parsesTmdbPrefixedMovieId() {
        assertEquals(1399, StreamVideoIdRemap.parseTmdbId("tmdb:1399"))
    }

    @Test
    fun parsesTmdbPrefixedEpisodeId() {
        assertEquals(1399, StreamVideoIdRemap.parseTmdbId("tmdb:1399:1:5"))
    }

    @Test
    fun acceptsPrefixCaseInsensitively() {
        assertEquals(603, StreamVideoIdRemap.parseTmdbId("TMDB:603"))
    }

    /**
     * The bound on `StreamsRepository`'s retry recursion. The remap always re-enters with a `tt`
     * id, so if this ever started matching, the retry would loop.
     */
    @Test
    fun rejectsImdbId() {
        assertNull(StreamVideoIdRemap.parseTmdbId("tt22338669"))
        assertNull(StreamVideoIdRemap.parseTmdbId("tt22338669:1:5"))
    }

    @Test
    fun rejectsMalformedTmdbIds() {
        assertNull(StreamVideoIdRemap.parseTmdbId("tmdb:"))
        assertNull(StreamVideoIdRemap.parseTmdbId("tmdb:abc"))
        assertNull(StreamVideoIdRemap.parseTmdbId(""))
        // Not prefixed at all — a bare numeric id is Kitsu/other namespaces, not ours to rewrite.
        assertNull(StreamVideoIdRemap.parseTmdbId("1399"))
    }

    @Test
    fun rewritesMovieIdToImdb() {
        assertEquals("tt0944947", StreamVideoIdRemap.withImdbId("tmdb:1399", "tt0944947"))
    }

    @Test
    fun rewritesEpisodeIdKeepingSeasonAndEpisode() {
        assertEquals("tt0944947:1:5", StreamVideoIdRemap.withImdbId("tmdb:1399:1:5", "tt0944947"))
    }

    /** Season-only coordinates are still a suffix; don't special-case the arity. */
    @Test
    fun rewriteKeepsAnySuffixArity() {
        assertEquals("tt0944947:2", StreamVideoIdRemap.withImdbId("tmdb:1399:2", "tt0944947"))
    }

    // ---- per-addon matching (the "addons=1/11" case) ----

    @Test
    fun emptyPrefixListAcceptsAnything() {
        // Manifest convention, not a guess: no declared prefixes means no restriction. This is the
        // addon that kept the reporter's list non-empty and so hid how much was being dropped.
        assertTrue(StreamVideoIdRemap.accepts(emptyList(), "tmdb:550"))
        assertTrue(StreamVideoIdRemap.accepts(emptyList(), "tt0137523"))
    }

    @Test
    fun ttPrefixRejectsTmdbId() {
        assertFalse(StreamVideoIdRemap.accepts(listOf("tt"), "tmdb:550"))
        assertTrue(StreamVideoIdRemap.accepts(listOf("tt"), "tt0137523"))
    }

    /**
     * The exact shape the simulator run recorded: 11 addons, one prefix-less, ten `tt`-only, asked
     * for `tmdb:550` — one match. A "retry when NOTHING matched" net never fires here, which is
     * why the trigger is stated as "some addon was excluded that an IMDb id would reach".
     */
    @Test
    fun remapTriggersEvenWhenOneAddonStillMatched() {
        val prefixes = List(10) { listOf("tt") }
        assertTrue(StreamVideoIdRemap.wouldReachMoreAddons("tmdb:550", prefixes))
    }

    @Test
    fun noRemapWhenEveryAddonAlreadyAcceptsTheTmdbId() {
        assertFalse(StreamVideoIdRemap.wouldReachMoreAddons("tmdb:550", listOf(listOf("tmdb:"))))
        // Prefix-less addons are filtered out before this call (they never contribute), but an
        // empty candidate list must still be a clean "no".
        assertFalse(StreamVideoIdRemap.wouldReachMoreAddons("tmdb:550", emptyList()))
    }

    @Test
    fun noRemapForAnIdThatIsNotTmdbNamespaced() {
        assertFalse(StreamVideoIdRemap.wouldReachMoreAddons("tt0137523", listOf(listOf("tt"))))
        assertFalse(StreamVideoIdRemap.wouldReachMoreAddons("kitsu:42", listOf(listOf("tt"))))
    }

    /** A namespace an IMDb id cannot serve either — remapping would gain nothing. */
    @Test
    fun noRemapWhenExcludedAddonsWantSomeOtherNamespace() {
        assertFalse(StreamVideoIdRemap.wouldReachMoreAddons("tmdb:550", listOf(listOf("kitsu:"))))
    }

    @Test
    fun redactsAddonUrlToHostAndStreamPath() {
        assertEquals(
            "meteor.example.com/…/stream/series/tt0944947:1:5.json",
            StreamDiagnostics.redactUrl(
                "https://meteor.example.com/eyJhcGlLZXkiOiJzdXBlci1zZWNyZXQifQ/stream/series/tt0944947:1:5.json"
            ),
        )
    }

    /** A configless addon has no blob to hide, but the shape stays the same so the log reads alike. */
    @Test
    fun redactsUrlWithoutConfigBlob() {
        assertEquals(
            "example.com/…/stream/movie/tt1234567.json",
            StreamDiagnostics.redactUrl("https://example.com/stream/movie/tt1234567.json"),
        )
    }
}
