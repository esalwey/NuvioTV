package com.nuvio.app.features.streams

import com.nuvio.app.features.servers.ServerItemRef
import com.nuvio.app.features.servers.ServerPlaybackTarget
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StreamServerGroupsTest {
    private val serverFile = StreamItem(
        name = "Movie.mkv",
        addonName = "Jellyfin · Box",
        addonId = "server:cbox",
        serverTarget = ServerPlaybackTarget(ServerItemRef("cbox", "42"), "src-42"),
    )

    private fun group(id: String, name: String = id) =
        AddonStreamGroup(addonName = name, addonId = id, streams = emptyList(), isLoading = false)

    @Test
    fun aServerFileIsPlayableBeforeItsUrlIsMinted() {
        assertNull(serverFile.playableDirectUrl)
        assertTrue(serverFile.hasPlayableSource)
        assertTrue(serverFile.needsServerPreparation)
        assertFalse(serverFile.copy(url = "https://box.example/stream").needsServerPreparation)
    }

    @Test
    fun preferredServerGroupsLeadEveryAddon() {
        val groups = listOf(group("addon:a", "A"), group("server:cbox", "Box"), group("addon:b", "B"))

        val ordered = StreamAutoPlaySelector.orderAddonStreams(
            groups = groups,
            installedOrder = listOf("A", "B"),
            preferredGroupIds = setOf("server:cbox"),
        )

        assertEquals(listOf("server:cbox", "addon:a", "addon:b"), ordered.map { it.addonId })
    }

    @Test
    fun serverGroupsKeepTheirPlaceWithoutAPreference() {
        val groups = listOf(group("addon:b", "B"), group("server:cbox", "Box"), group("addon:a", "A"))

        val ordered = StreamAutoPlaySelector.orderAddonStreams(groups, installedOrder = listOf("A", "B"))

        assertEquals(listOf("addon:a", "addon:b", "server:cbox"), ordered.map { it.addonId })
    }

    @Test
    fun autoPlayCanPickAServerFileInEveryScope() {
        val picked = StreamAutoPlaySelector.selectAutoPlayStream(
            streams = listOf(serverFile),
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.INSTALLED_ADDONS_ONLY,
            installedAddonNames = setOf("Some Addon"),
            selectedAddons = setOf("Some Addon"),
            selectedPlugins = emptySet(),
        )

        assertNotNull(picked)
        assertEquals(serverFile, picked)
    }
}
