package com.nuvio.app.features.mdblist

import com.nuvio.app.features.trakt.MoreLikeThisSourcePreference
import kotlin.test.Test
import kotlin.test.assertEquals

class MdbListProviderOrderTest {
    private val defaults = MdbListMetadataService.PROVIDER_PRIORITY_ORDER

    @Test
    fun `no stored order falls back to the default order`() {
        assertEquals(defaults, normalizeMdbListProviderOrder(null))
        assertEquals(defaults, decodeMdbListProviderOrder(null))
        assertEquals(defaults, decodeMdbListProviderOrder(""))
    }

    @Test
    fun `a partial order keeps its entries first and appends the rest in default order`() {
        val order = normalizeMdbListProviderOrder(listOf("mal", "tomatoes"))
        assertEquals(listOf("mal", "tomatoes"), order.take(2))
        assertEquals(defaults.size, order.size)
        assertEquals(defaults.toSet(), order.toSet())
        assertEquals(defaults.filter { it != "mal" && it != "tomatoes" }, order.drop(2))
    }

    @Test
    fun `unknown and duplicate ids are dropped`() {
        val order = normalizeMdbListProviderOrder(listOf("trakt", "bogus", "trakt", "imdb"))
        assertEquals(listOf("trakt", "imdb"), order.take(2))
        assertEquals(defaults.toSet(), order.toSet())
        assertEquals(defaults.size, order.size)
    }

    @Test
    fun `order survives an encode and decode round trip`() {
        val custom = listOf("letterboxd") + defaults.filter { it != "letterboxd" }
        assertEquals(custom, decodeMdbListProviderOrder(encodeMdbListProviderOrder(custom)))
    }

    @Test
    fun `enabled providers follow the custom order and skip disabled ones`() {
        val settings = MdbListSettings(
            enabled = true,
            apiKey = "key",
            useImdb = false,
            providerOrder = listOf("mal", "imdb", "trakt"),
        )
        val enabled = settings.enabledProvidersInPriorityOrder()
        assertEquals("mal", enabled.first())
        assertEquals(listOf("mal", "trakt"), enabled.take(2))
        assertEquals(false, "imdb" in enabled)
        assertEquals(defaults.size - 1, enabled.size)
    }

    @Test
    fun `default settings keep the historical priority order`() {
        assertEquals(defaults, MdbListSettings().enabledProvidersInPriorityOrder())
    }

    @Test
    fun `more like this source stored names stay readable and unknown values fall back`() {
        assertEquals(MoreLikeThisSourcePreference.SIMKL, MoreLikeThisSourcePreference.fromStorage("SIMKL"))
        assertEquals(MoreLikeThisSourcePreference.TMDB, MoreLikeThisSourcePreference.fromStorage("TMDB"))
        assertEquals(MoreLikeThisSourcePreference.TRAKT, MoreLikeThisSourcePreference.fromStorage("nope"))
    }
}
