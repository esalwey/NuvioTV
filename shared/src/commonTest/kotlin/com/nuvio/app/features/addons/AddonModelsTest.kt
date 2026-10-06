package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/// Upstream 085e8dc6 (#1819): the pending/error manifest predicates behind the delayed-addon
/// states. Ported from upstream's composeApp `AddonModelsTest`; lives in :shared so it runs under
/// the tvOS-native gate.
class AddonModelsTest {
    @Test
    fun `pending manifest helpers only consider enabled unresolved addons`() {
        val pending = ManagedAddon(manifestUrl = "https://pending.example/manifest.json", isRefreshing = true)
        val disabledPending = ManagedAddon(
            manifestUrl = "https://disabled.example/manifest.json",
            enabled = false,
            isRefreshing = true,
        )

        assertTrue(listOf(pending, disabledPending).hasPendingEnabledManifests())
        assertTrue(listOf(pending, disabledPending).isWaitingForFirstEnabledManifest())
        assertFalse(
            listOf(
                pending,
                ManagedAddon(manifestUrl = "https://loaded.example/manifest.json", manifest = manifest(id = "loaded")),
            ).isWaitingForFirstEnabledManifest(),
        )
        assertFalse(listOf(disabledPending).hasPendingEnabledManifests())
    }

    @Test
    fun `manifest error helper ignores disabled and resolved addons`() {
        val disabledFailure = ManagedAddon(
            manifestUrl = "https://disabled.example/manifest.json",
            enabled = false,
            errorMessage = "Disabled failure",
        )
        val resolvedFailure = ManagedAddon(
            manifestUrl = "https://resolved.example/manifest.json",
            manifest = manifest(id = "resolved"),
            errorMessage = "Stale refresh failure",
        )
        val unresolvedFailure = ManagedAddon(
            manifestUrl = "https://failed.example/manifest.json",
            errorMessage = "Manifest failure",
        )

        assertEquals(
            "Manifest failure",
            listOf(disabledFailure, resolvedFailure, unresolvedFailure).firstEnabledManifestError(),
        )
        assertEquals(null, listOf(disabledFailure, resolvedFailure).firstEnabledManifestError())
    }
}

private fun manifest(id: String = "addon") = AddonManifest(
    id = id,
    name = id,
    description = "",
    version = "1.0.0",
    resources = listOf(AddonResource(name = "meta", types = listOf("movie"))),
    types = listOf("movie"),
    catalogs = emptyList(),
    transportUrl = "https://$id.example/manifest.json",
)
