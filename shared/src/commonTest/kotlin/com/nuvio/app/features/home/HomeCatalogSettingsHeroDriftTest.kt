package com.nuvio.app.features.home

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.collection.Collection
import com.nuvio.app.features.collection.CollectionFolder
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.CollectionSource
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Coverage for the 2026-08-29/30 hero-source drift bug: `normalizePreferences()` only
 * auto-enables an entry with NO stored preference at all, so once every survivor of a catalog-key
 * change carries a stored `heroSourceEnabled=false` (which normalize itself wrote there on an
 * earlier pass), the selection could get stranded at zero forever. See the drift-refill block in
 * `HomeCatalogSettingsRepository.normalizePreferences()`.
 *
 * Exercises the singleton repository directly (unlike `HomeCatalogDefinitionsGuardTest`, which
 * deliberately avoids it) — reset via `clearLocalState()` plus wiping the persisted payload so a
 * stale on-disk preference set from another test/run can't leak into `ensureLoaded()`.
 */
class HomeCatalogSettingsHeroDriftTest {

    private val addonId = "drift-test-addon"

    @BeforeTest
    fun setUp() {
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsStorage.savePayload("")
        CollectionRepository.clearLocalState()
    }

    @AfterTest
    fun tearDown() {
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsStorage.savePayload("")
        CollectionRepository.clearLocalState()
    }

    private fun addonWithCatalogs(catalogIds: List<String>, id: String = addonId): ManagedAddon {
        val manifest = AddonManifest(
            id = id,
            name = "Drift Test Addon",
            description = "",
            version = "1.0.0",
            resources = listOf(AddonResource(name = "catalog", types = listOf("movie"))),
            types = listOf("movie"),
            catalogs = catalogIds.map { catalogId -> AddonCatalog(type = "movie", id = catalogId, name = catalogId) },
            transportUrl = "https://example.com/$id/manifest.json",
        )
        return ManagedAddon(manifestUrl = manifest.transportUrl, manifest = manifest, enabled = true)
    }

    private fun key(catalogId: String, id: String = addonId) = "$id:movie:$catalogId"

    private fun heroEnabledKeys(): Set<String> =
        HomeCatalogSettingsRepository.uiState.value.items
            .filter { it.heroSourceEnabled }
            .mapTo(mutableSetOf()) { it.key }

    private fun itemFor(key: String): HomeCatalogSettingsItem =
        HomeCatalogSettingsRepository.uiState.value.items.first { it.key == key }

    @Test
    fun driftRefillRecoversASelectionStrandedOnRemovedCatalogKeys() {
        val fullAddon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4", "c5"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(fullAddon))

        // Defaults: the first two in display order are hero-enabled, the rest are not — and are
        // now stored as heroSourceEnabled=false, exactly the drift precondition.
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // A user moves the selection onto c4/c5 — c1..c3 now all carry a STORED false.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c4"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c5"), true)
        assertEquals(setOf(key("c4"), key("c5")), heroEnabledKeys())

        // The addon's manifest changes shape and c4/c5 (the whole active selection) disappear.
        val shrunkAddon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))

        // Drift-refill recovers exactly LIMIT entries among the survivors, first in display order
        // — never left stranded at zero.
        val enabled = heroEnabledKeys()
        assertEquals(HomeCatalogSettingsRepository.HERO_SOURCE_SELECTION_LIMIT, enabled.size)
        assertEquals(setOf(key("c1"), key("c2")), enabled)
        assertFalse(itemFor(key("c3")).heroSourceEnabled)
    }

    @Test
    fun deliberateAllOffSelectionOnSurvivingKeysIsNotRefilled() {
        val addon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // The user explicitly turns every hero source off, on catalogs that keep existing.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        assertTrue(heroEnabledKeys().isEmpty())

        // Re-sync with the identical catalog set — nothing vanished, so this was a deliberate
        // all-off choice, not drift, and must stay untouched.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))

        assertTrue(
            heroEnabledKeys().isEmpty(),
            "a deliberate all-off selection on surviving keys must never be silently refilled",
        )
    }

    @Test
    fun driftRefillFiresOnceAndDoesNotOverrideALaterDeliberateAllOff() {
        // Codex 2026-08-30 P2: the orphaned stored-true entries that prove drift are preserved in
        // the map, so without consuming them after the refill they would classify EVERY later
        // normalize pass as drifted — including one where the user has since deliberately turned
        // every surviving hero source off.
        val fullAddon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4", "c5"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(fullAddon))
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c4"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c5"), true)

        // Drift: the selection's keys vanish and the refill recovers c1/c2.
        val shrunkAddon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // The user then deliberately turns the refilled pair off — on keys that still exist.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        assertTrue(heroEnabledKeys().isEmpty())

        // Any later sync with the same surviving set must respect that choice: the c4/c5 orphan
        // markers were consumed by the first refill, so this is a deliberate all-off, not drift.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "the drift refill must fire once per drift, not on every pass while orphans linger",
        )
    }

    @Test
    fun partialManifestLoadNeverTreatsAnUnloadedAddonsSelectionAsDrift() {
        // Codex 2026-08-30 P1: on a cold start the callers feed syncCatalogs() only the addons
        // whose manifests are READY. An unlucky completion order used to make the selection's
        // addon look "vanished", steal its slots for the loaded subset, and consume the markers —
        // destroying a valid selection on an ordinary launch. Absent addon ⇒ not drift.
        val addonA = addonWithCatalogs(listOf("c1", "c2", "c3"))
        val addonB = addonWithCatalogs(listOf("b1", "b2"), id = "drift-test-addon-b")
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addonA, addonB))

        // Move the whole selection onto addon B.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b1", "drift-test-addon-b"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b2", "drift-test-addon-b"), true)
        assertEquals(
            setOf(key("b1", "drift-test-addon-b"), key("b2", "drift-test-addon-b")),
            heroEnabledKeys(),
        )

        // New session (in-memory reset; persisted preferences survive), and addon A's manifest
        // arrives first — B is not in this sync at all.
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addonA))

        // No refill fired: A's catalogs all carry a stored false, and B's absence is not drift.
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "an addon that has not loaded yet must not have its selection reassigned",
        )

        // B's manifest lands — the untouched selection comes straight back.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addonA, addonB))
        assertEquals(
            setOf(key("b1", "drift-test-addon-b"), key("b2", "drift-test-addon-b")),
            heroEnabledKeys(),
        )
    }

    @Test
    fun colonContainingAddonIdsDoNotFalselyReadAsPresentByPrefix() {
        // Codex 2026-08-30 round 3 P1: addon ids may contain ':'. With addon "X" loaded and addon
        // "X:sub" still loading, "X:sub"'s keys start with "X:" — a bare prefix test would call
        // them vanished-from-a-present-addon and consume the selection. The type-segment pin
        // ("X:movie:") must keep the absent addon's selection untouched.
        val base = addonWithCatalogs(listOf("c1", "c2"))
        val colonAddonId = "$addonId:sub"
        val colonAddon = addonWithCatalogs(listOf("b1", "b2"), id = colonAddonId)
        HomeCatalogSettingsRepository.syncCatalogs(listOf(base, colonAddon))

        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b1", colonAddonId), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("b2", colonAddonId), true)
        assertEquals(setOf(key("b1", colonAddonId), key("b2", colonAddonId)), heroEnabledKeys())

        // New session; only the base addon has loaded. The colon addon's keys share its prefix.
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsRepository.syncCatalogs(listOf(base))
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "the colon-prefixed sibling addon's selection must not be reassigned while it loads",
        )

        // The colon addon lands — its selection must have survived unconsumed.
        HomeCatalogSettingsRepository.syncCatalogs(listOf(base, colonAddon))
        assertEquals(setOf(key("b1", colonAddonId), key("b2", colonAddonId)), heroEnabledKeys())
    }

    @Test
    fun vanishedMarkersAreConsumedEvenWhenANewCatalogAlreadyFillsASlot() {
        // Codex 2026-08-30 P2: when the vanished selection coincides with a brand-new catalog
        // (no stored preference ⇒ defaults to enabled), the refill isn't needed — but the stale
        // markers still must be consumed, or a later deliberate all-off gets misread as drift.
        val original = addonWithCatalogs(listOf("c1", "c2"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(original))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // Same addon reshapes: the selected pair is gone, a NEW catalog appears and auto-fills.
        val reshaped = addonWithCatalogs(listOf("c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(reshaped))
        assertEquals(setOf(key("c3")), heroEnabledKeys())

        // The user deliberately turns the survivor off; a later identical sync must respect it —
        // the c1/c2 markers were consumed above even though no refill ran.
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c3"), false)
        HomeCatalogSettingsRepository.syncCatalogs(listOf(reshaped))
        assertTrue(
            heroEnabledKeys().isEmpty(),
            "stale vanished-selection markers must be consumed even when no refill was needed",
        )
    }

    /**
     * K2 deliverable 1: [HomeCatalogSettingsRepository.heroSourceKeys] reads persisted state alone
     * and must be usable BEFORE [HomeCatalogSettingsRepository.syncCatalogs] runs this session —
     * K1's hero-commit gate needs to know which catalogs the hero is waiting on before the addon
     * fan-in that populates `definitions` has completed.
     */
    @Test
    fun heroSourceKeysReturnsThePersistedSelectionBeforeSyncCatalogsRunsThisSession() {
        val addon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c3"), true)
        assertEquals(setOf(key("c2"), key("c3")), heroEnabledKeys())

        // New in-memory session (persisted payload survives) — heroSourceKeys() must reflect the
        // persisted selection WITHOUT syncCatalogs() having run yet.
        HomeCatalogSettingsRepository.clearLocalState()
        assertEquals(
            setOf(key("c2"), key("c3")),
            HomeCatalogSettingsRepository.heroSourceKeys(),
            "heroSourceKeys() must read the persisted selection even before syncCatalogs() runs",
        )
    }

    @Test
    fun heroSourceKeysExcludesCollectionKeys() {
        val collection = Collection(
            id = "drift-test-collection-2",
            title = "Collection",
            folders = listOf(CollectionFolder(id = "f1", title = "Folder")),
        )
        CollectionRepository.setCollections(listOf(collection))
        val addon = addonWithCatalogs(listOf("c1", "c2"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        // Collections are never hero sources (enforced in publish()); heroSourceKeys() must agree.
        assertEquals(setOf(key("c1"), key("c2")), HomeCatalogSettingsRepository.heroSourceKeys())
    }

    @Test
    fun heroSourceKeysFallsBackToTheFirstDefinitionsInDisplayOrderWhenNothingIsPersisted() {
        val addon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        // Nothing was ever explicitly selected — the fallback is the first LIMIT definitions.
        assertEquals(setOf(key("c1"), key("c2")), HomeCatalogSettingsRepository.heroSourceKeys())
    }

    @Test
    fun heroSourceKeysIsEmptyBeforeAnyDefinitionsOrPersistedSelectionAreKnown() {
        assertTrue(HomeCatalogSettingsRepository.heroSourceKeys().isEmpty())
        assertFalse(
            HomeCatalogSettingsRepository.heroSourceSelectionIsAllOff(),
            "no stored preference at all is 'not known yet', never a deliberate all-off",
        )
    }

    /**
     * Codex round 2 P2: a deliberate all-off selection is stored preferences with every
     * `heroSourceEnabled` false, which is NOT the "nothing persisted" fallback case. Answering it
     * with the first two definitions told K1's hero-commit gate to wait on catalogs the hero pool
     * excludes by construction, so the gate spent its whole budget and released on the timeout on
     * every launch of such a profile.
     */
    @Test
    fun heroSourceKeysIsEmptyForADeliberateAllOffSelectionRatherThanFallingBackToTheFirstDefinitions() {
        val addon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        assertEquals(setOf(key("c1"), key("c2")), HomeCatalogSettingsRepository.heroSourceKeys())

        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)

        assertTrue(
            HomeCatalogSettingsRepository.heroSourceKeys().isEmpty(),
            "an explicit all-off selection must not fall back to the first definitions",
        )
        assertTrue(HomeCatalogSettingsRepository.heroSourceSelectionIsAllOff())
    }

    @Test
    fun aCollectionOnlyPreferenceSetStillFallsBackToTheDefinitions() {
        // Collections are never hero sources, so a profile whose only stored preferences are
        // collection keys has no hero selection yet: the fallback still applies, and the all-off
        // flag must stay false or the gate would commit an empty hero on a healthy launch.
        val collection = Collection(
            id = "drift-test-collection-3",
            title = "Collection",
            folders = listOf(CollectionFolder(id = "f1", title = "Folder")),
        )
        CollectionRepository.setCollections(listOf(collection))
        HomeCatalogSettingsRepository.syncCollections(listOf(collection))
        assertFalse(HomeCatalogSettingsRepository.heroSourceSelectionIsAllOff())

        val addon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        assertEquals(setOf(key("c1"), key("c2")), HomeCatalogSettingsRepository.heroSourceKeys())
    }

    /**
     * K2 deliverable 2 (Hole D): a remote payload item for a catalog key this client has never
     * seen locally must default `heroSourceEnabled` to false once the local selection already
     * holds HERO_SOURCE_SELECTION_LIMIT true entries — never silently displace the real selection,
     * even after that key later becomes a genuine local catalog ordered ahead of it.
     */
    @Test
    fun applyFromRemoteNeverLetsAnUnknownKeyDisplaceAFullSelectionEvenAfterItReordersAheadLocally() {
        val addon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())

        // A remote payload carries a catalog key this client has never loaded, ordered AHEAD of
        // the real selection.
        val unknownKey = key("cX")
        val remotePayload = SyncHomeCatalogPayload(
            items = listOf(
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "cX", order = 0, key = unknownKey),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c1", order = 1, key = key("c1")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c2", order = 2, key = key("c2")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c3", order = 3, key = key("c3")),
            ),
        )
        HomeCatalogSettingsRepository.applyFromRemote(remotePayload)
        assertEquals(
            setOf(key("c1"), key("c2")),
            heroEnabledKeys(),
            "an unknown remote key must not become hero-selected while the local selection is full",
        )

        // The addon manifest catches up and cX becomes a real local catalog — still ordered first.
        val caughtUpAddon = addonWithCatalogs(listOf("cX", "c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(caughtUpAddon))
        assertEquals(
            setOf(key("c1"), key("c2")),
            heroEnabledKeys(),
            "the real selection must survive even once the deferred key is a genuine, ordered-first local catalog",
        )
    }

    /**
     * Codex round 2 P2: the free-slot check is a BUDGET, not a constant. It used to compare every
     * unknown remote key against the same starting count, so a single free slot admitted ALL of
     * them: three unfamiliar keys ordered ahead of the one real selection wrote four stored-true
     * entries for a cap of two, and the two-pass walk in `normalizePreferences()` (which cannot
     * tell a remote-defaulted true from a user's own) then seated the two that sorted first and
     * dropped the selection the user actually made.
     */
    @Test
    fun applyFromRemoteSpreadsTheRemainingHeroSlotsAcrossUnknownKeysInsteadOfAdmittingThemAll() {
        val addon = addonWithCatalogs(listOf("c1", "c2"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        // Exactly one of the two slots is taken, so exactly one is free.
        assertEquals(setOf(key("c1")), heroEnabledKeys())

        // Three keys this client has never seen, all ordered AHEAD of the real selection.
        val remotePayload = SyncHomeCatalogPayload(
            items = listOf(
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "cX", order = 0, key = key("cX")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "cY", order = 1, key = key("cY")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "cZ", order = 2, key = key("cZ")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c1", order = 3, key = key("c1")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c2", order = 4, key = key("c2")),
            ),
        )
        HomeCatalogSettingsRepository.applyFromRemote(remotePayload)

        assertTrue(
            key("c1") in heroEnabledKeys(),
            "the user's own selection must survive a payload that reorders unknown keys ahead of it",
        )
        assertTrue(
            heroEnabledKeys().size <= HomeCatalogSettingsRepository.HERO_SOURCE_SELECTION_LIMIT,
            "the admitted unknown keys must fit the remaining budget, never exceed the cap",
        )

        // The deferred keys become real local catalogs, still ordered first: at most the one key
        // that was admitted may share the selection, and c1 is still in it.
        val caughtUpAddon = addonWithCatalogs(listOf("cX", "cY", "cZ", "c1", "c2"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(caughtUpAddon))
        val enabled = heroEnabledKeys()
        assertTrue(key("c1") in enabled, "the real selection must survive the catch-up sync too")
        assertEquals(
            HomeCatalogSettingsRepository.HERO_SOURCE_SELECTION_LIMIT,
            enabled.size,
            "one user key plus at most one admitted unknown fills the cap exactly",
        )
    }

    /** K2 deliverable 2 (H3 no-op suppression): a byte-identical remote payload must leave the
     * published signature unchanged, so the caller can skip HomeRepository.applyCurrentSettings(). */
    @Test
    fun applyFromRemoteWithAnIdenticalPayloadLeavesTheSignatureUnchanged() {
        val addon = addonWithCatalogs(listOf("c1", "c2"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon))
        val payload = SyncHomeCatalogPayload(
            showCatalogType = true,
            items = listOf(
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c1", order = 0, key = key("c1")),
                SyncCatalogItem(addonId = addonId, type = "movie", catalogId = "c2", order = 1, key = key("c2")),
            ),
        )
        HomeCatalogSettingsRepository.applyFromRemote(payload)
        val signatureAfterFirstApply = HomeCatalogSettingsRepository.uiState.value.signature

        // Re-applying the EXACT same payload must be a true no-op at the signature level.
        HomeCatalogSettingsRepository.applyFromRemote(payload)
        assertEquals(
            signatureAfterFirstApply,
            HomeCatalogSettingsRepository.uiState.value.signature,
            "a byte-identical remote payload must never change the published signature",
        )

        // Contrast: a genuinely different payload DOES change the signature — the equality above
        // isn't vacuously true because publish() is a no-op regardless of input.
        val changedPayload = payload.copy(hideUnreleasedContent = true)
        HomeCatalogSettingsRepository.applyFromRemote(changedPayload)
        assertTrue(
            HomeCatalogSettingsRepository.uiState.value.signature != signatureAfterFirstApply,
            "a genuinely different remote payload must change the published signature",
        )
    }

    // ---------------------------------------------------------------------------------------
    // Codex round 1 P2: a collection whose CONTENTS change is not a no-op for Home
    // ---------------------------------------------------------------------------------------

    private fun collectionWithFolder(folder: CollectionFolder) = Collection(
        id = "content-drift-collection",
        title = "Collection",
        folders = listOf(folder),
    )

    /**
     * `syncCollections` compared only [HomeCatalogSettingsUiState.signature], which carries the
     * collection's key, order, enabled flag and custom title, none of which move when the
     * collection keeps its id and preferences while its folders change. The fan-out was therefore
     * suppressed, `HomeRepository.applyCurrentSettings()` never ran, and
     * `ensureCollectionHeroFallback` was never called with the request key those folders feed, so
     * the previous collection-derived hero stayed cached.
     *
     * The two assertions are the whole finding: the ui signature does NOT move (the old check
     * suppressed) while the contents digest DOES (the new check fires).
     */
    @Test
    fun aFolderContentChangeUnderAStableCollectionIdStillTriggersTheHomeFanOut() {
        val original = collectionWithFolder(
            CollectionFolder(id = "f1", title = "Folder", heroBackdropUrl = "https://cdn/one.jpg"),
        )
        HomeCatalogSettingsRepository.syncCollections(listOf(original))
        val uiSignatureBefore = HomeCatalogSettingsRepository.uiState.value.signature
        val contentSignatureBefore = HomeCatalogSettingsRepository.collectionContentSignature

        // Same collection id, same folder count (so even the "n folder(s)" subtitle is identical),
        // same preferences. Only the folder's hero art changed.
        val edited = collectionWithFolder(
            CollectionFolder(id = "f1", title = "Folder", heroBackdropUrl = "https://cdn/two.jpg"),
        )
        HomeCatalogSettingsRepository.syncCollections(listOf(edited))

        assertEquals(
            uiSignatureBefore,
            HomeCatalogSettingsRepository.uiState.value.signature,
            "the ui signature is blind to folder contents, which is why the old no-op check suppressed",
        )
        assertTrue(
            HomeCatalogSettingsRepository.collectionContentSignature != contentSignatureBefore,
            "the contents digest must move so syncCollections still fans out to HomeRepository",
        )
    }

    @Test
    fun anIdenticalCollectionReEmissionMovesNeitherSignature() {
        val collection = collectionWithFolder(
            CollectionFolder(id = "f1", title = "Folder", coverImageUrl = "https://cdn/cover.jpg"),
        )
        HomeCatalogSettingsRepository.syncCollections(listOf(collection))
        val uiSignatureBefore = HomeCatalogSettingsRepository.uiState.value.signature
        val contentSignatureBefore = HomeCatalogSettingsRepository.collectionContentSignature

        // A redundant CollectionRepository fan-out, or a sync pull that resolved to the same set.
        HomeCatalogSettingsRepository.syncCollections(listOf(collection.copy()))

        assertEquals(uiSignatureBefore, HomeCatalogSettingsRepository.uiState.value.signature)
        assertEquals(
            contentSignatureBefore,
            HomeCatalogSettingsRepository.collectionContentSignature,
            "the H3 no-op suppression must survive the added check: a true re-emission is still a no-op",
        )
    }

    @Test
    fun theContentsDigestCoversFolderOrderSourcesAndTheArtTheHeroPaintsFrom() {
        val a = CollectionFolder(id = "f1", title = "A", heroBackdropUrl = "https://cdn/a.jpg")
        val b = CollectionFolder(id = "f2", title = "B", titleLogoUrl = "https://cdn/b-logo.png")
        val base = Collection(id = "c", title = "C", folders = listOf(a, b))
        val baseline = collectionsHeroContentSignature(listOf(base))

        assertEquals(
            baseline,
            collectionsHeroContentSignature(listOf(base.copy())),
            "an equal collection set must digest identically",
        )
        assertTrue(
            collectionsHeroContentSignature(listOf(base.copy(folders = listOf(b, a)))) != baseline,
            "folder ORDER feeds the collection hero request key, so it must move the digest",
        )
        assertTrue(
            collectionsHeroContentSignature(
                listOf(base.copy(folders = listOf(a.copy(heroBackdropUrl = "https://cdn/z.jpg"), b))),
            ) != baseline,
            "a repointed hero backdrop must move the digest",
        )
        assertTrue(
            collectionsHeroContentSignature(
                listOf(base.copy(folders = listOf(a.copy(title = "A2"), b))),
            ) != baseline,
            "a renamed folder must move the digest",
        )
        assertTrue(
            collectionsHeroContentSignature(
                listOf(
                    base.copy(
                        folders = listOf(
                            a.copy(
                                sources = listOf(
                                    CollectionSource(addonId = "addon", type = "movie", catalogId = "top"),
                                ),
                            ),
                            b,
                        ),
                    ),
                ),
            ) != baseline,
            "a repointed source must move the digest: it is what the hero actually resolves from",
        )
        assertEquals(
            "",
            collectionsHeroContentSignature(listOf(base.copy(folders = emptyList()))),
            "a folderless collection never reaches Home, so it must not register as content",
        )
    }

    @Test
    fun driftRefillNeverEnablesCollectionsAndNeverExceedsTheLimit() {
        val collection = Collection(
            id = "drift-test-collection",
            title = "Collection",
            folders = listOf(CollectionFolder(id = "f1", title = "Folder")),
        )
        CollectionRepository.setCollections(listOf(collection))
        val collectionKey = "collection_${collection.id}"

        val fullAddon = addonWithCatalogs(listOf("c1", "c2", "c3", "c4", "c5"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(fullAddon))
        assertEquals(setOf(key("c1"), key("c2")), heroEnabledKeys())
        assertFalse(itemFor(collectionKey).heroSourceEnabled)

        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c1"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c2"), false)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c4"), true)
        HomeCatalogSettingsRepository.setHeroSourceEnabled(key("c5"), true)

        // Three catalogs survive (more than the limit) alongside the untouched collection.
        val shrunkAddon = addonWithCatalogs(listOf("c1", "c2", "c3"))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(shrunkAddon))

        val enabled = heroEnabledKeys()
        assertEquals(HomeCatalogSettingsRepository.HERO_SOURCE_SELECTION_LIMIT, enabled.size)
        assertFalse(collectionKey in enabled)
        assertFalse(itemFor(collectionKey).heroSourceEnabled)
    }
}
