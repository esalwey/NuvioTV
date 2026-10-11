package com.nuvio.app.features.mdblist

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class MdbListNetworkEngineTest {
    @Test
    fun queryValuesCannotChangeRequestDestination() {
        val request = MdbListHttpRequest(MdbListHttpMethod.GET, "/lists/user", mapOf("cursor" to "a&b=#雪"))
        val url = io.ktor.http.Url(mdbListRequestUrl(MdbListConfiguration("client", "test"), request))
        assertEquals("api.mdblist.com", url.host)
        assertEquals("a&b=#雪", url.parameters["cursor"])
        listOf("//other.test/path", "/path?secret", "/path#fragment", "/path\\other").forEach { path ->
            assertFailsWith<IllegalArgumentException> {
                mdbListRequestUrl(MdbListConfiguration("client", "test"), MdbListHttpRequest(MdbListHttpMethod.GET, path))
            }
        }
    }
}
