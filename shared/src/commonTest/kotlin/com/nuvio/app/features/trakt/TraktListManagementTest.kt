package com.nuvio.app.features.trakt

import com.nuvio.app.features.tracking.LibraryListPrivacy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class TraktListManagementTest {
    @Test
    fun `personal list id is the part after the key prefix`() {
        assertEquals("12345", traktPersonalListId("trakt:list:12345"))
        assertEquals("my-list", traktPersonalListId("trakt:list:my-list"))
    }

    @Test
    fun `watchlist and foreign keys are not personal lists`() {
        assertFailsWith<IllegalArgumentException> { traktPersonalListId("trakt:watchlist") }
        assertFailsWith<IllegalArgumentException> { traktPersonalListId("simkl:watching") }
        assertFailsWith<IllegalArgumentException> { traktPersonalListId("trakt:list:") }
    }

    @Test
    fun `create body trims, omits a blank description and carries the privacy wire value`() {
        val body = Json.parseToJsonElement(
            traktListRequestBody("  Weekend Movies ", "   ", LibraryListPrivacy.FRIENDS, clearEmptyDescription = false),
        ).jsonObject

        assertEquals("Weekend Movies", body.getValue("name").jsonPrimitive.content)
        assertNull(body["description"])
        assertEquals("friends", body.getValue("privacy").jsonPrimitive.content)
    }

    @Test
    fun `update body sends an empty description so Trakt clears it`() {
        val cleared = Json.parseToJsonElement(
            traktListRequestBody("Movies", null, LibraryListPrivacy.PRIVATE, clearEmptyDescription = true),
        ).jsonObject
        val kept = Json.parseToJsonElement(
            traktListRequestBody("Movies", " Cozy ones ", LibraryListPrivacy.PUBLIC, clearEmptyDescription = true),
        ).jsonObject

        assertEquals("", cleared.getValue("description").jsonPrimitive.content)
        assertEquals("Cozy ones", kept.getValue("description").jsonPrimitive.content)
        assertEquals("public", kept.getValue("privacy").jsonPrimitive.content)
    }

    @Test
    fun `reorder body lists the numeric ids in order`() {
        val body = Json.parseToJsonElement(
            traktReorderRequestBody(listOf("trakt:list:30", "trakt:list:10", "trakt:list:20")),
        ).jsonObject

        assertEquals(listOf(30L, 10L, 20L), body.getValue("rank").jsonArray.map { it.jsonPrimitive.content.toLong() })
    }

    @Test
    fun `reorder refuses a list that only has a slug`() {
        assertFailsWith<IllegalArgumentException> {
            traktReorderRequestBody(listOf("trakt:list:10", "trakt:list:my-list"))
        }
    }

    @Test
    fun `reordering keeps the watchlist first and unmentioned lists last`() {
        val tabs = listOf(
            tab("trakt:watchlist", TraktListType.WATCHLIST),
            tab("trakt:list:1"),
            tab("trakt:list:2"),
            tab("trakt:list:3"),
        )

        val reordered = reorderedTraktTabs(tabs, listOf("trakt:list:3", "trakt:list:1", "trakt:list:99"))

        assertEquals(
            listOf("trakt:watchlist", "trakt:list:3", "trakt:list:1", "trakt:list:2"),
            reordered.map { it.key },
        )
    }

    @Test
    fun `privacy parses the wire value and falls back to private`() {
        assertEquals(LibraryListPrivacy.LINK, LibraryListPrivacy.fromApi("link"))
        assertEquals(LibraryListPrivacy.PUBLIC, LibraryListPrivacy.fromApi(" Public "))
        assertEquals(LibraryListPrivacy.PRIVATE, LibraryListPrivacy.fromApi(null))
        assertEquals(LibraryListPrivacy.PRIVATE, LibraryListPrivacy.fromApi("secret"))
    }

    private fun tab(key: String, type: TraktListType = TraktListType.PERSONAL) =
        TraktListTab(key = key, title = key, type = type)
}
