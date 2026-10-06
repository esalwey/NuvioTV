package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * FEAT-10 coverage: the Search Sources setting filters the search fan-out by stable catalog
 * key (`manifestId:type:catalogId`), and [SearchRepository.searchCatalogOptions] enumerates
 * exactly the catalogs the fan-out would hit (same keys, same order).
 *
 * BUG-33 defect 1 hardening (bottom half of the file): `manifestId:type:catalogId` is not unique
 * on its own, so duplicate installs and same-type+id catalogs are disambiguated. The suffix is an
 * IDENTITY HASH (`#<8 hex>`) derived only from the member's own manifestUrl + catalog index —
 * never a positional `#2`/`#3` counter, which renumbered survivors when a colliding addon was
 * removed and silently re-enabled them.
 */
class SearchSourceFilterTest {

    /// `base#xxxxxxxx` — the only suffix shape the enumeration may mint.
    private val identitySuffix = Regex("^#[0-9a-f]{8}$")

    private fun searchCatalog(type: String, id: String, name: String = id) = AddonCatalog(
        type = type,
        id = id,
        name = name,
        extra = listOf(AddonExtraProperty(name = "search")),
    )

    /// A catalog with a required non-search extra is not search-capable and must never
    /// appear in options or requests.
    private fun nonSearchCatalog(type: String, id: String) = AddonCatalog(
        type = type,
        id = id,
        name = id,
        extra = listOf(AddonExtraProperty(name = "genre", isRequired = true)),
    )

    private fun addon(
        manifestId: String,
        catalogs: List<AddonCatalog>,
        manifestUrl: String = "https://example.test/$manifestId/manifest.json",
    ) = ManagedAddon(
        manifestUrl = manifestUrl,
        manifest = AddonManifest(
            id = manifestId,
            name = manifestId,
            description = "",
            version = "1.0.0",
            resources = emptyList(),
            types = catalogs.map { it.type }.distinct(),
            catalogs = catalogs,
            transportUrl = "https://example.test/$manifestId",
        ),
    )

    private val cinemeta = addon(
        "com.test.cinemeta",
        listOf(
            searchCatalog("movie", "top"),
            searchCatalog("series", "top"),
            nonSearchCatalog("movie", "genre-only"),
        ),
    )
    private val marvel = addon("com.test.marvel", listOf(searchCatalog("movie", "mcu")))

    /// BUG-33: the same manifest.id installed again under a different URL — a real tester setup
    /// (official addon + community mirror) that used to mint a duplicate key.
    private val marvelMirror = addon(
        "com.test.marvel",
        listOf(searchCatalog("movie", "mcu")),
        manifestUrl = "https://mirror.test/marvel/manifest.json",
    )

    /// A third install of the same manifest — needed to test survivor stability: removing one
    /// member of a 3-way collision must leave the other two keys untouched.
    private val marvelBackup = addon(
        "com.test.marvel",
        listOf(searchCatalog("movie", "mcu")),
        manifestUrl = "https://backup.test/marvel/manifest.json",
    )

    /// BUG-33: one manifest declaring several catalogs that share type+id — the other
    /// collision source. Names differ so tests can tell the entries apart.
    private val twins = addon(
        "com.test.twins",
        listOf(
            searchCatalog("movie", "popular", name = "Popular"),
            searchCatalog("movie", "popular", name = "Popular Mirror"),
            searchCatalog("movie", "popular", name = "Popular Backup"),
        ),
    )

    private fun keys(vararg addons: ManagedAddon): List<String> =
        SearchRepository.searchCatalogOptions(addons.toList()).map { it.key }

    // ---- FEAT-10 baseline: filtering by key ----

    @Test
    fun `options enumerate exactly the search-capable catalogs with stable keys`() {
        val options = SearchRepository.searchCatalogOptions(listOf(cinemeta, marvel))
        assertEquals(
            listOf(
                "com.test.cinemeta:movie:top",
                "com.test.cinemeta:series:top",
                "com.test.marvel:movie:mcu",
            ),
            options.map { it.key },
        )
        assertTrue(options.none { it.catalogName == "genre-only" })
    }

    @Test
    fun `empty disabled set keeps the full fan-out`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(cinemeta, marvel),
            query = "iron man",
        )
        assertEquals(3, requests.size)
    }

    @Test
    fun `disabled keys drop exactly their catalogs`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(cinemeta, marvel),
            query = "iron man",
            disabledCatalogKeys = setOf(
                "com.test.cinemeta:series:top",
                "com.test.marvel:movie:mcu",
            ),
        )
        assertEquals(1, requests.size)
        assertEquals("top", requests.single().catalogId)
        assertEquals("movie", requests.single().type)
    }

    @Test
    fun `unknown keys are ignored`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(marvel),
            query = "thor",
            disabledCatalogKeys = setOf("com.gone.addon:movie:old", "not-even-a-key"),
        )
        assertEquals(1, requests.size)
    }

    @Test
    fun `disabling every source empties the fan-out`() {
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(marvel),
            query = "thor",
            disabledCatalogKeys = setOf("com.test.marvel:movie:mcu"),
        )
        assertTrue(requests.isEmpty(), "search() then reports NoSearchCatalogs — the existing empty state")
    }

    @Test
    fun `options and requests agree on the key universe`() {
        val addons = listOf(cinemeta, marvel)
        val optionKeys = SearchRepository.searchCatalogOptions(addons).map { it.key }.toSet()
        // Disabling every enumerated option must silence the whole fan-out — proves the
        // settings UI's keys and the filter's keys can never drift apart.
        val requests = SearchRepository.buildSearchRequests(
            addons = addons,
            query = "iron man",
            disabledCatalogKeys = optionKeys,
        )
        assertTrue(requests.isEmpty())
    }

    // ---- BUG-33 defect 1 hardening: identity-stable collision keys ----

    @Test
    fun `non-colliding catalogs keep the bare legacy key`() {
        // The universal case: every key is byte-identical to the pre-hardening format, so no
        // persisted disablement is ever orphaned by the hardening itself.
        val bare = keys(cinemeta, marvel, addon("com.test.other", listOf(searchCatalog("series", "x"))))
        assertEquals(
            listOf(
                "com.test.cinemeta:movie:top",
                "com.test.cinemeta:series:top",
                "com.test.marvel:movie:mcu",
                "com.test.other:series:x",
            ),
            bare,
        )
        bare.forEach { key -> assertFalse(key.contains('#'), "$key must stay bare when nothing collides") }
    }

    @Test
    fun `duplicate addon installs get distinct identity-hash keys`() {
        val mcuKeys = keys(marvel, marvelMirror)
        assertEquals(2, mcuKeys.toSet().size, "duplicate installs must not share a key")
        mcuKeys.forEach { key ->
            assertTrue(key.startsWith("com.test.marvel:movie:mcu#"), "unexpected key shape: $key")
            assertTrue(
                identitySuffix.matches(key.removePrefix("com.test.marvel:movie:mcu")),
                "suffix must be an 8-hex identity hash, got: $key",
            )
        }
        // No member keeps the bare key: every colliding member is suffixed, so removing one of
        // them cannot promote another one's identity onto the bare key.
        assertFalse(mcuKeys.contains("com.test.marvel:movie:mcu"))
    }

    @Test
    fun `catalogs sharing type and id inside one manifest get distinct identity-hash keys`() {
        val options = SearchRepository.searchCatalogOptions(listOf(twins))
        assertEquals(listOf("Popular", "Popular Mirror", "Popular Backup"), options.map { it.catalogName })
        assertEquals(3, options.map { it.key }.toSet().size)
        options.forEach { option ->
            assertTrue(
                identitySuffix.matches(option.key.removePrefix("com.test.twins:movie:popular")),
                "unexpected key shape: ${option.key}",
            )
        }
    }

    @Test
    fun `key derivation is deterministic across repeated enumeration`() {
        val addons = listOf(cinemeta, twins, marvel, marvelMirror)
        // Same input ⇒ same keys; no counter state survives between enumerations, and no
        // platform-varying or time-varying input feeds the hash.
        assertEquals(
            SearchRepository.searchCatalogOptions(addons).map { it.key },
            SearchRepository.searchCatalogOptions(addons).map { it.key },
        )
    }

    @Test
    fun `removing one colliding install leaves the survivors' keys unchanged`() {
        // FINDING 2, the exact scenario: three duplicate installs, one is uninstalled. Under the
        // old positional scheme the survivors were renumbered (#3 -> #2) and their persisted
        // disablements stopped matching — a silent re-enable.
        val before = SearchRepository.searchCatalogOptions(listOf(marvel, marvelMirror, marvelBackup))
        val mirrorKey = before[1].key
        val backupKey = before[2].key

        val after = SearchRepository.searchCatalogOptions(listOf(marvelMirror, marvelBackup))
        assertEquals(listOf(mirrorKey, backupKey), after.map { it.key })

        // And the survivor's persisted disablement still governs exactly that survivor.
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(marvelMirror, marvelBackup),
            query = "thor",
            disabledCatalogKeys = setOf(backupKey),
        )
        assertEquals(listOf(mirrorKey), requests.map { it.key })
    }

    @Test
    fun `a group shrinking to one member falls back to the bare key`() {
        // Documented, accepted trade-off of "no collision means no suffix": the LAST survivor of
        // a collision group changes key once. Its stored suffixed key stops matching, so it
        // re-enables — narrow (needs the user to have disabled that one catalog AND uninstalled
        // every other member) and the alternative (permanently suffixing) would break the
        // byte-identical legacy format for everyone.
        assertEquals(listOf("com.test.marvel:movie:mcu"), keys(marvelMirror))
    }

    @Test
    fun `reordering the addon list does not change any key`() {
        // Keys depend only on each member's own identity, never on encounter order — so the
        // same three installs enumerated in reverse yield the same key SET (and, per entry, the
        // reversed order of the same keys).
        val forward = keys(marvel, marvelMirror, marvelBackup)
        val reversed = keys(marvelBackup, marvelMirror, marvel)
        assertEquals(3, forward.toSet().size)
        assertEquals(forward.reversed(), reversed)
    }

    @Test
    fun `a suffixed key disables exactly one member of the group`() {
        val options = SearchRepository.searchCatalogOptions(listOf(twins))
        val mirrorKey = options.single { it.catalogName == "Popular Mirror" }.key

        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(twins),
            query = "dune",
            disabledCatalogKeys = setOf(mirrorKey),
        )
        assertEquals(listOf("Popular", "Popular Backup"), requests.map { it.catalogName })
    }

    @Test
    fun `a legacy bare key disables the whole collision group`() {
        // FINDING 4: keys persisted before the hardening are always bare, and back then they
        // disabled every colliding catalog. The bare key must keep doing that, or upgrading
        // silently re-enables all members but one.
        val twinsDisabled = SearchRepository.buildSearchRequests(
            addons = listOf(twins),
            query = "dune",
            disabledCatalogKeys = setOf("com.test.twins:movie:popular"),
        )
        assertTrue(twinsDisabled.isEmpty(), "legacy bare key must silence all three twin catalogs")

        val installsDisabled = SearchRepository.buildSearchRequests(
            addons = listOf(marvel, marvelMirror, cinemeta),
            query = "thor",
            disabledCatalogKeys = setOf("com.test.marvel:movie:mcu"),
        )
        assertEquals(
            listOf("com.test.cinemeta:movie:top", "com.test.cinemeta:series:top"),
            installsDisabled.map { it.key },
            "the legacy key covers both installs and nothing else",
        )
    }

    @Test
    fun `isSearchSourceDisabled agrees with the fan-out filter`() {
        val addons = listOf(cinemeta, twins, marvel, marvelMirror)
        val options = SearchRepository.searchCatalogOptions(addons)
        val legacyDisabled = setOf("com.test.twins:movie:popular", "com.test.cinemeta:series:top")
        val keptKeys = SearchRepository.buildSearchRequests(addons, "iron man", legacyDisabled)
            .map { it.key }
            .toSet()

        options.forEach { option ->
            assertEquals(
                !keptKeys.contains(option.key),
                SearchRepository.isSearchSourceDisabled(option.key, legacyDisabled),
                "UI-facing rule must match the filter for ${option.key}",
            )
        }
        // A suffixed member covered only by the legacy bare key — the case a plain
        // `disabledKeys.contains(option.key)` check in the UI would miss.
        val twinKey = options.single { it.catalogName == "Popular Mirror" }.key
        assertFalse(legacyDisabled.contains(twinKey))
        assertTrue(SearchRepository.isSearchSourceDisabled(twinKey, legacyDisabled))
    }

    // ---- Codex round-2 finding N1: legacy-key migration on toggle ----

    private fun twinKeys(): Triple<String, String, String> {
        val options = SearchRepository.searchCatalogOptions(listOf(twins))
        return Triple(
            options.single { it.catalogName == "Popular" }.key,
            options.single { it.catalogName == "Popular Mirror" }.key,
            options.single { it.catalogName == "Popular Backup" }.key,
        )
    }

    @Test
    fun `enabling a legacy-disabled group member drops the bare key and pins the survivors`() {
        // FINDING N1: before the resolver, the pane removed only the row's own suffixed key —
        // which was never in the set — so the bare key survived and the row could never be
        // switched back on.
        val (popular, mirror, backup) = twinKeys()
        val legacy = setOf("com.test.twins:movie:popular")

        val next = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = false,
            currentDisabledKeys = legacy,
            addons = listOf(twins),
        )

        assertEquals(setOf(popular, backup), next, "bare key retires; the other two keep their own keys")
        assertFalse(SearchRepository.isSearchSourceDisabled(mirror, next), "the toggled row must read enabled")
        assertTrue(SearchRepository.isSearchSourceDisabled(popular, next))
        assertTrue(SearchRepository.isSearchSourceDisabled(backup, next))

        // And the fan-out agrees: exactly the toggled catalog comes back.
        val requests = SearchRepository.buildSearchRequests(listOf(twins), "dune", next)
        assertEquals(listOf("Popular Mirror"), requests.map { it.catalogName })
    }

    @Test
    fun `legacy migration spans duplicate installs of one manifest`() {
        // Same defect, the other collision source: one bare key covering two separate installs.
        val installs = listOf(marvel, marvelMirror)
        val options = SearchRepository.searchCatalogOptions(installs)
        val firstKey = options[0].key
        val mirrorKey = options[1].key

        val next = SearchRepository.resolveSearchSourceToggle(
            optionKey = firstKey,
            disabled = false,
            currentDisabledKeys = setOf("com.test.marvel:movie:mcu", "com.test.cinemeta:series:top"),
            addons = installs,
        )

        assertEquals(setOf(mirrorKey, "com.test.cinemeta:series:top"), next, "unrelated keys are untouched")
        assertFalse(SearchRepository.isSearchSourceDisabled(firstKey, next))
        assertTrue(SearchRepository.isSearchSourceDisabled(mirrorKey, next))
    }

    @Test
    fun `enabling a non-colliding catalog disabled by its bare key is a plain removal`() {
        // The catalog's own key IS the bare key, so there is no group to migrate — nothing else
        // may be added to the set.
        val next = SearchRepository.resolveSearchSourceToggle(
            optionKey = "com.test.cinemeta:series:top",
            disabled = false,
            currentDisabledKeys = setOf("com.test.cinemeta:series:top", "com.test.marvel:movie:mcu"),
            addons = listOf(cinemeta, marvel),
        )
        assertEquals(setOf("com.test.marvel:movie:mcu"), next)
    }

    @Test
    fun `enabling a member disabled by its own suffixed key leaves the group alone`() {
        // No legacy bare key in play: a suffixed member is per-member granular already, so the
        // migration branch must not fire and no sibling key may be synthesized.
        val (popular, mirror, backup) = twinKeys()
        val next = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = false,
            currentDisabledKeys = setOf(mirror, backup),
            addons = listOf(twins),
        )
        assertEquals(setOf(backup), next)
        assertFalse(SearchRepository.isSearchSourceDisabled(popular, next))
    }

    @Test
    fun `disabling writes the member's own key`() {
        val (_, mirror, _) = twinKeys()
        assertEquals(
            setOf(mirror),
            SearchRepository.resolveSearchSourceToggle(
                optionKey = mirror,
                disabled = true,
                currentDisabledKeys = emptySet(),
                addons = listOf(twins),
            ),
            "a colliding member is disabled by its suffixed key, never by the bare base key",
        )
        assertEquals(
            setOf("com.test.marvel:movie:mcu", "com.test.cinemeta:movie:top"),
            SearchRepository.resolveSearchSourceToggle(
                optionKey = "com.test.marvel:movie:mcu",
                disabled = true,
                currentDisabledKeys = setOf("com.test.cinemeta:movie:top"),
                addons = listOf(cinemeta, marvel),
            ),
        )
    }

    @Test
    fun `toggling a legacy-disabled member off again restores an equivalent set`() {
        // Round-trip: after the migration, switching the same row back off writes its own key and
        // the group is fully disabled again — just under per-member keys instead of the bare one.
        val (popular, mirror, backup) = twinKeys()
        val migrated = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = false,
            currentDisabledKeys = setOf("com.test.twins:movie:popular"),
            addons = listOf(twins),
        )
        val reDisabled = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = true,
            currentDisabledKeys = migrated,
            addons = listOf(twins),
        )
        assertEquals(setOf(popular, mirror, backup), reDisabled)
        assertTrue(SearchRepository.buildSearchRequests(listOf(twins), "dune", reDisabled).isEmpty())
    }

    @Test
    fun `enabling an already-enabled member changes nothing`() {
        val (popular, mirror, backup) = twinKeys()
        val current = setOf(backup)

        val once = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = false,
            currentDisabledKeys = current,
            addons = listOf(twins),
        )
        assertEquals(current, once, "no bare key to migrate and no own key to drop")

        val twice = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = false,
            currentDisabledKeys = once,
            addons = listOf(twins),
        )
        assertEquals(once, twice, "the resolver is idempotent")

        // Re-applying the migration is idempotent too: the second pass sees no bare key.
        val migrated = SearchRepository.resolveSearchSourceToggle(
            optionKey = mirror,
            disabled = false,
            currentDisabledKeys = setOf("com.test.twins:movie:popular"),
            addons = listOf(twins),
        )
        assertEquals(
            migrated,
            SearchRepository.resolveSearchSourceToggle(
                optionKey = mirror,
                disabled = false,
                currentDisabledKeys = migrated,
                addons = listOf(twins),
            ),
        )
        assertEquals(setOf(popular, backup), migrated)
    }

    @Test
    fun `an unknown option key falls back to plain removal`() {
        // A stale row racing an addon change: group membership is unknowable, so nothing is
        // synthesized and no unrelated key is disturbed.
        val stale = "com.gone.addon:movie:old#deadbeef"
        val next = SearchRepository.resolveSearchSourceToggle(
            optionKey = stale,
            disabled = false,
            currentDisabledKeys = setOf(stale, "com.gone.addon:movie:old", "com.test.marvel:movie:mcu"),
            addons = listOf(cinemeta, marvel),
        )
        assertEquals(setOf("com.gone.addon:movie:old", "com.test.marvel:movie:mcu"), next)
    }

    @Test
    fun `section keys stay unique under duplicate installs and unchanged otherwise`() {
        // FINDING 3: SearchView renders `ForEach(model.sections, id: \.key)`; duplicate installs
        // used to produce identical section keys and the rails collapsed.
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(cinemeta, marvel, marvelMirror, twins),
            query = "Iron Man",
        )
        val sectionKeys = requests.map { it.sectionKey() }
        assertEquals(sectionKeys.size, sectionKeys.toSet().size, "every result section needs its own identity")

        // Non-colliding catalogs keep the legacy section-key format byte-for-byte.
        assertTrue(sectionKeys.contains("com.test.cinemeta:search:movie:top:iron man"))
        assertTrue(sectionKeys.contains("com.test.cinemeta:search:series:top:iron man"))

        // Colliding ones carry the same disambiguator their catalog key does.
        requests.forEach { request ->
            val manifestId = request.addon.manifest?.id.orEmpty()
            val suffix = request.key.removePrefix("$manifestId:${request.type}:${request.catalogId}")
            assertEquals(
                "$manifestId:search:${request.type}:${request.catalogId}$suffix:iron man",
                request.sectionKey(),
            )
        }
    }

    @Test
    fun `see all targets carry the search query`() {
        // BUG-48: a search section's CatalogTarget.Addon used to drop the query it was built
        // from, so See All fetched the addon's UNFILTERED catalog — empty for search-only
        // catalogs (the grid behind BUG-47's tab-bar eject), wrong titles for browsable ones.
        val requests = SearchRepository.buildSearchRequests(
            addons = listOf(cinemeta, marvel),
            query = "Iron Man",
        )
        assertTrue(requests.isNotEmpty())
        requests.forEach { request ->
            val target = request.toCatalogTarget(manifestTransportUrl = "https://example.test/manifest.json")
            assertEquals("Iron Man", target.search, "the See All target must fetch the SEARCHED catalog")
            assertEquals(request.type, target.contentType)
            assertEquals(request.catalogId, target.catalogId)
            // And the query participates in request identity (UX-13 cross-push restoration keys
            // on CatalogRequest equality): the same catalog under a different query is a
            // different target.
            val other = request.copy(query = "Batman").toCatalogTarget("https://example.test/manifest.json")
            assertTrue(target != other, "targets for different queries must not compare equal")
        }
    }

    @Test
    fun `options and requests agree on the key universe under collisions`() {
        val addons = listOf(cinemeta, twins, marvel, marvelMirror)
        val optionKeys = SearchRepository.searchCatalogOptions(addons).map { it.key }
        assertEquals(
            optionKeys.size,
            optionKeys.toSet().size,
            "every enumerated key must be unique — SwiftUI ForEach(id: \\.key) identity depends on it",
        )
        assertEquals(optionKeys, SearchRepository.buildSearchRequests(addons, "iron man").map { it.key })

        // Disabling everything the settings pane can show silences the whole fan-out.
        assertTrue(
            SearchRepository.buildSearchRequests(addons, "iron man", optionKeys.toSet()).isEmpty(),
        )

        // And each single toggle governs exactly ONE fan-out entry — the tester-visible bug
        // ("I select only two catalogs but it searches all of them") stated as an invariant.
        optionKeys.forEach { key ->
            val remaining = SearchRepository.buildSearchRequests(addons, "iron man", setOf(key))
            assertEquals(optionKeys.size - 1, remaining.size, "disabling $key must drop exactly one catalog")
        }
    }
}
