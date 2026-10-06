package com.nuvio.app.features.home

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// Pure-function coverage for the syncCatalogs() empty-definition-set guard (see
// docs/steven-batch-plan-2026-08-29.md). Deliberately does not touch HomeCatalogSettingsRepository
// itself — it's a singleton with storage/platform dependencies — so this only exercises the
// top-level decision function the repository delegates to.
class HomeCatalogDefinitionsGuardTest {
    @Test
    fun `allows a fresh-boot no-op when both counts are zero`() {
        assertTrue(shouldReplaceCatalogDefinitions(currentCount = 0, incomingCount = 0))
    }

    @Test
    fun `allows replacing an empty set with a populated one`() {
        assertTrue(shouldReplaceCatalogDefinitions(currentCount = 0, incomingCount = 3))
    }

    @Test
    fun `blocks a transient empty set from wiping a known non-empty set`() {
        assertFalse(shouldReplaceCatalogDefinitions(currentCount = 3, incomingCount = 0))
    }

    @Test
    fun `allows replacing a non-empty set with a smaller non-empty set`() {
        assertTrue(shouldReplaceCatalogDefinitions(currentCount = 3, incomingCount = 2))
    }

    @Test
    fun `allows replacing a non-empty set with an equal-sized set`() {
        assertTrue(shouldReplaceCatalogDefinitions(currentCount = 3, incomingCount = 3))
    }
}
