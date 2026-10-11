package com.nuvio.app.features.debrid

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class TorboxCloudPagingTest {
    private fun item(id: Int) = TorboxCloudItemDto(name = "item-$id")

    private fun page(items: List<TorboxCloudItemDto>, status: Int = 200, success: Boolean? = true, rawBody: String = "{}") =
        DebridApiResponse(
            status = status,
            body = TorboxEnvelopeDto(success = success, data = items),
            rawBody = rawBody,
        )

    @Test
    fun `merges every page of a large library`() = runBlocking {
        val source = (1..250).map(::item)
        val requests = mutableListOf<Pair<Int, Int>>()

        val response = fetchTorboxCloudPages { offset, limit ->
            requests += offset to limit
            page(source.drop(offset).take(limit))
        }

        assertEquals(source, response.body?.data)
        assertEquals(listOf(0 to 100, 100 to 100, 200 to 100), requests)
        assertEquals("", response.rawBody)
    }

    @Test
    fun `an exact page multiple ends on the following empty page`() = runBlocking {
        val source = (1..200).map(::item)
        val offsets = mutableListOf<Int>()

        val response = fetchTorboxCloudPages { offset, limit ->
            offsets += offset
            page(source.drop(offset).take(limit))
        }

        assertEquals(200, response.body?.data?.size)
        assertEquals(listOf(0, 100, 200), offsets)
    }

    @Test
    fun `a truncated page is retried with half the limit`() = runBlocking {
        val source = (1..120).map(::item)
        val limits = mutableListOf<Int>()

        val response = fetchTorboxCloudPages { offset, limit ->
            limits += limit
            if (limit > 25) {
                page(emptyList(), rawBody = "{\"data\":[\n...[truncated]")
            } else {
                page(source.drop(offset).take(limit))
            }
        }

        assertEquals(source, response.body?.data)
        assertEquals(listOf(100, 50, 25), limits.take(3))
    }

    @Test
    fun `an API error is returned as is and never retried`() = runBlocking {
        var calls = 0

        val response = fetchTorboxCloudPages { _, _ ->
            calls++
            page(emptyList(), status = 403, success = false)
        }

        assertEquals(1, calls)
        assertEquals(403, response.status)
    }

    @Test
    fun `a single oversized item fails instead of looping`() {
        assertFailsWith<IllegalStateException> {
            runBlocking {
                fetchTorboxCloudPages { _, _ -> page(emptyList(), rawBody = "x\n...[truncated]") }
            }
        }
    }
}
