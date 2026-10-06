package com.nuvio.app.core.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Ordering contract for `shared`'s sync primitives — the copy tvOS actually runs. (composeApp has
 * a sibling test over the same public declarations; this one is the authoritative twin for the
 * shared module.)
 */
class SyncManagerTest {

    @Test
    fun `source prerequisites finish before source dependent pulls`() = runBlocking {
        val events = mutableListOf<String>()
        var profileSettingsApplied = false
        var credentialsApplied = false

        runOrderedProfileSync(
            profileId = 7,
            pluginsEnabled = true,
            operations = ProfileSyncOperations(
                pullAddons = { events += "addons" },
                pullPlugins = { events += "plugins" },
                pullProfileSettings = {
                    events += "settings:start"
                    yield()
                    profileSettingsApplied = true
                    events += "settings:end"
                },
                syncProviderCredentials = {
                    assertTrue(profileSettingsApplied)
                    credentialsApplied = true
                    events += "credentials"
                },
                pullLibrary = {
                    assertTrue(profileSettingsApplied)
                    assertTrue(credentialsApplied)
                    events += "library"
                },
                refreshActiveWatchSource = {
                    assertTrue(profileSettingsApplied)
                    assertTrue(credentialsApplied)
                    events += "active-watch-source"
                },
                pullCollections = { events += "collections" },
                pullHomeCatalogSettings = { events += "home-settings" },
            ),
            onFailure = { _, error -> throw error },
        )

        val lastPrerequisite = events.indexOf("settings:end")
        assertTrue(events.indexOf("addons") > lastPrerequisite)
        assertTrue(events.indexOf("plugins") > lastPrerequisite)
        assertTrue(events.indexOf("credentials") > lastPrerequisite)
        assertTrue(events.indexOf("library") > lastPrerequisite)
        assertTrue(events.indexOf("active-watch-source") > lastPrerequisite)
        assertEquals(1, events.count { it == "active-watch-source" })
    }

    @Test
    fun `disabled plugins are skipped without changing sync ordering`() = runBlocking {
        val events = mutableListOf<String>()

        runOrderedProfileSync(
            profileId = 2,
            pluginsEnabled = false,
            operations = recordingOperations(events),
            onFailure = { _, error -> throw error },
        )

        assertTrue("plugins" !in events)
        assertTrue(events.indexOf("settings") < events.indexOf("credentials"))
        assertTrue(events.indexOf("settings") < events.indexOf("library"))
        assertTrue(events.indexOf("credentials") < events.indexOf("library"))
        assertTrue(events.indexOf("credentials") < events.indexOf("active-watch-source"))
        assertTrue(events.indexOf("settings") < events.indexOf("active-watch-source"))
    }

    /**
     * The full pull (`SyncManager.startFullProfilePull`) is private and drives real repositories,
     * so it cannot be exercised directly here. What it shares with the ordered sync is this
     * invariant: provider credentials are resolved after profile settings and before the
     * library / active-watch-source fan-out, which may read them. Guarding the declared step order
     * catches an accidental reshuffle on either path.
     */
    @Test
    fun `provider credentials step sits between profile settings and the dependent steps`() {
        val steps = ProfileSyncStep.entries
        assertTrue(steps.indexOf(ProfileSyncStep.ProfileSettings) < steps.indexOf(ProfileSyncStep.ProviderCredentials))
        assertTrue(steps.indexOf(ProfileSyncStep.ProviderCredentials) < steps.indexOf(ProfileSyncStep.Library))
        assertTrue(
            steps.indexOf(ProfileSyncStep.ProviderCredentials) < steps.indexOf(ProfileSyncStep.ActiveWatchSource),
        )
    }

    /**
     * BUG-75 precedence rule: the shared tracking-source namespace is applied after the
     * platform-scoped settings blob (so it wins) and before the watch-source refresh (so the
     * refresh sees the winner).
     */
    @Test
    fun `shared tracking sources are applied after profile settings and before the watch source refresh`() = runBlocking {
        val events = mutableListOf<String>()

        runOrderedProfileSync(
            profileId = 9,
            pluginsEnabled = false,
            operations = recordingOperations(events).copy(
                pullTrackingSourceSettings = { events += "tracking-sources" },
            ),
            onFailure = { _, error -> throw error },
        )

        assertTrue(events.indexOf("settings") < events.indexOf("tracking-sources"))
        assertTrue(events.indexOf("tracking-sources") < events.indexOf("active-watch-source"))

        val steps = ProfileSyncStep.entries
        assertTrue(
            steps.indexOf(ProfileSyncStep.ProfileSettings) < steps.indexOf(ProfileSyncStep.TrackingSourceSettings),
        )
        assertTrue(
            steps.indexOf(ProfileSyncStep.TrackingSourceSettings) < steps.indexOf(ProfileSyncStep.ActiveWatchSource),
        )
    }

    @Test
    fun `duplicate active request for one profile is coalesced`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        var runCount = 0

        val first = gate.launch(this, profileId = 4) {
            runCount += 1
            firstStarted.complete(Unit)
            releaseFirst.await()
        }
        firstStarted.await()

        val duplicate = gate.launch(this, profileId = 4) {
            runCount += 1
        }

        assertEquals(ProfileSyncRequestResult.Started, first)
        assertEquals(ProfileSyncRequestResult.Coalesced, duplicate)
        assertEquals(1, runCount)

        releaseFirst.complete(Unit)
        yield()
        gate.cancel()
    }

    @Test
    fun `full request replaces activity request for the same profile`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val activityStarted = CompletableDeferred<Unit>()
        val activityCancelled = CompletableDeferred<Unit>()
        val fullCompleted = CompletableDeferred<Unit>()

        gate.launch(this, profileId = 1, kind = ProfileSyncRequestKind.Activity) {
            activityStarted.complete(Unit)
            try {
                CompletableDeferred<Unit>().await()
            } finally {
                activityCancelled.complete(Unit)
            }
        }
        activityStarted.await()

        val replacement = gate.launch(this, profileId = 1, kind = ProfileSyncRequestKind.Full) {
            fullCompleted.complete(Unit)
        }

        assertEquals(ProfileSyncRequestResult.Replaced, replacement)
        activityCancelled.await()
        fullCompleted.await()
        gate.cancel()
    }

    @Test
    fun `activity sync runs only requested domains`() = runBlocking {
        val events = mutableListOf<String>()
        val operations = ProfileActivitySyncOperations(
            pullLibrary = { events += "library" },
            pullWatchActivity = { events += "watch" },
        )

        val libraryOnly = runActivityProfileSync(
            profileId = 1,
            pullLibrary = true,
            pullWatchActivity = false,
            operations = operations,
        )
        val watchOnly = runActivityProfileSync(
            profileId = 1,
            pullLibrary = false,
            pullWatchActivity = true,
            operations = operations,
        )

        assertTrue(libraryOnly.succeeded)
        assertTrue(watchOnly.succeeded)
        assertEquals(listOf("library", "watch"), events)
    }

    @Test
    fun `failed step is reported by ordered sync result`() = runBlocking {
        val result = runOrderedProfileSync(
            profileId = 3,
            pluginsEnabled = false,
            operations = recordingOperations(mutableListOf()).copy(
                refreshActiveWatchSource = { error("source refresh failed") },
            ),
        )

        assertFalse(result.succeeded)
        assertEquals(setOf(ProfileSyncStep.ActiveWatchSource), result.failedSteps)
    }

    @Test
    fun `failed provider credential sync does not abort the remaining steps`() = runBlocking {
        val events = mutableListOf<String>()

        val result = runOrderedProfileSync(
            profileId = 5,
            pluginsEnabled = false,
            operations = recordingOperations(events).copy(
                syncProviderCredentials = { error("credential sync failed") },
            ),
        )

        assertFalse(result.succeeded)
        assertEquals(setOf(ProfileSyncStep.ProviderCredentials), result.failedSteps)
        assertTrue("library" in events)
        assertTrue("active-watch-source" in events)
    }

    private fun recordingOperations(events: MutableList<String>): ProfileSyncOperations =
        ProfileSyncOperations(
            pullAddons = { events += "addons" },
            pullPlugins = { events += "plugins" },
            pullProfileSettings = { events += "settings" },
            syncProviderCredentials = { events += "credentials" },
            pullLibrary = { events += "library" },
            refreshActiveWatchSource = { events += "active-watch-source" },
            pullCollections = { events += "collections" },
            pullHomeCatalogSettings = { events += "home-settings" },
        )
}
