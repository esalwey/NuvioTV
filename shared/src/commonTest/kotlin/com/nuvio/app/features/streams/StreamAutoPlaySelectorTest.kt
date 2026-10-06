package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals

class StreamAutoPlaySelectorTest {

    @Test
    fun nestedExclusionsDoNotCrashRegexSelection() {
        val stream = stream(
            addonName = "Direct Addon",
            url = "https://example.com/video.mp4",
            name = "Movie 1080p WEB",
        )

        val selected = StreamAutoPlaySelector.selectAutoPlayStream(
            streams = listOf(stream),
            mode = StreamAutoPlayMode.REGEX_MATCH,
            regexPattern = "^(?!.*\\b(CAM(?!RIP)|TS)\\b).*1080p",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = setOf("Direct Addon"),
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
        )

        assertEquals(stream, selected)
    }

    private fun stream(
        addonName: String,
        url: String? = null,
        name: String? = null,
    ): StreamItem = StreamItem(
        name = name,
        url = url,
        addonName = addonName,
        addonId = "addon:$addonName",
    )
}
