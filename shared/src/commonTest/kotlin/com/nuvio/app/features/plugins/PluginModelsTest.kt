package com.nuvio.app.features.plugins

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class PluginModelsTest {
    @Test
    fun `repository updated just under the interval is not due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertFalse(
            isPluginRepositoryRefreshDue(
                lastUpdatedEpochMs = now - PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS + 1L,
                nowEpochMs = now,
            ),
        )
    }

    @Test
    fun `repository updated exactly one interval ago is due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertTrue(
            isPluginRepositoryRefreshDue(
                lastUpdatedEpochMs = now - PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS,
                nowEpochMs = now,
            ),
        )
    }

    @Test
    fun `repository that has never been updated is due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertTrue(isPluginRepositoryRefreshDue(lastUpdatedEpochMs = 0L, nowEpochMs = now))
    }

    // Fork-only (Codex 2026-08-24): a future lastUpdated (clock rollback) is due, not frozen.
    @Test
    fun `repository updated in the future is due for refresh`() {
        val now = 10 * PLUGIN_REPOSITORY_REFRESH_INTERVAL_MS

        assertTrue(isPluginRepositoryRefreshDue(lastUpdatedEpochMs = now + 1L, nowEpochMs = now))
    }

    // Fork-only (Codex 2026-08-30 P1): the push payload is a snapshot paired with the profile it
    // was built under, captured before the upload coroutine launches.
    @Test
    fun `push snapshot pairs the payload with the profile and orders by list position`() {
        val snapshot = buildPluginPushSnapshot(
            profileId = 3,
            repositories = listOf(
                PluginRepositoryItem(manifestUrl = "https://a.example/manifest.json", name = "Repo A"),
                PluginRepositoryItem(manifestUrl = "https://b.example/manifest.json", name = "Repo B"),
                PluginRepositoryItem(manifestUrl = "https://c.example/manifest.json", name = "Repo C"),
            ),
        )

        assertEquals(3, snapshot.profileId)
        assertEquals(listOf(0, 1, 2), snapshot.items.map { it.sortOrder })
        assertEquals(
            listOf(
                "https://a.example/manifest.json",
                "https://b.example/manifest.json",
                "https://c.example/manifest.json",
            ),
            snapshot.items.map { it.url },
        )
        assertEquals(listOf("Repo A", "Repo B", "Repo C"), snapshot.items.map { it.name })
        assertTrue(snapshot.items.all { it.enabled })
    }

    @Test
    fun `push snapshot of no repositories is an empty payload for that profile`() {
        val snapshot = buildPluginPushSnapshot(profileId = 2, repositories = emptyList())

        assertEquals(2, snapshot.profileId)
        assertTrue(snapshot.items.isEmpty())
    }

    // Wire contract of the sync_push_plugins RPC: sort_order is snake_case and defaults are
    // written out (the repository's Json has encodeDefaults = true).
    @Test
    fun `push item serializes with the sync_push_plugins field names`() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val encoded = json.encodeToString(
            PluginPushItem(url = "https://a.example/manifest.json", name = "Repo A", sortOrder = 4),
        )

        assertEquals(
            """{"url":"https://a.example/manifest.json","name":"Repo A","enabled":true,"sort_order":4}""",
            encoded,
        )
    }
}
