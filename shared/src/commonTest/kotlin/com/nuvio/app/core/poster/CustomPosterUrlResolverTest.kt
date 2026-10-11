package com.nuvio.app.core.poster

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CustomPosterUrlResolverTest {

    private val rpdb = "https://api.ratingposterdb.com/key/imdb/poster-default/{imdb_id}.jpg"
    private val universal = "https://example.com/{id_type}/poster-default/{typed_id}.jpg"
    private val shaped = "https://example.com/{id_type}/{shape}/{typed_id}.jpg"

    @Test
    fun `extractIds reads the id namespace`() {
        assertEquals("tt0137523", CustomPosterUrlResolver.extractIds("tt0137523").imdbId)
        assertEquals("1396", CustomPosterUrlResolver.extractIds("tmdb:1396").tmdbId)
        assertEquals("7442", CustomPosterUrlResolver.extractIds("kitsu:7442").kitsuId)
        assertEquals("21", CustomPosterUrlResolver.extractIds("anilist:21").anilistId)
        assertEquals("1535", CustomPosterUrlResolver.extractIds("mal:1535").malId)
        assertNull(CustomPosterUrlResolver.extractIds("kitsu:7442").imdbId)
    }

    @Test
    fun `an explicit imdb id wins over the parsed one`() {
        val ids = CustomPosterUrlResolver.extractIds("tmdb:1396", explicitImdbId = "tt0903747")
        assertEquals("1396", ids.tmdbId)
        assertEquals("tt0903747", ids.imdbId)
    }

    @Test
    fun `native placeholders resolve for an imdb id`() {
        val url = CustomPosterUrlResolver.resolve(
            "https://example.com/poster?id={id}&id_type={id_type}&type={type}",
            CustomPosterUrlResolver.extractIds("tt0137523"),
            "movie",
        )
        assertEquals("https://example.com/poster?id=tt0137523&id_type=imdb&type=movie", url)
    }

    @Test
    fun `typed id prefixes tmdb ids with the content type`() {
        val movie = CustomPosterUrlResolver.resolve(universal, CustomPosterUrlResolver.extractIds("tmdb:1396"), "movie")
        val series = CustomPosterUrlResolver.resolve(universal, CustomPosterUrlResolver.extractIds("tmdb:1396"), "series")
        assertEquals("https://example.com/tmdb/poster-default/movie-1396.jpg", movie)
        assertEquals("https://example.com/tmdb/poster-default/series-1396.jpg", series)
    }

    @Test
    fun `a required placeholder without a value resolves to nothing`() {
        val url = CustomPosterUrlResolver.resolve(rpdb, CustomPosterUrlResolver.extractIds("kitsu:7442"), "series")
        assertNull(url)
    }

    @Test
    fun `an optional placeholder without a value becomes empty`() {
        val url = CustomPosterUrlResolver.resolve(
            "https://example.com/{imdb_id}?tmdb={tmdb_id?}",
            CustomPosterUrlResolver.extractIds("tt0137523"),
            "movie",
        )
        assertEquals("https://example.com/tt0137523?tmdb=", url)
    }

    @Test
    fun `a pipe list takes the first id the title has`() {
        val pattern = "https://example.com/{imdb_id|kitsu_id}.jpg"
        assertEquals(
            "https://example.com/7442.jpg",
            CustomPosterUrlResolver.resolve(pattern, CustomPosterUrlResolver.extractIds("kitsu:7442"), "series"),
        )
        assertNull(CustomPosterUrlResolver.resolve(pattern, CustomPosterUrlResolver.extractIds("tmdb:1396"), "series"))
    }

    @Test
    fun `a pattern without placeholders is ignored`() {
        assertNull(
            CustomPosterUrlResolver.resolve("https://example.com/static.jpg", CustomPosterUrlResolver.extractIds("tt1"), "movie"),
        )
    }

    @Test
    fun `percent encoded placeholders are decoded`() {
        val url = CustomPosterUrlResolver.resolve(
            "https://example.com/%7Bimdb_id%7D.jpg",
            CustomPosterUrlResolver.extractIds("tt0137523"),
            "movie",
        )
        assertEquals("https://example.com/tt0137523.jpg", url)
    }

    @Test
    fun `rating poster urls fall back to another id type`() {
        val url = CustomPosterUrlResolver.resolve(rpdb, CustomPosterUrlResolver.extractIds("tmdb:1396"), "series")
        assertEquals("https://api.ratingposterdb.com/key/tmdb/poster-default/series-1396.jpg", url)
    }

    @Test
    fun `resolveForTitle fills the portrait poster`() {
        assertEquals(
            "https://api.ratingposterdb.com/key/imdb/poster-default/tt0137523.jpg",
            CustomPosterUrlResolver.resolveForTitle(rpdb, "tt0137523", "movie", "poster", null),
        )
    }

    @Test
    fun `resolveForTitle skips landscape and square when the pattern has no shape`() {
        assertNull(CustomPosterUrlResolver.resolveForTitle(rpdb, "tt0137523", "movie", "landscape", null))
        assertNull(CustomPosterUrlResolver.resolveForTitle(rpdb, "tt0137523", "movie", "square", null))
    }

    @Test
    fun `resolveForTitle fills the shape when the pattern asks for it`() {
        assertEquals(
            "https://example.com/imdb/landscape/tt0137523.jpg",
            CustomPosterUrlResolver.resolveForTitle(shaped, "tt0137523", "movie", "Landscape", null),
        )
        assertEquals(
            "https://example.com/imdb/poster/tt0137523.jpg",
            CustomPosterUrlResolver.resolveForTitle(shaped, "tt0137523", "movie", "poster", null),
        )
    }

    @Test
    fun `resolveForTitle treats every non movie type as a series`() {
        assertEquals(
            "https://example.com/tmdb/poster-default/series-1396.jpg",
            CustomPosterUrlResolver.resolveForTitle(universal, "tmdb:1396", "tv", "poster", null),
        )
    }

    @Test
    fun `resolveForTitle returns nothing for a blank pattern`() {
        assertNull(CustomPosterUrlResolver.resolveForTitle("  ", "tt0137523", "movie", "poster", null))
    }

    @Test
    fun `supportsShape sees an encoded placeholder`() {
        assertTrue(CustomPosterUrlResolver.supportsShape("https://example.com/%7Bshape%7D/x"))
        assertFalse(CustomPosterUrlResolver.supportsShape(rpdb))
    }
}
