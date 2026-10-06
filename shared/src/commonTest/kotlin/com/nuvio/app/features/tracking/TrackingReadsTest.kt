package com.nuvio.app.features.tracking

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Ported from upstream `TrackingReadsTest`. Upstream's fixtures use Simkl status lists (the only
 * provider that ships them); Phase 1 has no Simkl, so the same rules are exercised with
 * Trakt-owned tab keys. The behaviour under test — selection groups, membership destinations,
 * content-type filtering — is provider-neutral.
 */
class TrackingReadsTest {
    @Test
    fun `selection group keeps one provider status selected`() {
        val tabs = listOf(
            tab("local", providerId = null),
            tab("trakt:watching", selectionGroup = "trakt:status"),
            tab("trakt:completed", selectionGroup = "trakt:status"),
        )
        val current = mapOf(
            "local" to true,
            "trakt:watching" to true,
            "trakt:completed" to false,
        )

        val updated = toggleTrackingLibraryMembership(
            tabs = tabs,
            membership = current,
            key = "trakt:completed",
        )

        assertEquals(true, updated["local"])
        assertEquals(false, updated["trakt:watching"])
        assertEquals(true, updated["trakt:completed"])
    }

    @Test
    fun `unknown selection key leaves membership unchanged`() {
        val current = mapOf("local" to true)

        val updated = toggleTrackingLibraryMembership(
            tabs = listOf(tab("local", providerId = null)),
            membership = current,
            key = "missing",
        )

        assertSame(current, updated)
    }

    @Test
    fun `content type support filters provider specific statuses`() {
        val seriesOnly = tab("trakt:watching").copy(supportedContentTypes = setOf("series"))

        assertTrue(seriesOnly.supportsContentType("SERIES"))
        assertFalse(seriesOnly.supportsContentType("movie"))
        assertTrue(tab("trakt:watchlist").supportsContentType("movie"))
    }

    @Test
    fun `non destination status stays in selection group without appearing in picker`() {
        val watching = tab("trakt:watching", selectionGroup = "trakt:status")
        val completed = tab("trakt:completed", selectionGroup = "trakt:status")
            .copy(isMembershipDestination = false)
        val tabs = listOf(watching, completed)

        assertEquals(listOf(watching), trackingMembershipDestinations(tabs))

        val updated = toggleTrackingLibraryMembership(
            tabs = tabs,
            membership = mapOf(watching.key to false, completed.key to true),
            key = watching.key,
        )

        assertEquals(true, updated[watching.key])
        assertEquals(false, updated[completed.key])
    }

    private fun tab(
        key: String,
        providerId: TrackingProviderId? = TrackingProviderId.TRAKT,
        selectionGroup: String? = null,
    ) = TrackingLibraryTab(
        key = key,
        title = key,
        providerId = providerId,
        kind = TrackingLibraryTabKind.STATUS,
        selectionGroup = selectionGroup,
    )
}
