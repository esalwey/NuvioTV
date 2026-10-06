package com.nuvio.app.features.home

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.catalog.CatalogTarget
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * What an add-on RENAME is allowed to do to Home.
 *
 * Hole E (BUG-86, Wave H) took the add-on's display title out of the catalog descriptor signature,
 * because that signature feeds the cache key and a server-supplied rename was pruning every one of
 * that add-on's fetched sections - the skeleton rebuild in the tester's cold-launch video. Codex
 * branch review round 6 found the other half of the trade: with the title out of the signature
 * entirely, nothing told the frontend a rename had happened, so the row caption and the Home Rows
 * settings caption kept the OLD name until some unrelated refresh.
 *
 * The rules below are the split that resolves both: the title rides the TRIGGER signature, never
 * the IDENTITY (cache key), and a definition set that differs only in display metadata is applied
 * by republishing rather than re-fetching.
 *
 * Scope note: [HomeRepository] is not driven here for the reasons spelled out in
 * `HomeRepositoryGateReleaseTest` (network + wall-clock + four singletons, no injection seam). Its
 * rename path is exactly the three pure functions asserted below, extracted for that reason.
 */
class HomeCatalogRenameTest {

    private fun manifest(
        id: String = "org.example",
        version: String = "1.0.0",
        catalogName: String = "Top Movies",
    ) = AddonManifest(
        id = id,
        name = "Example",
        description = "",
        version = version,
        resources = listOf(AddonResource(name = "catalog", types = listOf("movie"))),
        types = listOf("movie"),
        catalogs = listOf(AddonCatalog(type = "movie", id = "top", name = catalogName)),
        transportUrl = "https://example.com/$id/manifest.json",
    )

    private fun addon(
        userSetName: String? = null,
        version: String = "1.0.0",
        catalogName: String = "Top Movies",
        isRefreshing: Boolean = false,
        errorMessage: String? = null,
    ) = ManagedAddon(
        manifestUrl = "https://example.com/org.example/manifest.json",
        manifest = manifest(version = version, catalogName = catalogName),
        userSetName = userSetName,
        isRefreshing = isRefreshing,
        errorMessage = errorMessage,
    )

    private fun section(definition: HomeCatalogDefinition) = HomeCatalogSection(
        key = definition.key,
        title = definition.defaultTitle,
        subtitle = definition.addonName,
        addonName = definition.addonName,
        target = CatalogTarget.Addon(
            manifestUrl = definition.manifestUrl,
            contentType = definition.type,
            catalogId = definition.catalogId,
            supportsPagination = definition.supportsPagination,
        ),
        items = emptyList(),
    )

    // ---------------------------------------------------------------------------------------
    // The trigger signature sees the rename; the cache key does not.
    // ---------------------------------------------------------------------------------------

    @Test
    fun `a rename moves the refresh signature`() {
        assertNotEquals(
            buildHomeCatalogRefreshSignature(listOf(addon())),
            buildHomeCatalogRefreshSignature(listOf(addon(userSetName = "My Movies"))),
            "a rename must reach the frontend's catalog re-sync effect",
        )
    }

    @Test
    fun `a rename leaves the cache key untouched`() {
        val before = buildHomeCatalogDefinitions(listOf(addon())).single()
        val after = buildHomeCatalogDefinitions(listOf(addon(userSetName = "My Movies"))).single()

        assertEquals(before.key, after.key, "a rename must not re-key a fetched section")
        assertEquals(before.cacheKey, after.cacheKey, "a rename must not invalidate fetched content")
        assertEquals("Example", before.addonName)
        assertEquals("My Movies", after.addonName)
    }

    @Test
    fun `volatile addon state moves neither signature`() {
        // The other three fields Hole E removed. They flip twice per manifest fetch, so a trigger
        // that carried them would re-sync Home on every refresh cycle.
        val noisy = addon(isRefreshing = true, errorMessage = "boom")
        assertEquals(
            buildHomeCatalogRefreshSignature(listOf(addon())),
            buildHomeCatalogRefreshSignature(listOf(noisy)),
        )
        assertEquals(
            buildHomeCatalogDefinitions(listOf(addon())).single().cacheKey,
            buildHomeCatalogDefinitions(listOf(noisy)).single().cacheKey,
        )
    }

    // ---------------------------------------------------------------------------------------
    // isMetadataOnlyDefinitionChange: repaint or re-fetch?
    // ---------------------------------------------------------------------------------------

    @Test
    fun `a rename is a metadata-only definition change`() {
        val before = buildHomeCatalogDefinitions(listOf(addon()))
        val after = buildHomeCatalogDefinitions(listOf(addon(userSetName = "My Movies")))
        assertTrue(isMetadataOnlyDefinitionChange(before, after))
    }

    @Test
    fun `an unchanged definition set is not a metadata-only change`() {
        val before = buildHomeCatalogDefinitions(listOf(addon()))
        val after = buildHomeCatalogDefinitions(listOf(addon()))
        assertFalse(
            isMetadataOnlyDefinitionChange(before, after),
            "nothing to repaint means no publish; the normal refresh path owns this case",
        )
    }

    @Test
    fun `a manifest version bump is not a metadata-only change`() {
        val before = buildHomeCatalogDefinitions(listOf(addon()))
        val after = buildHomeCatalogDefinitions(listOf(addon(version = "1.1.0")))
        assertFalse(
            isMetadataOnlyDefinitionChange(before, after),
            "the cache key moved, so this is real content change and must re-fetch",
        )
    }

    @Test
    fun `a renamed catalog is not a metadata-only change`() {
        // The catalog's own name IS in the descriptor signature, so it re-keys like content.
        val before = buildHomeCatalogDefinitions(listOf(addon()))
        val after = buildHomeCatalogDefinitions(listOf(addon(catalogName = "Popular Movies")))
        assertFalse(isMetadataOnlyDefinitionChange(before, after))
    }

    @Test
    fun `a changed catalog count is not a metadata-only change`() {
        val before = buildHomeCatalogDefinitions(listOf(addon()))
        assertFalse(isMetadataOnlyDefinitionChange(before, emptyList()))
        assertFalse(isMetadataOnlyDefinitionChange(emptyList(), before))
    }

    // ---------------------------------------------------------------------------------------
    // withCurrentMetadata: the published row follows the definition, not the fetch.
    // ---------------------------------------------------------------------------------------

    @Test
    fun `a cached section takes the renamed addon name on publish`() {
        val fetched = section(buildHomeCatalogDefinitions(listOf(addon())).single())
        val renamed = buildHomeCatalogDefinitions(listOf(addon(userSetName = "My Movies"))).single()

        val published = fetched.withCurrentMetadata(
            definition = renamed,
            customTitle = "",
            showCatalogType = true,
        )

        assertEquals("My Movies", published.subtitle)
        assertEquals("My Movies", published.addonName)
        assertEquals(renamed.defaultTitle, published.title)
        assertEquals(fetched.key, published.key, "a repaint must not re-key the row")
        assertEquals(fetched.items, published.items, "a repaint must not touch fetched items")
    }

    @Test
    fun `a custom row title survives the repaint`() {
        val renamed = buildHomeCatalogDefinitions(listOf(addon(userSetName = "My Movies"))).single()

        val published = section(renamed).withCurrentMetadata(
            definition = renamed,
            customTitle = "Saturday Night",
            showCatalogType = true,
        )

        assertEquals("Saturday Night", published.title)
        assertEquals("My Movies", published.subtitle)
    }

    @Test
    fun `the catalog-type preference still picks the title`() {
        val definition = buildHomeCatalogDefinitions(listOf(addon())).single()

        assertEquals(
            definition.catalogName,
            section(definition).withCurrentMetadata(
                definition = definition,
                customTitle = "",
                showCatalogType = false,
            ).title,
        )
    }
}
