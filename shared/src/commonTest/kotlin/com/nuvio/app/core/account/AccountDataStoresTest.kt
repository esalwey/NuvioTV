package com.nuvio.app.core.account

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Structural invariants for [AccountDataStores], the single source of truth for what a sign-out
 * wipe erases. These tests do not exercise any platform cleaner — they only prove the registry
 * itself is internally consistent, so a copy/paste slip or a too-broad prefix is caught here
 * instead of silently shipping a wipe gap (data survives sign-out) or a wipe overreach (data is
 * deleted the registry never intended to touch).
 */
class AccountDataStoresTest {

    @Test
    fun `no two stores claim the same Android preferences file`() {
        val byFile = AccountDataStores.all
            .mapNotNull { it.androidPreferences }
            .groupBy { it }
        val duplicates = byFile.filterValues { it.size > 1 }.keys
        assertTrue(duplicates.isEmpty(), "Android preference files claimed by more than one store: $duplicates")
    }

    @Test
    fun `no two stores declare the same Apple Plain key`() {
        assertNoDuplicates(
            AccountDataStores.all.flatMap { store ->
                store.appleKeys.filterIsInstance<AppleKeySpec.Plain>().map { it.key }
            },
            label = "Plain key",
        )
    }

    @Test
    fun `no two stores declare the same Apple ProfileScoped base`() {
        assertNoDuplicates(
            AccountDataStores.all.flatMap { store ->
                store.appleKeys.filterIsInstance<AppleKeySpec.ProfileScoped>().map { it.base }
            },
            label = "ProfileScoped base",
        )
    }

    @Test
    fun `no two stores declare the same Apple ProfileIndexed prefix`() {
        assertNoDuplicates(
            AccountDataStores.all.flatMap { store ->
                store.appleKeys.filterIsInstance<AppleKeySpec.ProfileIndexed>().map { it.prefix }
            },
            label = "ProfileIndexed prefix",
        )
    }

    @Test
    fun `no two stores declare the same Apple FileStore subdirectory`() {
        assertNoDuplicates(
            AccountDataStores.all.flatMap { store ->
                store.appleKeys.filterIsInstance<AppleKeySpec.FileStore>().map { it.subdirectory }
            },
            label = "FileStore subdirectory",
        )
    }

    @Test
    fun `every store is reachable by at least one platform`() {
        for (store in AccountDataStores.all) {
            assertTrue(store.name.isNotBlank(), "A store has a blank name: $store")
            val reachable = store.androidPreferences != null || store.appleKeys.isNotEmpty()
            assertTrue(
                reachable,
                "\"${store.name}\" targets neither Android nor Apple — a sign-out wipe silently skips it",
            )
        }
    }

    @Test
    fun `no identifier is blank or whitespace`() {
        for (store in AccountDataStores.all) {
            store.androidPreferences?.let {
                assertTrue(it.isNotBlank(), "\"${store.name}\" has a blank androidPreferences name")
            }
            for (key in store.appleKeys) {
                val (kind, value) = when (key) {
                    is AppleKeySpec.Plain -> "Plain" to key.key
                    is AppleKeySpec.ProfileScoped -> "ProfileScoped" to key.base
                    is AppleKeySpec.ProfileIndexed -> "ProfileIndexed" to key.prefix
                    is AppleKeySpec.DynamicPrefix -> "DynamicPrefix" to key.prefix
                    is AppleKeySpec.FileStore -> "FileStore" to key.subdirectory
                }
                assertTrue(value.isNotBlank(), "\"${store.name}\" has a blank $kind identifier")
            }
        }
    }

    @Test
    fun `projections are exactly the matching key specs from all`() {
        assertEquals(
            AccountDataStores.all.mapNotNull { it.androidPreferences }.distinct().toSet(),
            AccountDataStores.androidPreferenceNames().toSet(),
        )
        assertEquals(
            AccountDataStores.all
                .flatMap { it.appleKeys }
                .filterIsInstance<AppleKeySpec.Plain>()
                .map { it.key }
                .distinct()
                .toSet(),
            AccountDataStores.applePlainKeys().toSet(),
        )
        assertEquals(
            AccountDataStores.all
                .flatMap { it.appleKeys }
                .filterIsInstance<AppleKeySpec.ProfileScoped>()
                .map { it.base }
                .distinct()
                .toSet(),
            AccountDataStores.appleProfileScopedBases().toSet(),
        )
        assertEquals(
            AccountDataStores.all
                .flatMap { it.appleKeys }
                .filterIsInstance<AppleKeySpec.ProfileIndexed>()
                .map { it.prefix }
                .distinct()
                .toSet(),
            AccountDataStores.appleProfileIndexedPrefixes().toSet(),
        )
        assertEquals(
            AccountDataStores.all
                .flatMap { it.appleKeys }
                .filterIsInstance<AppleKeySpec.DynamicPrefix>()
                .map { it.prefix }
                .distinct()
                .toSet(),
            AccountDataStores.appleDynamicPrefixes().toSet(),
        )
        assertEquals(
            AccountDataStores.all
                .flatMap { it.appleKeys }
                .filterIsInstance<AppleKeySpec.FileStore>()
                .map { it.subdirectory }
                .distinct()
                .toSet(),
            AccountDataStores.appleFileStoreSubdirectories().toSet(),
        )
    }

    /**
     * Regression guard for the credential leak that motivated this registry: debrid provider API
     * keys and the TMDB API key must be listed, on both platforms, or a sign-out leaves a live
     * credential behind.
     */
    @Test
    fun `credential keys survive in the registry`() {
        val profileScopedBases = AccountDataStores.appleProfileScopedBases()
        assertContains(profileScopedBases, "debrid_torbox_api_key")
        assertContains(profileScopedBases, "debrid_real_debrid_api_key")
        assertContains(profileScopedBases, "debrid_alldebrid_api_key")
        assertContains(profileScopedBases, "tmdb_api_key")

        val androidPreferences = AccountDataStores.androidPreferenceNames()
        assertContains(androidPreferences, "nuvio_debrid_settings")
        assertContains(androidPreferences, "nuvio_tmdb_settings")
    }

    /**
     * A [AppleKeySpec.DynamicPrefix] is a blunt instrument: the Apple cleaners scan
     * `NSUserDefaults.dictionaryRepresentation()` and delete every key that starts with it. If a
     * prefix happened to be a literal prefix of some OTHER store's static key, the dynamic scan
     * would delete data that store never opted into wiping via that mechanism.
     *
     * A prefix matching a key declared by its OWN store is fine and expected — see
     * `DebridSettingsStorage`'s `"debrid_"` catch-all, which is deliberately broad enough to cover
     * its own listed `debrid_*` keys (and any future, unlisted provider key) in one sweep.
     *
     * One cross-store match survives here, verified benign rather than excluded blindly: see
     * [BENIGN_CROSS_STORE_PREFIX_COLLISIONS] below.
     */
    @Test
    fun `dynamic prefixes do not swallow a different store's static keys`() {
        val collisions = mutableListOf<String>()
        for (prefixStore in AccountDataStores.all) {
            val prefixes = prefixStore.appleKeys.filterIsInstance<AppleKeySpec.DynamicPrefix>()
            if (prefixes.isEmpty()) continue

            for (targetStore in AccountDataStores.all) {
                if (targetStore.name == prefixStore.name) continue // same-store sweep is intentional

                val targetKeys = targetStore.appleKeys.mapNotNull { spec ->
                    when (spec) {
                        is AppleKeySpec.Plain -> spec.key
                        is AppleKeySpec.ProfileScoped -> spec.base
                        else -> null
                    }
                }

                for (prefixSpec in prefixes) {
                    for (targetKey in targetKeys) {
                        if (!targetKey.startsWith(prefixSpec.prefix)) continue
                        if ((prefixSpec.prefix to targetKey) in BENIGN_CROSS_STORE_PREFIX_COLLISIONS) continue
                        collisions += "\"${prefixSpec.prefix}\" (${prefixStore.name}) swallows " +
                            "\"$targetKey\" (${targetStore.name})"
                    }
                }
            }
        }
        assertTrue(collisions.isEmpty(), "Unreported dynamic-prefix collisions: $collisions")
    }

    private fun assertNoDuplicates(values: List<String>, label: String) {
        val duplicates = values.groupBy { it }.filterValues { it.size > 1 }.keys
        assertTrue(duplicates.isEmpty(), "Duplicate $label values across stores: $duplicates")
    }

    private companion object {
        /**
         * Cross-store prefix/key pairs excluded from the collision check above after manual
         * verification that the overlap causes no unintended deletion. Every entry here MUST be
         * accompanied by a reason; do not add to this set to silence a genuinely new collision
         * without the same level of scrutiny.
         *
         * - `"debrid_"` (from `DebridSettingsStorage`'s catch-all `DynamicPrefix`) is also a
         *   prefix of `StreamBadgeSettingsStorage`'s `"debrid_stream_badge_rules"` `ProfileScoped`
         *   base. `StreamBadgeSettingsStorage` already lists that exact key as its own entry (kept
         *   for migration off a legacy field name), so every profile-scoped copy is wiped by that
         *   store's own `ProfileScoped` removal regardless of whether the `"debrid_"` scan also
         *   matches it. Both mechanisms agree the key must be deleted, so the broad prefix does
         *   not cause any data to be deleted (or preserved) against the registry's intent — it is
         *   redundant, not unsafe.
         */
        val BENIGN_CROSS_STORE_PREFIX_COLLISIONS: Set<Pair<String, String>> = setOf(
            "debrid_" to "debrid_stream_badge_rules",
        )
    }
}
