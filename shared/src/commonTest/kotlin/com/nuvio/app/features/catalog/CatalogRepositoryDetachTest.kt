package com.nuvio.app.features.catalog

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

/**
 * H1 hardening (BUG-47 / UX-13) coverage for [CatalogRepository.detach].
 *
 * `CatalogRepository` is a singleton whose fetch paths (`fetchCatalogPage`,
 * `TmdbCollectionSourceResolver`, `LibraryRepository`, …) make real network/storage calls with no
 * fake or dispatcher seam exposed to this test target — the same reason the rest of this module's
 * tests (e.g. `LibraryRepositoryTest`) exercise pure state helpers rather than the network-coupled
 * repository object directly. A full "load() populates items over the network, detach(), reload()
 * with the same target early-returns with items intact, reload() with a different target resets"
 * round trip therefore isn't exercisable here without a network fake this codebase doesn't have.
 *
 * What IS testable without that dependency is the state-shape contract `detach()` promises
 * relative to `clear()` (see both doc comments in CatalogRepository.kt): `detach()` must never
 * emit a fresh [CatalogUiState] and must never touch `scrollPositions`, which is exactly the
 * difference from `clear()` BUG-47/UX-13 depend on.
 */
class CatalogRepositoryDetachTest {

    private val target = CatalogTarget.Addon(
        manifestUrl = "https://example.test/manifest.json",
        contentType = "movie",
        catalogId = "top",
    )

    @AfterTest
    fun tearDown() {
        // CatalogRepository is a process-wide singleton — leave it clean for any other test.
        CatalogRepository.clear()
    }

    @Test
    fun `detach on an idle repository does not emit a new state`() {
        CatalogRepository.clear()
        val before = CatalogRepository.uiState.value

        CatalogRepository.detach()

        assertSame(before, CatalogRepository.uiState.value, "detach() must not emit while idle")
    }

    @Test
    fun `detach is safe to call repeatedly with no active fetch`() {
        CatalogRepository.clear()

        // No active job to cancel on any of these — must not throw, must not emit.
        val before = CatalogRepository.uiState.value
        CatalogRepository.detach()
        CatalogRepository.detach()
        CatalogRepository.detach()

        assertSame(before, CatalogRepository.uiState.value)
    }

    @Test
    fun `detach preserves saved scroll positions unlike clear`() {
        CatalogRepository.clear()
        CatalogRepository.saveScrollPosition(
            target = target,
            firstVisibleItemIndex = 4,
            firstVisibleItemScrollOffset = 120,
        )

        CatalogRepository.detach()

        val retained = CatalogRepository.scrollPosition(target)
        assertEquals(4, retained.firstVisibleItemIndex)
        assertEquals(120, retained.firstVisibleItemScrollOffset)

        // Contrast: clear() is the full-wipe variant (sign-out) and must still discard it — this
        // guards against the hardening accidentally weakening clear()'s own contract too.
        CatalogRepository.clear()
        assertEquals(CatalogScrollPosition(), CatalogRepository.scrollPosition(target))
    }
}
