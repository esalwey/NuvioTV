package com.nuvio.app.features.plugins

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PluginTestReportTest {

    private fun result(title: String, quality: String? = null, size: String? = null, type: String? = null) =
        PluginRuntimeResult(title = title, url = "https://example.com/$title", quality = quality, size = size, type = type)

    @Test
    fun reportsTheFirstStreamsAndTheCount() {
        val results = (1..8).map { result("Stream $it", quality = "1080p", size = "2 GB") }
        val report = buildPluginTestReport("Provider", "movie", null, null, 1_234, Result.success(results))

        assertTrue(report.succeeded)
        assertNull(report.error)
        assertEquals("Movie \u00B7 TMDB 603", report.sample)
        assertEquals(8, report.streamCount)
        assertEquals(PLUGIN_TEST_PREVIEW_COUNT, report.streams.size)
        assertEquals("1080p \u00B7 2 GB", report.streams.first().detail)
        assertEquals("Answered in 1.2 s with 8 streams", report.steps.last())
    }

    @Test
    fun aSeriesSampleNamesTheEpisode() {
        val report = buildPluginTestReport("Provider", "tv", 1, 1, 400, Result.success(emptyList()))
        assertEquals("Series \u00B7 TMDB 603 \u00B7 S1E1", report.sample)
        assertEquals(0, report.streamCount)
        assertEquals("Answered in 400 ms with no streams", report.steps.last())
        assertTrue(report.succeeded)
    }

    @Test
    fun aFailureKeepsTheReasonAndNoStreams() {
        val report = buildPluginTestReport(
            "Provider", "movie", null, null, 60_000,
            Result.failure(IllegalStateException("Timed out")),
        )
        assertFalse(report.succeeded)
        assertEquals("Timed out", report.error)
        assertEquals(0, report.streamCount)
        assertTrue(report.streams.isEmpty())
        assertEquals("Failed after 60.0 s: Timed out", report.steps.last())
    }

    @Test
    fun aBlankTitleFallsBackToTheNameThenToUntitled() {
        val results = listOf(
            PluginRuntimeResult(title = "", name = "Named", url = "u1"),
            PluginRuntimeResult(title = " ", url = "u2"),
        )
        val report = buildPluginTestReport("Provider", "movie", null, null, 10, Result.success(results))
        assertEquals(listOf("Named", "Untitled"), report.streams.map { it.title })
        assertEquals("Answered in 10 ms with 2 streams", report.steps.last())
    }
}
