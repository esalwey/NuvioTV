package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * BUG-75: episode ratings weren't read from the addon's own metadata, so episode cards had no
 * fallback when the ratings repository (imdbEpisodeRatings) had no entry for a title. Covers
 * [MetaDetailsParser]'s `rating` extraction on [MetaVideo].
 */
class MetaVideoRatingParseTest {

    private fun parseVideos(ratingJson: String): List<MetaVideo> {
        val payload = """
            {
                "id": "tt1234567",
                "type": "series",
                "name": "Test Show",
                "videos": [
                    {
                        "id": "tt1234567:1:1",
                        "title": "Pilot",
                        "season": 1,
                        "episode": 1,
                        $ratingJson
                    }
                ]
            }
        """.trimIndent()
        return MetaDetailsParser.parse(payload).videos
    }

    @Test
    fun `rating parses a numeric string into a Double`() {
        val videos = parseVideos(""""rating": "7.8"""")
        assertEquals(7.8, videos.single().rating)
    }

    @Test
    fun `rating of zero is treated as absent`() {
        val videos = parseVideos(""""rating": "0"""")
        assertNull(videos.single().rating)
    }

    @Test
    fun `rating is null when the field is missing`() {
        val videos = parseVideos(""""available": true""")
        assertNull(videos.single().rating)
    }
}
