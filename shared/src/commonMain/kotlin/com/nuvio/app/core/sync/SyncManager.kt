package com.nuvio.app.core.sync

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.collection.CollectionSyncService
import com.nuvio.app.features.home.HomeCatalogSettingsSyncService
import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.plugins.PluginSyncProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingSettingsRepository
import com.nuvio.app.features.tracking.TrackingSourceSettingsSyncService
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.tracking.effectiveLibrarySourceMode
import com.nuvio.app.features.tracking.effectiveWatchProgressSource
import com.nuvio.app.features.trakt.TraktPlatformClock
import com.nuvio.app.features.watchprogress.WatchProgressSourceCoordinator
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val FOREGROUND_PULL_DELAY_MS = 2500L
private const val FOREGROUND_ACTIVITY_PULL_MIN_INTERVAL_MS = 2 * 60_000L
private const val FULL_PULL_MIN_INTERVAL_MS = 10_000L
private const val PERIODIC_NUVIO_SYNC_PULL_INTERVAL_MS = 15 * 60_000L

// Fork: the sync primitives below are public (upstream: internal) — composeApp tests consume them cross-module.
enum class ProfileSyncStep {
    Addons,
    Plugins,
    ProfileSettings,
    // Must stay immediately after ProfileSettings: the shared-namespace tracking sources override
    // whatever the platform-scoped settings blob just applied, and the watch-source refresh below
    // has to see the winner (BUG-75).
    TrackingSourceSettings,
    // Must stay between ProfileSettings and Library: the library/watch-source steps can read
    // provider credentials, so those have to be resolved first.
    ProviderCredentials,
    Library,
    ActiveWatchSource,
    Collections,
    HomeCatalogSettings,
}

data class ProfileSyncOperations(
    val pullAddons: suspend (Int) -> Unit,
    val pullPlugins: suspend (Int) -> Unit,
    val pullProfileSettings: suspend (Int) -> Unit,
    // Defaulted so existing constructions (composeApp's cross-module tests included) still compile.
    val pullTrackingSourceSettings: suspend (Int) -> Unit = {},
    val snapshotTrackingSelection: (Int) -> Unit = {},
    val restoreTrackingSelectionAfterFailure: (Int) -> Unit = {},
    val syncProviderCredentials: suspend (Int) -> Unit,
    val pullLibrary: suspend (Int) -> Unit,
    val refreshActiveWatchSource: suspend (Int) -> Unit,
    val pullCollections: suspend (Int) -> Unit,
    val pullHomeCatalogSettings: suspend (Int) -> Unit,
)

data class ProfileActivitySyncOperations(
    val pullLibrary: suspend (Int) -> Unit,
    val pullWatchActivity: suspend (Int) -> Unit,
)

data class ProfileSyncResult(
    val failedSteps: Set<ProfileSyncStep>,
) {
    val succeeded: Boolean
        get() = failedSteps.isEmpty()
}

data class ProfilePullFreshness(
    val profileId: Int? = null,
    val completedAtEpochMs: Long = 0L,
) {
    fun isRecent(profileId: Int, nowEpochMs: Long, minIntervalMs: Long): Boolean {
        // Fork (Codex 2026-08-24): a backwards wall-clock correction makes elapsed negative, which
        // upstream's `elapsed < minIntervalMs` reads as "recent" — suppressing pulls until the
        // clock catches back up. Treat it as stale instead (same rule d0c7bff7's write dedup uses).
        val elapsedMs = nowEpochMs - completedAtEpochMs
        return this.profileId == profileId && elapsedMs >= 0L && elapsedMs < minIntervalMs
    }

    fun recordIfSuccessful(
        profileId: Int,
        completedAtEpochMs: Long,
        result: ProfileSyncResult,
    ): ProfilePullFreshness =
        if (result.succeeded) {
            ProfilePullFreshness(
                profileId = profileId,
                completedAtEpochMs = completedAtEpochMs,
            )
        } else {
            this
        }
}

suspend fun runOrderedProfileSync(
    profileId: Int,
    pluginsEnabled: Boolean,
    operations: ProfileSyncOperations,
    onFailure: (ProfileSyncStep, Throwable) -> Unit = { _, _ -> },
): ProfileSyncResult {
    val failureLock = SynchronizedObject()
    val failedSteps = mutableSetOf<ProfileSyncStep>()

    suspend fun runStep(
        step: ProfileSyncStep,
        operation: suspend (Int) -> Unit,
    ) {
        try {
            operation(profileId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            synchronized(failureLock) {
                failedSteps += step
            }
            onFailure(step, error)
        }
    }

    // Snapshot the tracking selection BEFORE the platform blob applies: if the shared-namespace
    // pull below fails, the blob's possibly-stale source values are already live, and every later
    // consumer in this sync (library pull, the resumed coordinator transitions after
    // resumeAutomaticTransitions) would otherwise run against them. The restore returns them to
    // the last-known-good selection; a user edit made mid-sync is never restored over.
    operations.snapshotTrackingSelection(profileId)
    runStep(ProfileSyncStep.ProfileSettings, operations.pullProfileSettings)
    runStep(ProfileSyncStep.TrackingSourceSettings, operations.pullTrackingSourceSettings)
    val trackingSourcesPullFailed = synchronized(failureLock) {
        ProfileSyncStep.TrackingSourceSettings in failedSteps
    }
    if (trackingSourcesPullFailed) {
        operations.restoreTrackingSelectionAfterFailure(profileId)
    }
    runStep(ProfileSyncStep.ProviderCredentials, operations.syncProviderCredentials)
    runStep(ProfileSyncStep.Addons, operations.pullAddons)
    if (pluginsEnabled) {
        runStep(ProfileSyncStep.Plugins, operations.pullPlugins)
    }

    coroutineScope {
        launch {
            runStep(ProfileSyncStep.Library, operations.pullLibrary)
        }
        launch {
            runStep(ProfileSyncStep.ActiveWatchSource) { stepProfileId ->
                // The refresh must see the shared-namespace winner. The restore above already
                // returned a failed pull's consumers to the last-known-good selection; this gate
                // stays as defense in depth (and keeps the sync recorded stale so both steps are
                // retried together).
                val trackingSourcesFailed = synchronized(failureLock) {
                    ProfileSyncStep.TrackingSourceSettings in failedSteps
                }
                if (trackingSourcesFailed) {
                    error("skipped — tracking source settings pull failed, source may be stale")
                }
                operations.refreshActiveWatchSource(stepProfileId)
            }
        }
        launch {
            runStep(ProfileSyncStep.Collections, operations.pullCollections)
        }
        launch {
            runStep(ProfileSyncStep.HomeCatalogSettings, operations.pullHomeCatalogSettings)
        }
    }
    return ProfileSyncResult(
        failedSteps = synchronized(failureLock) { failedSteps.toSet() },
    )
}

// Fork: public (upstream: internal)
suspend fun runActivityProfileSync(
    profileId: Int,
    pullLibrary: Boolean = true,
    pullWatchActivity: Boolean = true,
    operations: ProfileActivitySyncOperations,
    onFailure: (ProfileSyncStep, Throwable) -> Unit = { _, _ -> },
): ProfileSyncResult {
    val failureLock = SynchronizedObject()
    val failedSteps = mutableSetOf<ProfileSyncStep>()

    suspend fun runStep(
        step: ProfileSyncStep,
        operation: suspend (Int) -> Unit,
    ) {
        try {
            operation(profileId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            synchronized(failureLock) {
                failedSteps += step
            }
            onFailure(step, error)
        }
    }

    coroutineScope {
        if (pullLibrary) {
            launch {
                runStep(ProfileSyncStep.Library, operations.pullLibrary)
            }
        }
        if (pullWatchActivity) {
            launch {
                runStep(ProfileSyncStep.ActiveWatchSource, operations.pullWatchActivity)
            }
        }
    }
    return ProfileSyncResult(
        failedSteps = synchronized(failureLock) { failedSteps.toSet() },
    )
}

enum class ProfileSyncRequestResult {
    Started,
    Coalesced,
    Replaced,
}

// Fork: public (upstream: internal)
enum class ProfileSyncRequestKind {
    Activity,
    Full,
}

// Fork: public (upstream: internal)
class ProfileSyncRequestGate {
    private data class PendingRequest(
        val scope: CoroutineScope,
        val profileId: Int,
        val kind: ProfileSyncRequestKind,
        val block: suspend () -> Unit,
    )

    private val lock = SynchronizedObject()
    private var activeProfileId: Int? = null
    private var activeKind: ProfileSyncRequestKind? = null
    private var activeJob: Job? = null
    private var pendingRequest: PendingRequest? = null

    /**
     * @param onWillLaunch run exactly once, on the CALLING thread, for a request that will really
     * run ([ProfileSyncRequestResult.Started] or [ProfileSyncRequestResult.Replaced]) and BEFORE
     * the job it replaces is cancelled, never for a coalesced one. It receives the not-yet-started
     * job so a caller can attach a terminal handler that survives the job being cancelled before
     * its block ever runs. The single caller is `startFullProfilePull`, claiming
     * [LaunchSyncSignal] for the replacement profile ahead of the cancellation it is about to
     * cause; see the ordering note there.
     *
     * It runs while this request is still serialized, i.e. under [lock] (Codex branch review round
     * 7). Running it after the lock was released left the claim outside the ordering the gate
     * exists to impose: two requests racing a profile switch could install in the order A, B and
     * then claim in the order B, A, so the OLDER request published itself as the signal's owner,
     * its own cancelled job settled for it, and the replacement's completion was rejected as
     * stale: the exact inversion `onWillLaunch` was added to prevent, one level up. Everything the
     * callback may do is therefore bounded: take [LaunchSyncSignal]'s lock (always in that order,
     * gate then signal, so the pair cannot deadlock) and register a terminal handler on a job that
     * has not started, which cannot run inline.
     *
     * @param onCoalesced the mirror for an absorbed request, run under the same [lock] with the
     * job this request was absorbed INTO. A coalesced launch pull has no block to report progress
     * from, so it adopts that job (see [adoptCoalescedLaunchPull]); looking the job up afterwards
     * through [activeJobFor] raced the same profile switch, found nothing once a newer profile had
     * replaced the active request, and reported a definite "no burst is coming" over the newer
     * profile's Running state.
     */
    fun launch(
        scope: CoroutineScope,
        profileId: Int,
        queueIfCoalesced: Boolean = false,
        kind: ProfileSyncRequestKind = ProfileSyncRequestKind.Full,
        onWillLaunch: ((Job) -> Unit)? = null,
        onCoalesced: ((Job) -> Unit)? = null,
        block: suspend () -> Unit,
    ): ProfileSyncRequestResult {
        lateinit var newJob: Job
        var previousJob: Job? = null
        val result = synchronized(lock) {
            val active = activeJob?.takeUnless(Job::isCompleted)
            if (active != null && activeProfileId == profileId) {
                // A Full request in flight absorbs everything for this profile; an Activity
                // request only absorbs other Activity requests — an incoming Full cancels and
                // replaces it (falls through below).
                val activeRequestKind = activeKind
                if (activeRequestKind == ProfileSyncRequestKind.Full || kind == ProfileSyncRequestKind.Activity) {
                    if (queueIfCoalesced) {
                        pendingRequest = PendingRequest(scope = scope, profileId = profileId, kind = kind, block = block)
                    }
                    // The job is handed over HERE, in the same critical section that decided this
                    // request was absorbed by it, so the pair cannot come apart under a profile
                    // switch: whatever replaces the active request has to wait for this lock.
                    onCoalesced?.invoke(active)
                    return ProfileSyncRequestResult.Coalesced
                }
            }

            previousJob = active
            pendingRequest = null
            val requestResult = if (active == null) {
                ProfileSyncRequestResult.Started
            } else {
                ProfileSyncRequestResult.Replaced
            }

            newJob = scope.launch(start = CoroutineStart.LAZY) {
                block()
            }
            activeProfileId = profileId
            activeKind = kind
            activeJob = newJob
            newJob.invokeOnCompletion {
                var pending: PendingRequest? = null
                synchronized(lock) {
                    if (activeJob === newJob) {
                        activeJob = null
                        activeProfileId = null
                        activeKind = null
                        pending = pendingRequest
                        pendingRequest = null
                    }
                }
                pending?.let { request ->
                    launch(
                        scope = request.scope,
                        profileId = request.profileId,
                        queueIfCoalesced = false,
                        kind = request.kind,
                        block = request.block,
                    )
                }
            }
            // Under the lock, and before the cancellation below: the job being replaced runs its
            // own teardown as soon as it is cancelled, and anything that teardown reports must
            // already be readable as stale by the time it fires, which it is: the claim for THIS
            // request has landed by the time the lock is released, in install order.
            onWillLaunch?.invoke(newJob)
            requestResult
        }

        previousJob?.cancel()
        newJob.start()
        return result
    }

    /**
     * The request currently in flight for [profileId], or null when nothing is running for it (the
     * job finished between a [launch] returning [ProfileSyncRequestResult.Coalesced] and this call,
     * or a different profile owns the gate).
     *
     * The production adoption path does NOT use this: a lookup after the fact answers for whatever
     * request owns the gate by then, not for the one that was absorbed, so `launch`'s `onCoalesced`
     * hands the job over under the lock instead (Codex round 7 P2). Kept for tests, which drive the
     * gate a step at a time and need to see what it is holding.
     */
    fun activeJobFor(profileId: Int): Job? = synchronized(lock) {
        activeJob?.takeIf { job -> activeProfileId == profileId && !job.isCompleted }
    }

    fun cancel() {
        val job = synchronized(lock) {
            activeJob.also {
                activeJob = null
                activeProfileId = null
                activeKind = null
                pendingRequest = null
            }
        }
        job?.cancel()
    }
}

/**
 * Moves [LaunchSyncSignal] for a launch pull that was COALESCED into a full pull already in flight.
 *
 * The gap this closes: `startFullProfilePull` drives the signal from the request it hands to
 * [ProfileSyncRequestGate], and a coalesced request neither launches (so `onWillLaunch`, which
 * marks Running, is skipped) nor runs its block (so no `markSettled` fires either). When the
 * absorbing pull is the foreground escalation
 * (`requestForegroundPull` passes `updateLaunchSignal = false`, so it touches the signal at no
 * point either), the signal stays [LaunchSyncSignal.LaunchSyncState.Idle] for a signed-in account.
 * `HomeRepository.launchSyncExpected()` then reads Idle as "the burst has not started yet", and the
 * hero commit gate holds until its 4 s budget runs out: `gate=released:timeout gateWait=sync` in the
 * device probe, on a launch where nothing was actually wrong.
 *
 * The in-flight job cannot settle a signal it did not start, so the adoption attaches the settle
 * itself: mark Running for [profileId], then settle when [inFlight] completes. Both directions are
 * safe against the signal's own staleness guard: a settle for a profile the signal has since
 * stopped tracking (profile switch, sign-out, or the absorbing pull declaring NotApplicable) is
 * ignored by `markSettled`. With no job left to adopt, the burst is already over, so the gate is
 * told not to wait at all.
 *
 * Whether the adoption may speak at all is [LaunchSyncSignal.claimCoalescedLaunch]'s decision, and
 * it is per PROFILE, not per state. Only a Running or Settled state that [profileId] itself owns is
 * authoritative here; a request that ran no work of its own must not restart or downgrade that. The
 * rule used to be "claim only from Idle", which read as authoritative the one state that is most
 * often stale: profile A's launch pull settles, the user switches to profile B, B's launch pull
 * coalesces into a foreground full pull already in flight, the adoption declines because the signal
 * is not Idle, and B's hero gate then reads A's Settled as B's own: releasing, and committing a
 * hero, in the middle of B's burst.
 *
 * Called from `launch`'s `onCoalesced`, i.e. under `ProfileSyncRequestGate`'s lock, so [inFlight]
 * is the job that actually absorbed the request rather than whatever owns the gate a moment later
 * (Codex round 7 P2). The lock order is gate then signal, everywhere, and the signal never calls
 * back into the gate, so the two cannot deadlock.
 */
internal fun adoptCoalescedLaunchPull(profileId: Int, inFlight: Job?) {
    val burst = inFlight?.takeIf { job -> !job.isCompleted }
    if (!LaunchSyncSignal.claimCoalescedLaunch(profileId = profileId, burstInFlight = burst != null)) {
        return
    }
    // Attached outside the signal's lock on purpose: a handler on an already completed job runs
    // inline on the calling thread and would re-enter that lock. The claim above is the part that
    // has to be atomic; a settle landing after another profile has taken the signal over is
    // rejected by markSettled's own staleness guard.
    burst?.invokeOnCompletion { LaunchSyncSignal.markSettled(profileId) }
}

object SyncManager {
    private val log = Logger.withTag("SyncManager")
    private val syncRequestGate = ProfileSyncRequestGate()
    private val accountScopeLock = SynchronizedObject()
    private var accountScopeJob: Job = SupervisorJob()
    private var accountScope = CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("SyncManager"))
    private val pullStateLock = SynchronizedObject()
    private var foregroundPullJob: Job? = null
    private var foregroundPullProfileId: Int? = null
    private var periodicNuvioSyncPullJob: Job? = null
    private var periodicNuvioSyncProfileId: Int? = null
    private var activityPullFreshness = ProfilePullFreshness()
    private var fullPullFreshness = ProfilePullFreshness()

    private val profileSyncOperations = ProfileSyncOperations(
        pullAddons = { profileId -> AddonRepository.pullFromServer(profileId) },
        // Fork: plugins pull goes through the PluginSyncProvider seam (PluginRepository is
        // flavor-bound in composeApp), gated on the FeaturePolicy plugins flag.
        pullPlugins = { profileId ->
            if (FeaturePolicyProvider.policy.pluginsEnabled) {
                PluginSyncProvider.controller.pullFromServer(profileId)
            }
        },
        pullProfileSettings = { profileId -> ProfileSettingsSync.pull(profileId) },
        pullTrackingSourceSettings = { profileId -> TrackingSourceSettingsSyncService.pullFromServer(profileId) },
        snapshotTrackingSelection = { profileId -> TrackingSourceSettingsSyncService.snapshotSelectionBeforePlatformApply(profileId) },
        restoreTrackingSelectionAfterFailure = { profileId -> TrackingSourceSettingsSyncService.restoreSelectionAfterFailedPull(profileId) },
        syncProviderCredentials = { profileId -> ProviderCredentialSync.syncFromRemote(profileId) },
        pullLibrary = { profileId -> LibraryRepository.pullFromServer(profileId) },
        refreshActiveWatchSource = { profileId ->
            val result = WatchProgressSourceCoordinator.refreshActiveSource(profileId = profileId, force = true)
            check(result.succeeded) {
                "Active watch source refresh was incomplete: " +
                    "progress=${result.progressRefreshed} watched=${result.watchedHistoryRefreshed}"
            }
        },
        pullCollections = { profileId -> CollectionSyncService.pullFromServer(profileId) },
        pullHomeCatalogSettings = { profileId -> HomeCatalogSettingsSyncService.pullFromServer(profileId) },
    )
    private val profileActivitySyncOperations = ProfileActivitySyncOperations(
        pullLibrary = { profileId -> LibraryRepository.pullFromServer(profileId) },
        pullWatchActivity = { profileId ->
            val result = WatchProgressSourceCoordinator.refreshActiveSource(profileId = profileId, force = false)
            check(result.succeeded) {
                "Active watch source refresh was incomplete: " +
                    "progress=${result.progressRefreshed} watched=${result.watchedHistoryRefreshed}"
            }
        },
    )

    /**
     * "A profile was just picked — pull everything for it."
     *
     * tvOS calls this from `ProfilesViewModel.select`, immediately after
     * `ProfileRepository.selectProfile()` and on the same Swift main thread. A Kotlin exception
     * escaping here is not catchable on the Swift side — it reaches the Kotlin/Native
     * unhandled-exception hook and aborts the process, so a single failure turns into "the app
     * force-closes every time I pick my profile". `selectProfile` guards its own persistence and
     * fan-out for exactly this reason; this call sat outside those guards.
     *
     * Note this is the only part of a profile tap that does nothing when signed out, which is why
     * a failure here would look like a crash that only signed-in testers can hit. The sync itself
     * runs on `accountScope` (already covered by `uncaughtCoroutineLogger`) — what is guarded here
     * is the synchronous scheduling that happens on the caller's thread.
     */
    fun pullAllForProfile(profileId: Int) {
        log.i { "Full profile pull requested for profile $profileId" }
        try {
            startFullProfilePull(profileId = profileId, reason = "requested")
        } catch (error: CancellationException) {
            // composeApp calls this from coroutines — never swallow their cancellation.
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Full profile pull request failed for profile $profileId" }
            // The synchronous scheduling itself blew up before any pull could run — nothing is
            // going to mark this profile Running, so the hero gate must not wait on it forever.
            LaunchSyncSignal.markNotApplicable()
        }
    }

    // Fork: public — composeApp LocalAccountDataCleaner calls this cross-module.
    fun cancelAccountSync() {
        syncRequestGate.cancel()
        val previousAccountJob = synchronized(accountScopeLock) {
            accountScopeJob.also {
                accountScopeJob = SupervisorJob()
                accountScope = CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("SyncManager"))
            }
        }
        previousAccountJob.cancel()
        val foregroundJob = synchronized(pullStateLock) {
            foregroundPullJob.also {
                foregroundPullJob = null
                foregroundPullProfileId = null
                activityPullFreshness = ProfilePullFreshness()
                fullPullFreshness = ProfilePullFreshness()
            }
        }
        foregroundJob?.cancel()
        stopPeriodicNuvioSyncPull()
        LaunchSyncSignal.reset()
    }

    private fun accountScopeSnapshot(): CoroutineScope = synchronized(accountScopeLock) {
        accountScope
    }

    fun requestForegroundPull(profileId: Int, force: Boolean = false) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return

        if (!force && hasRecentActivityPull(profileId)) {
            return
        }
        lateinit var requestJob: Job
        var previousJob: Job? = null
        synchronized(pullStateLock) {
            if (
                !force &&
                foregroundPullJob?.isCompleted == false &&
                foregroundPullProfileId == profileId
            ) {
                return
            }

            previousJob = foregroundPullJob
            requestJob = accountScopeSnapshot().launch(start = CoroutineStart.LAZY) {
                try {
                    if (!force) {
                        delay(FOREGROUND_PULL_DELAY_MS)
                    }
                    if (!force && hasRecentActivityPull(profileId)) return@launch
                    if (ProfileRepository.activeProfileId != profileId) return@launch
                    // Escalate to a full sync when the caller forced (reconnect handlers use
                    // force=true precisely to retry everything) or when this profile has never
                    // completed one — otherwise a full pull that failed offline would only ever
                    // retry library/watch activity until the profile is reselected (Codex
                    // 2026-08-24). startFullProfilePull's own 10s gate bounds the worst case.
                    if (force || !hasCompletedFullPull(profileId)) {
                        // Foreground-triggered escalation, not the launch burst — LaunchSyncSignal
                        // tracks only the profile-select pull (K2 contract: "foreground pulls must
                        // not touch it"), so a reconnect/force full pull minutes into a session must
                        // never resurrect Running on a hero that already committed.
                        startFullProfilePull(profileId = profileId, reason = "foreground", updateLaunchSignal = false)
                    } else {
                        startActivityProfilePull(profileId = profileId, reason = "foreground")
                    }
                } finally {
                    synchronized(pullStateLock) {
                        if (foregroundPullJob === requestJob) {
                            foregroundPullJob = null
                            foregroundPullProfileId = null
                        }
                    }
                }
            }
            foregroundPullProfileId = profileId
            foregroundPullJob = requestJob
        }
        previousJob?.cancel()
        requestJob.start()
    }

    private fun hasRecentActivityPull(profileId: Int): Boolean =
        synchronized(pullStateLock) {
            activityPullFreshness.isRecent(
                profileId = profileId,
                nowEpochMs = TraktPlatformClock.nowEpochMs(),
                minIntervalMs = FOREGROUND_ACTIVITY_PULL_MIN_INTERVAL_MS,
            )
        }

    private fun hasRecentFullPull(profileId: Int): Boolean =
        synchronized(pullStateLock) {
            fullPullFreshness.isRecent(
                profileId = profileId,
                nowEpochMs = TraktPlatformClock.nowEpochMs(),
                minIntervalMs = FULL_PULL_MIN_INTERVAL_MS,
            )
        }

    // "Has ANY full pull ever succeeded for this profile since the account scope began" — the
    // freshness record only ever holds a successful pull's profile, and cancelAccountSync resets it.
    private fun hasCompletedFullPull(profileId: Int): Boolean =
        synchronized(pullStateLock) {
            fullPullFreshness.profileId == profileId
        }

    private fun startActivityProfilePull(
        profileId: Int,
        reason: String,
        pullLibrary: Boolean = true,
        pullWatchActivity: Boolean = true,
    ) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return
        if (ProfileRepository.activeProfileId != profileId) return

        val result = syncRequestGate.launch(
            scope = accountScopeSnapshot(),
            profileId = profileId,
            kind = ProfileSyncRequestKind.Activity,
        ) {
            val currentAuthState = AuthRepository.state.value
            if (currentAuthState !is AuthState.Authenticated || currentAuthState.isAnonymous) return@launch
            if (ProfileRepository.activeProfileId != profileId) return@launch

            log.i { "Activity sync started profile=$profileId reason=$reason" }
            val syncResult = runActivityProfileSync(
                profileId = profileId,
                pullLibrary = pullLibrary,
                pullWatchActivity = pullWatchActivity,
                operations = profileActivitySyncOperations,
                onFailure = { step, error ->
                    log.e(error) { "Activity sync step failed profile=$profileId step=$step" }
                },
            )
            synchronized(pullStateLock) {
                activityPullFreshness = activityPullFreshness.recordIfSuccessful(
                    profileId = profileId,
                    completedAtEpochMs = TraktPlatformClock.nowEpochMs(),
                    result = syncResult,
                )
            }
            if (!syncResult.succeeded) {
                log.w {
                    "Activity sync incomplete profile=$profileId reason=$reason failedSteps=${syncResult.failedSteps}"
                }
            }
            log.i { "Activity sync completed profile=$profileId reason=$reason" }
        }

        if (result == ProfileSyncRequestResult.Coalesced) {
            log.d { "Activity sync coalesced profile=$profileId reason=$reason" }
        }
    }

    private fun startFullProfilePull(
        profileId: Int,
        reason: String,
        queueIfCoalesced: Boolean = false,
        // K2 contract: only the profile-select launch pull drives LaunchSyncSignal. Callers of a
        // full pull triggered for any other reason (today: requestForegroundPull's reconnect/force
        // escalation) pass false so a mid-session pull never resurrects Running on an already-
        // committed hero.
        updateLaunchSignal: Boolean = true,
    ) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) {
            if (updateLaunchSignal) LaunchSyncSignal.markNotApplicable()
            return
        }
        if (ProfileRepository.activeProfileId != profileId) {
            if (updateLaunchSignal) LaunchSyncSignal.markNotApplicable()
            return
        }
        if (hasRecentFullPull(profileId)) {
            if (updateLaunchSignal) LaunchSyncSignal.markNotApplicable()
            return
        }

        val result = syncRequestGate.launch(
            scope = accountScopeSnapshot(),
            profileId = profileId,
            queueIfCoalesced = queueIfCoalesced,
            kind = ProfileSyncRequestKind.Full,
            // Codex round 1 P1: claim the signal for the REPLACEMENT profile synchronously, at
            // request time. `ProfileSyncRequestGate` cancels the pull it replaces the moment this
            // returns, and that pull's `finally` settles for the profile the signal is tracking.
            // Marking Running from inside the block below instead left a window on every profile
            // switch where the OLD pull's settle landed while the old profile was still tracked:
            // the new profile's hero gate saw Settled, released, and committed an intermediate
            // hero, before the replacement had reported itself Running at all.
            //
            // The terminal handler is attached here too, not only in the block's `finally`: a job
            // cancelled before its body ever ran executes no `finally`, and a Running that nothing
            // settles holds the hero gate for its whole 4 s budget.
            onWillLaunch = if (!updateLaunchSignal) {
                null
            } else {
                { job ->
                    LaunchSyncSignal.markRunning(profileId)
                    job.invokeOnCompletion { LaunchSyncSignal.markSettled(profileId) }
                }
            },
            // Codex round 7 P2: the adoption of an absorbing burst is decided in the same critical
            // section that absorbed this request. It used to run after `launch` returned, from a
            // second `activeJobFor` lookup, and a profile switch landing in between made that
            // lookup answer for the WRONG request: null, i.e. "no burst is coming", published over
            // the new profile's Running state and released its hero gate mid-sync. A QUEUED
            // request is the exception, as below: its block still runs and reports for itself.
            onCoalesced = if (!updateLaunchSignal || queueIfCoalesced) {
                null
            } else {
                { inFlight -> adoptCoalescedLaunchPull(profileId = profileId, inFlight = inFlight) }
            },
        ) {
            val currentAuthState = AuthRepository.state.value
            if (currentAuthState !is AuthState.Authenticated || currentAuthState.isAnonymous) {
                // markNotApplicableFor, not markNotApplicable: a superseded block still runs up to
                // its first suspension point after the gate cancels it, and must not release the
                // gate the replacement profile is waiting on.
                if (updateLaunchSignal) LaunchSyncSignal.markNotApplicableFor(profileId)
                return@launch
            }
            if (ProfileRepository.activeProfileId != profileId) {
                if (updateLaunchSignal) LaunchSyncSignal.markNotApplicableFor(profileId)
                return@launch
            }

            log.i { "Full profile sync started profile=$profileId reason=$reason" }
            WatchProgressSourceCoordinator.pauseAutomaticTransitions()
            val syncResult = try {
                runOrderedProfileSync(
                    profileId = profileId,
                    pluginsEnabled = FeaturePolicyProvider.policy.pluginsEnabled,
                    operations = profileSyncOperations,
                    onFailure = { step, error ->
                        log.e(error) { "Full profile sync step failed profile=$profileId step=$step" }
                    },
                )
            } finally {
                WatchProgressSourceCoordinator.resumeAutomaticTransitions()
                // Settled regardless of failedSteps — the gate only needs to know the burst is
                // OVER, not that it succeeded; a stalled hero is worse than one that commits raw
                // after a failed sync step.
                if (updateLaunchSignal) LaunchSyncSignal.markSettled(profileId)
            }
            synchronized(pullStateLock) {
                activityPullFreshness = activityPullFreshness.recordIfSuccessful(
                    profileId = profileId,
                    completedAtEpochMs = TraktPlatformClock.nowEpochMs(),
                    result = syncResult,
                )
                fullPullFreshness = fullPullFreshness.recordIfSuccessful(
                    profileId = profileId,
                    completedAtEpochMs = TraktPlatformClock.nowEpochMs(),
                    result = syncResult,
                )
            }
            if (!syncResult.succeeded) {
                log.w {
                    "Full profile sync incomplete profile=$profileId reason=$reason " +
                        "failedSteps=${syncResult.failedSteps}"
                }
            }
            log.i { "Full profile sync completed profile=$profileId reason=$reason" }
        }

        when (result) {
            ProfileSyncRequestResult.Started -> Unit
            ProfileSyncRequestResult.Coalesced -> {
                // The block above never runs for a coalesced request, so the launch signal has to
                // be moved from outside it or the hero commit gate waits out its whole budget on a
                // burst that is already in flight (see adoptCoalescedLaunchPull). That now happens
                // in `onCoalesced`, under the gate's lock; nothing is left to do here but log.
                log.d { "Full profile sync coalesced profile=$profileId reason=$reason" }
            }
            ProfileSyncRequestResult.Replaced -> {
                log.d { "Full profile sync replaced stale profile request with profile=$profileId reason=$reason" }
            }
        }
    }

    fun startPeriodicNuvioSyncPull(profileId: Int) {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) {
            stopPeriodicNuvioSyncPull()
            return
        }
        if (periodicNuvioSyncPullJob?.isActive == true && periodicNuvioSyncProfileId == profileId) return

        stopPeriodicNuvioSyncPull()
        periodicNuvioSyncProfileId = profileId
        periodicNuvioSyncPullJob = accountScopeSnapshot().launch {
            while (isActive) {
                delay(PERIODIC_NUVIO_SYNC_PULL_INTERVAL_MS)

                val currentAuthState = AuthRepository.state.value
                if (currentAuthState !is AuthState.Authenticated || currentAuthState.isAnonymous) {
                    continue
                }
                if (ProfileRepository.activeProfileId != profileId) {
                    continue
                }

                // Registry-driven, but still profile-scoped: the `profileId` overload fans out to
                // each provider's per-profile loader, so Trakt keeps loading exactly this
                // profile's credentials the way `TraktAuthRepository.ensureLoaded(profileId)` did.
                ensureTrackingProvidersRegistered()
                TrackingProviderRegistry.ensureLoaded(profileId)
                TrackingSettingsRepository.ensureLoaded()

                val settings = TrackingSettingsRepository.uiState.value
                val shouldPullLibrary = effectiveLibrarySourceMode(
                    requestedSource = settings.librarySourceMode,
                    isProviderAuthenticated = TrackingProviderRegistry::isAuthenticated,
                ) == LibrarySourceMode.LOCAL
                val shouldPullWatchProgress = effectiveWatchProgressSource(
                    requestedSource = settings.watchProgressSource,
                    isProviderAuthenticated = TrackingProviderRegistry::isAuthenticated,
                ) == WatchProgressSource.NUVIO_SYNC

                if (!shouldPullLibrary && !shouldPullWatchProgress) {
                    continue
                }

                startActivityProfilePull(
                    profileId = profileId,
                    reason = "periodic",
                    pullLibrary = shouldPullLibrary,
                    pullWatchActivity = shouldPullWatchProgress,
                )
            }
        }
    }

    fun stopPeriodicNuvioSyncPull() {
        periodicNuvioSyncPullJob?.cancel()
        periodicNuvioSyncPullJob = null
        periodicNuvioSyncProfileId = null
    }
}
