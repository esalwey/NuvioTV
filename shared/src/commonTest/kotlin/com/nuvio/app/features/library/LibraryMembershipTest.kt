package com.nuvio.app.features.library

import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingMembershipApplyResult
import com.nuvio.app.features.tracking.TrackingMembershipRemovalConfirmation
import com.nuvio.app.features.tracking.TrackingMembershipRemovalImpact
import com.nuvio.app.features.tracking.TrackingMembershipResolution
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LibraryMembershipTest {
    private val statuses = listOf(
        simklTab("simkl:plantowatch", "Simkl Plan to Watch"),
        simklTab("simkl:watching", "Simkl Watching"),
    )

    private fun item() = LibraryItem(id = "tt1", type = "movie", name = "Heat", savedAtEpochMs = 0L)

    private fun simklTab(key: String, title: String) = TrackingLibraryTab(
        key = key,
        title = title,
        providerId = TrackingProviderId.SIMKL,
        kind = TrackingLibraryTabKind.STATUS,
        selectionGroup = "status",
    )

    @Test
    fun `picking a status clears the other statuses of the same provider`() {
        val editor = LibraryMembershipEditor(
            item(),
            statuses,
            mapOf("simkl:plantowatch" to true, "simkl:watching" to false),
        )
        assertFalse(editor.hasChanges)

        editor.toggle("simkl:watching")

        assertTrue(editor.hasChanges)
        assertEquals(listOf(false, true), editor.options().map { it.isSelected })
    }

    @Test
    fun `options carry the provider name as their group`() {
        val editor = LibraryMembershipEditor(item(), statuses, emptyMap())
        assertEquals(listOf("Simkl", "Simkl"), editor.options().map { it.groupTitle })
    }

    @Test
    fun `a result that needs confirmation reports the providers and impact and retries with them`() = runBlocking {
        val result = TrackingMembershipApplyResult(
            requiredRemovalConfirmations = listOf(
                TrackingMembershipRemovalConfirmation(
                    TrackingProviderId.SIMKL,
                    setOf(TrackingMembershipRemovalImpact.WATCHED_HISTORY, TrackingMembershipRemovalImpact.RATING),
                ),
            ),
        )
        var retriedWith: Set<TrackingProviderId>? = null
        val done = result.toOutcome("Heat") { providers ->
            retriedWith = providers
            TrackingMembershipApplyResult().toOutcome("Heat") { error("not needed") }
        }

        assertTrue(done.requiresConfirmation)
        assertEquals(listOf("Simkl"), done.providerNames)
        assertEquals(LibraryRemovalImpact.WATCHED_HISTORY_AND_RATING, done.removalImpact)

        val applied = done.confirmRemoval()

        assertEquals(setOf(TrackingProviderId.SIMKL), retriedWith)
        assertFalse(applied.requiresConfirmation)
    }

    @Test
    fun `removal impact narrows to a single kind`() {
        fun impact(vararg impacts: TrackingMembershipRemovalImpact) = removalImpact(
            listOf(TrackingMembershipRemovalConfirmation(TrackingProviderId.SIMKL, impacts.toSet())),
        )
        assertEquals(LibraryRemovalImpact.WATCHED_HISTORY, impact(TrackingMembershipRemovalImpact.WATCHED_HISTORY))
        assertEquals(LibraryRemovalImpact.RATING, impact(TrackingMembershipRemovalImpact.RATING))
    }

    @Test
    fun `a rewritten list is reported with provider-free titles`() {
        val result = TrackingMembershipApplyResult(
            resolutions = listOf(
                TrackingMembershipResolution(TrackingProviderId.SIMKL, "simkl:plantowatch", "simkl:watching"),
                TrackingMembershipResolution(TrackingProviderId.SIMKL, "simkl:completed", "simkl:completed"),
            ),
        )

        val outcome = result.toOutcome("Heat", statuses) { error("not needed") }

        assertFalse(outcome.requiresConfirmation)
        val rewrite = outcome.rewrites.single()
        assertEquals("Simkl", rewrite.providerName)
        assertEquals("Plan to Watch", rewrite.requestedTitle)
        assertEquals("Watching", rewrite.resolvedTitle)
    }

    @Test
    fun `unknown list keys fall back to their last segment`() {
        assertEquals("completed", statuses.rewriteTitle("simkl:completed", "Simkl"))
    }
}
