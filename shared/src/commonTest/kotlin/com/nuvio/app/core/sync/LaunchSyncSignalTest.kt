package com.nuvio.app.core.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * [LaunchSyncSignal] is a plain observable state holder — no network, no other singleton — so it
 * is exercised directly rather than through `SyncManager.startFullProfilePull` (private, and gated
 * on live `AuthRepository`/`ProfileRepository` state that isn't fakeable from a unit test; see the
 * house style in `AddonSyncGuardsTest`). The transition wiring asserted here mirrors exactly what
 * `SyncManager.kt` calls at each site — see the K2 report for the file:line map.
 */
class LaunchSyncSignalTest {

    @BeforeTest
    fun setUp() {
        LaunchSyncSignal.reset()
    }

    @AfterTest
    fun tearDown() {
        LaunchSyncSignal.reset()
    }

    @Test
    fun `starts Idle before anything happens`() {
        assertEquals(LaunchSyncSignal.LaunchSyncState.Idle, LaunchSyncSignal.state.value)
    }

    @Test
    fun `markNotApplicable moves to NotApplicable`() {
        LaunchSyncSignal.markNotApplicable()
        assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)
    }

    @Test
    fun `markRunning then markSettled for the same profile reaches Settled`() {
        LaunchSyncSignal.markRunning(profileId = 1)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)

        LaunchSyncSignal.markSettled(profileId = 1)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Settled, LaunchSyncSignal.state.value)
    }

    /**
     * K2 deliverable 5: "a failing pull step still ends Settled" — mirrors the exact
     * `SyncManager.startFullProfilePull` shape: `markRunning` before `runOrderedProfileSync`,
     * `markSettled` inside the `finally` so it fires regardless of `failedSteps`.
     */
    @Test
    fun `a failing sync step still ends Settled via the finally block`() = runBlocking {
        LaunchSyncSignal.markRunning(profileId = 5)

        val syncResult = try {
            runOrderedProfileSync(
                profileId = 5,
                pluginsEnabled = false,
                operations = ProfileSyncOperations(
                    pullAddons = { },
                    pullPlugins = { },
                    pullProfileSettings = { },
                    syncProviderCredentials = { },
                    pullLibrary = { error("library pull failed") },
                    refreshActiveWatchSource = { },
                    pullCollections = { },
                    pullHomeCatalogSettings = { },
                ),
            )
        } finally {
            LaunchSyncSignal.markSettled(profileId = 5)
        }

        assertEquals(false, syncResult.succeeded, "the sync itself must record the failed step")
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Settled,
            LaunchSyncSignal.state.value,
            "the signal must reach Settled even though a step failed",
        )
    }

    @Test
    fun `a stale settle for a profile no longer tracked is ignored`() {
        LaunchSyncSignal.markRunning(profileId = 1)
        // Profile switched — a NEW request supersedes the old one before it settles.
        LaunchSyncSignal.markRunning(profileId = 2)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)

        // The cancelled job for profile 1 still runs its finally block and reports settled —
        // this must NOT downgrade profile 2's still-Running state.
        LaunchSyncSignal.markSettled(profileId = 1)
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "a stale settle for a superseded profile must not overwrite the current Running state",
        )

        LaunchSyncSignal.markSettled(profileId = 2)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Settled, LaunchSyncSignal.state.value)
    }

    @Test
    fun `reset returns to Idle and clears the tracked profile`() {
        LaunchSyncSignal.markRunning(profileId = 3)
        LaunchSyncSignal.reset()
        assertEquals(LaunchSyncSignal.LaunchSyncState.Idle, LaunchSyncSignal.state.value)

        // A settle for the profile that was running before reset must not resurrect anything —
        // cancelAccountSync()'s reset() must be a true teardown.
        LaunchSyncSignal.markSettled(profileId = 3)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Idle, LaunchSyncSignal.state.value)
    }

    // -------------------------------------------------------------------------------------------
    // adoptCoalescedLaunchPull: the launch pull that never runs a block of its own
    // -------------------------------------------------------------------------------------------

    /**
     * The bug this closes, in full: `requestForegroundPull` escalates to a full pull with
     * `updateLaunchSignal = false`, the profile-select launch pull arrives while that one is still
     * in flight, `ProfileSyncRequestGate` coalesces it, and its block, the only thing that would
     * have moved the signal, never runs. The signal stays Idle for a signed-in account, so
     * `HomeRepository.launchSyncExpected()` reads it as "the burst has not started yet" and the
     * hero commit gate holds until the 4 s budget expires: `gate=released:timeout gateWait=sync`.
     */
    @Test
    fun `a coalesced launch pull adopts the in-flight burst and settles when it ends`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val escalationStarted = CompletableDeferred<Unit>()
        val releaseEscalation = CompletableDeferred<Unit>()

        // The foreground escalation: a Full pull that deliberately never touches the signal.
        val escalation = gate.launch(this, profileId = 4, kind = ProfileSyncRequestKind.Full) {
            escalationStarted.complete(Unit)
            releaseEscalation.await()
        }
        escalationStarted.await()
        assertEquals(ProfileSyncRequestResult.Started, escalation)
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Idle,
            LaunchSyncSignal.state.value,
            "a foreground escalation must not move the launch signal by itself",
        )

        // The profile-select launch pull lands on top of it and is absorbed.
        val launchPull = gate.launch(this, profileId = 4, kind = ProfileSyncRequestKind.Full) { }
        assertEquals(ProfileSyncRequestResult.Coalesced, launchPull)

        adoptCoalescedLaunchPull(profileId = 4, inFlight = gate.activeJobFor(4))
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "the coalesced pull must report the burst it was absorbed into as running",
        )

        releaseEscalation.complete(Unit)
        yield()
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Settled,
            LaunchSyncSignal.state.value,
            "the adopted job's completion must settle the signal the gate is waiting on",
        )
        gate.cancel()
    }

    @Test
    fun `a coalesced launch pull whose burst already finished does not make the gate wait`() =
        runBlocking {
            val gate = ProfileSyncRequestGate()
            // Nothing in flight for this profile: whatever absorbed the request is already over,
            // so the gate has nothing left to wait for.
            adoptCoalescedLaunchPull(profileId = 8, inFlight = gate.activeJobFor(8))
            assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)
        }

    @Test
    fun `adoption never overwrites a signal that has already moved`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        gate.launch(this, profileId = 2, kind = ProfileSyncRequestKind.Full) {
            started.complete(Unit)
            release.await()
        }
        started.await()

        // The real launch pull already reported itself; a later coalesced duplicate must not
        // restart the tracking or downgrade it.
        LaunchSyncSignal.markRunning(profileId = 2)
        adoptCoalescedLaunchPull(profileId = 2, inFlight = gate.activeJobFor(2))
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)

        LaunchSyncSignal.markSettled(profileId = 2)
        adoptCoalescedLaunchPull(profileId = 2, inFlight = gate.activeJobFor(2))
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Settled,
            LaunchSyncSignal.state.value,
            "a settled burst must not be reopened by a duplicate request",
        )

        release.complete(Unit)
        yield()
        gate.cancel()
    }

    /**
     * Codex branch review round 5: the adoption used to decline whenever the signal was not Idle,
     * which is exactly wrong for the state it is most often left in. Profile A's launch pull
     * settles; the user switches to profile B; B's launch pull is coalesced into a foreground full
     * pull already in flight (that pull passes `updateLaunchSignal = false`, so it never speaks for
     * B either). With the adoption declining, B's hero commit gate reads A's Settled as B's own
     * sync input and releases in the middle of B's burst: the reordering publish the gate exists
     * to sit in front of.
     */
    @Test
    fun `a coalesced launch pull takes the signal over from another profile's settled burst`() =
        runBlocking {
            LaunchSyncSignal.markRunning(profileId = 1)
            LaunchSyncSignal.markSettled(profileId = 1)

            val gate = ProfileSyncRequestGate()
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            gate.launch(this, profileId = 2, kind = ProfileSyncRequestKind.Full) {
                started.complete(Unit)
                release.await()
            }
            started.await()
            val coalesced = gate.launch(this, profileId = 2, kind = ProfileSyncRequestKind.Full) { }
            assertEquals(ProfileSyncRequestResult.Coalesced, coalesced)

            adoptCoalescedLaunchPull(profileId = 2, inFlight = gate.activeJobFor(2))
            assertEquals(
                LaunchSyncSignal.LaunchSyncState.Running,
                LaunchSyncSignal.state.value,
                "profile 2's burst is in flight, so the previous profile's settle is not its own",
            )

            release.complete(Unit)
            yield()
            assertEquals(
                LaunchSyncSignal.LaunchSyncState.Settled,
                LaunchSyncSignal.state.value,
                "the adopted job's completion must settle for the profile that claimed it",
            )
            gate.cancel()
        }

    /** The same takeover with nothing left to adopt: the previous profile's Settled still must not
     * stand as this profile's answer, but the verdict is "no burst to wait for", not Running. */
    @Test
    fun `a takeover with no job left reports not applicable for the new profile`() = runBlocking {
        LaunchSyncSignal.markRunning(profileId = 1)
        LaunchSyncSignal.markSettled(profileId = 1)

        val gate = ProfileSyncRequestGate()
        adoptCoalescedLaunchPull(profileId = 2, inFlight = gate.activeJobFor(2))
        assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)

        // Tracking went with it, so the older profile cannot settle over the new verdict either.
        LaunchSyncSignal.markSettled(profileId = 1)
        assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)
    }

    @Test
    fun `an adopted settle for a superseded profile is ignored`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        gate.launch(this, profileId = 1, kind = ProfileSyncRequestKind.Full) {
            started.complete(Unit)
            release.await()
        }
        started.await()
        adoptCoalescedLaunchPull(profileId = 1, inFlight = gate.activeJobFor(1))
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)

        // The user switches profile mid-burst; profile 6's own launch pull takes over the signal.
        LaunchSyncSignal.markRunning(profileId = 6)
        release.complete(Unit)
        yield()
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "the adopted completion must not settle the signal for a profile nothing is waiting on",
        )
        gate.cancel()
    }

    // -------------------------------------------------------------------------------------------
    // Codex round 1 P1: the replacement profile must own the signal BEFORE the cancellation lands
    // -------------------------------------------------------------------------------------------

    /**
     * The race, exactly: `ProfileSyncRequestGate.launch` cancels the pull it replaces as soon as
     * the request is made, and the cancelled pull's `finally` reports Settled for the profile the
     * signal is still tracking. While the replacement only claimed the signal from INSIDE its own
     * (lazily dispatched) block, the window between those two events published Settled — a release
     * state — with the new profile's hero gate already armed and watching, which is enough for an
     * intermediate hero to commit.
     *
     * `onWillLaunch` closes it by running on the requesting thread, before the cancel.
     */
    @Test
    fun `the replacement profile owns the signal before the cancelled pull settles`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val firstStarted = CompletableDeferred<Unit>()
        val firstCancelled = CompletableDeferred<Unit>()
        val observed = mutableListOf<LaunchSyncSignal.LaunchSyncState>()

        gate.launch(
            scope = this,
            profileId = 1,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { job ->
                LaunchSyncSignal.markRunning(1)
                job.invokeOnCompletion { LaunchSyncSignal.markSettled(1) }
            },
        ) {
            firstStarted.complete(Unit)
            try {
                CompletableDeferred<Unit>().await() // never completes; only cancellation ends this
            } finally {
                // Exactly what startFullProfilePull's finally does for the pull being replaced.
                LaunchSyncSignal.markSettled(1)
                observed += LaunchSyncSignal.state.value
                firstCancelled.complete(Unit)
            }
        }
        firstStarted.await()
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)

        // Profile 2 takes over. The cancellation of profile 1's job happens inside this call.
        val replaced = gate.launch(
            scope = this,
            profileId = 2,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { job ->
                LaunchSyncSignal.markRunning(2)
                job.invokeOnCompletion { LaunchSyncSignal.markSettled(2) }
            },
        ) {
            CompletableDeferred<Unit>().await()
        }
        assertEquals(ProfileSyncRequestResult.Replaced, replaced)

        firstCancelled.await()
        assertEquals(
            listOf(LaunchSyncSignal.LaunchSyncState.Running),
            observed,
            "the superseded pull's settle must be rejected as stale, leaving profile 2 Running",
        )
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)
        gate.cancel()
    }

    /**
     * The orphan the `onWillLaunch` claim could otherwise create: a job cancelled before its body
     * ever ran executes no `finally`, so nothing inside the block can settle it. A Running with no
     * settle holds the hero gate for its whole 4 s budget, which is the failure the K2 signal
     * exists to avoid. The terminal handler attached in `onWillLaunch` covers it.
     */
    @Test
    fun `a launch cancelled before its block runs still settles`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        var blockRan = false
        gate.launch(
            scope = this,
            profileId = 7,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { job ->
                LaunchSyncSignal.markRunning(7)
                job.invokeOnCompletion { LaunchSyncSignal.markSettled(7) }
            },
        ) {
            blockRan = true
        }
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)

        gate.cancel()
        yield()
        assertFalse(blockRan, "the block must not have run for this to be the case under test")
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Settled,
            LaunchSyncSignal.state.value,
            "a cancelled-before-start pull must not strand the gate on Running",
        )
    }

    // -------------------------------------------------------------------------------------------
    // Codex branch review round 7: the claim runs while the request is still serialized
    // -------------------------------------------------------------------------------------------

    /**
     * The end state of a rapid profile switch, driven through the gate exactly as
     * `startFullProfilePull` drives it. Profile A's pull is replaced by profile B's, so A's job is
     * cancelled and reports Settled for A from two places (the terminal handler attached at request
     * time and its own finally); neither may be readable as B's answer, and B's own completion must
     * still be.
     *
     * What makes that hold is WHERE the claim runs. `onWillLaunch` now fires inside
     * `ProfileSyncRequestGate.lock`, in the same critical section that installs the request, so
     * claims land in install order: a second request cannot get between A installing and A
     * claiming, publish itself, and then be overwritten by the older request's claim. The signal
     * itself cannot tell an inverted pair apart (a genuine switch and an inverted claim look
     * identical to `markRunning`), which is exactly why the ordering has to come from the lock.
     */
    @Test
    fun `a rapid profile switch leaves the signal on the replacement profile`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val firstStarted = CompletableDeferred<Unit>()
        val firstCancelled = CompletableDeferred<Unit>()
        val releaseSecond = CompletableDeferred<Unit>()

        gate.launch(
            scope = this,
            profileId = 1,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { job ->
                LaunchSyncSignal.markRunning(1)
                job.invokeOnCompletion { LaunchSyncSignal.markSettled(1) }
            },
        ) {
            firstStarted.complete(Unit)
            try {
                CompletableDeferred<Unit>().await()
            } finally {
                LaunchSyncSignal.markSettled(1)
                firstCancelled.complete(Unit)
            }
        }
        firstStarted.await()

        gate.launch(
            scope = this,
            profileId = 2,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { job ->
                LaunchSyncSignal.markRunning(2)
                job.invokeOnCompletion { LaunchSyncSignal.markSettled(2) }
            },
        ) {
            releaseSecond.await()
        }
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "the replacement profile owns the signal by the time its request returns",
        )

        firstCancelled.await()
        yield()
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "the cancelled profile's settles must not stand as the replacement's answer",
        )

        releaseSecond.complete(Unit)
        yield()
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Settled,
            LaunchSyncSignal.state.value,
            "the replacement's own completion is the settle the hero gate waits for",
        )
        gate.cancel()
    }

    /**
     * The adoption is handed the job it was absorbed INTO, from inside the critical section that
     * absorbed it. Looking the job up afterwards, through `activeJobFor`, answered for whatever
     * request owned the gate by then, which on a profile switch is a different one entirely.
     */
    @Test
    fun `a coalesced request is handed the burst that absorbed it`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val adopted = mutableListOf<Job>()

        gate.launch(this, profileId = 4, kind = ProfileSyncRequestKind.Full) {
            started.complete(Unit)
            release.await()
        }
        started.await()
        val inFlight = gate.activeJobFor(4)

        val coalesced = gate.launch(
            scope = this,
            profileId = 4,
            kind = ProfileSyncRequestKind.Full,
            onCoalesced = { job ->
                adopted += job
                adoptCoalescedLaunchPull(profileId = 4, inFlight = job)
            },
        ) { }
        assertEquals(ProfileSyncRequestResult.Coalesced, coalesced)
        assertEquals(listOf(inFlight), adopted, "the absorbing job is the one handed over")
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "the claim is complete before the coalesced request returns",
        )

        release.complete(Unit)
        yield()
        assertEquals(LaunchSyncSignal.LaunchSyncState.Settled, LaunchSyncSignal.state.value)
        gate.cancel()
    }

    /**
     * The second half of the same fix, in the signal. A coalesced request whose absorbing pull is
     * already gone reports a definite "no burst is coming", and that verdict used to be published
     * over whatever it found, including a NEWER profile's Running, claimed at request time by the
     * switch that superseded this request. The new profile's hero gate then read NotApplicable in
     * the middle of its own burst and released: a hero committed under a reordering sync, which is
     * the failure the whole gate exists to prevent.
     */
    @Test
    fun `a stale coalesced adoption cannot clear a newer profile's running burst`() {
        // Profile 2's launch pull claimed the signal when its request was made.
        LaunchSyncSignal.markRunning(profileId = 2)

        // Profile 1's coalesced request, superseded by that switch, finds nothing to adopt.
        adoptCoalescedLaunchPull(profileId = 1, inFlight = null)

        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "a stale request must not publish a release state over a running burst",
        )
        LaunchSyncSignal.markSettled(profileId = 2)
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Settled,
            LaunchSyncSignal.state.value,
            "and the running burst must still be able to settle for its own profile",
        )
    }

    /** A coalesced request never launches, so it must never claim the signal either — the
     * adoption path (already covered above) is the only thing that may speak for it. */
    @Test
    fun `a coalesced request never runs the will-launch claim`() = runBlocking {
        val gate = ProfileSyncRequestGate()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var claims = 0
        gate.launch(
            scope = this,
            profileId = 3,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { claims++ },
        ) {
            started.complete(Unit)
            release.await()
        }
        started.await()
        assertEquals(1, claims)

        val coalesced = gate.launch(
            scope = this,
            profileId = 3,
            kind = ProfileSyncRequestKind.Full,
            onWillLaunch = { claims++ },
        ) { }
        assertEquals(ProfileSyncRequestResult.Coalesced, coalesced)
        assertEquals(1, claims, "a coalesced request must not claim the signal")

        release.complete(Unit)
        yield()
        gate.cancel()
    }

    /**
     * The mirror of the P1 fix on the OTHER early-exit path: a superseded block still runs up to
     * its first suspension point after the gate cancels it, and `startFullProfilePull`'s in-block
     * "nothing to do" exits (auth dropped, active profile moved on) would otherwise publish
     * NotApplicable — a release state — for a profile nothing is waiting on.
     */
    @Test
    fun `an in-block not-applicable exit from a superseded pull is ignored`() {
        LaunchSyncSignal.markRunning(profileId = 1)
        LaunchSyncSignal.markRunning(profileId = 2)

        LaunchSyncSignal.markNotApplicableFor(profileId = 1)
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.Running,
            LaunchSyncSignal.state.value,
            "a stale block's not-applicable exit must not release the replacement's gate",
        )

        // The tracked profile's own exit still lands, and clears tracking with it.
        LaunchSyncSignal.markNotApplicableFor(profileId = 2)
        assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)
        LaunchSyncSignal.markSettled(profileId = 2)
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.NotApplicable,
            LaunchSyncSignal.state.value,
            "the terminal settle attached at request time must not reopen a not-applicable pull",
        )
    }

    /** The request-site early returns (signed out, wrong profile, recent full pull) run before any
     * tracking is claimed and must speak unconditionally: their verdict is about the profile now in
     * front, whatever an older profile's pull left behind. */
    @Test
    fun `a request-site not-applicable supersedes an older profile's running pull`() {
        LaunchSyncSignal.markRunning(profileId = 1)
        LaunchSyncSignal.markNotApplicable()
        assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)

        LaunchSyncSignal.markSettled(profileId = 1)
        assertEquals(
            LaunchSyncSignal.LaunchSyncState.NotApplicable,
            LaunchSyncSignal.state.value,
            "the superseded pull must not settle over the new profile's verdict",
        )
    }

    @Test
    fun `NotApplicable then a later profile-select run still reaches Running and Settled`() {
        LaunchSyncSignal.markNotApplicable()
        assertEquals(LaunchSyncSignal.LaunchSyncState.NotApplicable, LaunchSyncSignal.state.value)

        LaunchSyncSignal.markRunning(profileId = 9)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Running, LaunchSyncSignal.state.value)
        LaunchSyncSignal.markSettled(profileId = 9)
        assertEquals(LaunchSyncSignal.LaunchSyncState.Settled, LaunchSyncSignal.state.value)
    }
}
