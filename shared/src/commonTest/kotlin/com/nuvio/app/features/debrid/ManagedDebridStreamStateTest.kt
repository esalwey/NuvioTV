package com.nuvio.app.features.debrid

import com.nuvio.app.features.debrid.DebridStreamPresentation.isManagedDebridStream
import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamDebridCacheState
import com.nuvio.app.features.streams.StreamDebridCacheStatus
import com.nuvio.app.features.streams.StreamItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * BUG-21 follow-up: only a VERIFIED cache hit (CACHED) may receive the managed-debrid
 * treatment — above all the "{service} Instant" rename. UNKNOWN means the cache check
 * failed (e.g. a dead token), and presenting those rows as "TB Instant" told the reporter
 * every stream was cached while every resolve failed with "Could not open this link".
 */
class ManagedDebridStreamStateTest {

    @Test
    fun `only CACHED torrent rows are managed`() {
        assertTrue(torrentStream(StreamDebridCacheState.CACHED).isManagedDebridStream)
        assertFalse(torrentStream(StreamDebridCacheState.UNKNOWN).isManagedDebridStream)
        assertFalse(torrentStream(StreamDebridCacheState.CHECKING).isManagedDebridStream)
        assertFalse(torrentStream(StreamDebridCacheState.NOT_CACHED).isManagedDebridStream)
    }

    @Test
    fun `UNKNOWN rows keep the addon title through presentation`() {
        val cached = torrentStream(StreamDebridCacheState.CACHED, name = "Cached row")
        val unknown = torrentStream(StreamDebridCacheState.UNKNOWN, name = "Comet 4K rip")
        val presented = present(cached, unknown)

        val unknownRow = presented.single { it.debridCacheStatus?.state == StreamDebridCacheState.UNKNOWN }
        assertEquals(
            "Comet 4K rip",
            unknownRow.name,
            "an unverified row must pass through unrenamed — no \"Instant\" claim",
        )
        val cachedRow = presented.single { it.debridCacheStatus?.state == StreamDebridCacheState.CACHED }
        assertTrue(
            cachedRow.name.orEmpty().contains("Instant"),
            "verified cache hits keep the Instant rename (got: ${cachedRow.name})",
        )
    }

    @Test
    fun `UNKNOWN rows stay visible while NOT_CACHED is hidden`() {
        val presented = present(
            torrentStream(StreamDebridCacheState.UNKNOWN, name = "Unknown row"),
            torrentStream(StreamDebridCacheState.NOT_CACHED, name = "Uncached row"),
        )
        assertEquals(listOf("Unknown row"), presented.map { it.name })
    }

    private fun present(vararg streams: StreamItem): List<StreamItem> =
        DebridStreamPresentation.apply(
            groups = listOf(
                AddonStreamGroup(
                    addonName = "Addon",
                    addonId = "addon:test",
                    streams = streams.toList(),
                ),
            ),
            settings = DebridSettings(
                enabled = true,
                providerApiKeys = mapOf(DebridProviders.TORBOX_ID to "key"),
            ),
        ).single().streams

    private fun torrentStream(
        state: StreamDebridCacheState,
        name: String = "Torrent row",
    ): StreamItem =
        StreamItem(
            name = name,
            infoHash = "abcdef1234567890abcdef1234567890abcdef12",
            addonName = "Addon",
            addonId = "addon:test",
            debridCacheStatus = StreamDebridCacheStatus(
                providerId = DebridProviders.TORBOX_ID,
                providerName = DebridProviders.Torbox.displayName,
                state = state,
            ),
        )
}
