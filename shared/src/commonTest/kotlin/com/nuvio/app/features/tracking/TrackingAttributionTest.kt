package com.nuvio.app.features.tracking

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Ported from upstream `TrackingAttributionTest`, resolving for Trakt instead of Simkl. The
 * non-matching fixture keeps a `simkl` storage id so the provider-discrimination branch is still
 * covered — no Simkl code is involved, only the id string.
 */
class TrackingAttributionTest {
    @Test
    fun `resolver matches content and provider without depending on active source`() {
        val items = sequenceOf(
            attributedItem(
                contentId = "tt123",
                providerId = "simkl",
                sourceUrl = "https://simkl.com/movies/456",
                providerItemId = "simkl:456",
            ),
            attributedItem(
                contentId = "TT123",
                providerId = "trakt",
                sourceUrl = "https://trakt.tv/movies/123",
                providerItemId = "trakt:123",
            ),
        )

        val result = resolveTrackingAttribution(
            contentId = "tt123",
            providerId = TrackingProviderId.TRAKT,
            items = items,
        )

        assertEquals("trakt:123", result?.providerItemId)
        assertEquals("https://trakt.tv/movies/123", result?.sourceUrl)
        assertEquals(TrackingProviderId.TRAKT, result?.providerId)
    }

    @Test
    fun `resolver rejects missing links and mismatched content`() {
        assertNull(
            resolveTrackingAttribution(
                contentId = "tt123",
                providerId = TrackingProviderId.TRAKT,
                items = sequenceOf(
                    attributedItem("tt999", "trakt", "https://trakt.tv/movies/999"),
                    attributedItem("tt123", "trakt", null),
                    attributedItem("tt123", "trakt", "   "),
                ),
            ),
        )
    }

    private fun attributedItem(
        contentId: String,
        providerId: String,
        sourceUrl: String?,
        providerItemId: String? = null,
    ): TrackingAttributedItem = object : TrackingAttributedItem {
        override val trackingContentId = contentId
        override val trackingProviderId = providerId
        override val trackingProviderItemId = providerItemId
        override val trackingSourceUrl = sourceUrl
    }
}
