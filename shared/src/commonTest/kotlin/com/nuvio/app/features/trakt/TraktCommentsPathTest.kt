package com.nuvio.app.features.trakt

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class TraktCommentsPathTest {
    @Test
    fun `title threads keep their historic path and cache key`() {
        assertEquals("movies/tt0111161/comments/likes", traktCommentsPath(TraktCommentsType.MOVIE, "tt0111161", null, null, "likes"))
        assertEquals("shows/tt0944947/comments/likes", traktCommentsPath(TraktCommentsType.SHOW, "tt0944947", null, null, "likes"))
        assertEquals("show|tt0944947", traktCommentsCacheKey(TraktCommentsType.SHOW, "tt0944947", null, null))
    }

    @Test
    fun `an episode thread is scoped under its season and episode`() {
        assertEquals(
            "shows/tt0944947/seasons/2/episodes/9/comments/likes",
            traktCommentsPath(TraktCommentsType.SHOW, "tt0944947", 2, 9, "likes"),
        )
        assertNotEquals(
            traktCommentsCacheKey(TraktCommentsType.SHOW, "tt0944947", null, null),
            traktCommentsCacheKey(TraktCommentsType.SHOW, "tt0944947", 2, 9),
        )
        assertNotEquals(
            traktCommentsCacheKey(TraktCommentsType.SHOW, "tt0944947", 2, 9),
            traktCommentsCacheKey(TraktCommentsType.SHOW, "tt0944947", 9, 2),
        )
    }

    @Test
    fun `a movie never gets an episode scope`() {
        assertEquals(
            "movies/tt0111161/comments/likes",
            traktCommentsPath(TraktCommentsType.MOVIE, "tt0111161", 1, 1, "likes"),
        )
    }
}
