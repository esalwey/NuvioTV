import Combine
import Foundation
import SharedCore

/// Backs the Settings "Simkl" section. Wraps the shared `SimklAuthRepository` PIN-code flow:
/// `connect()` asks Simkl for a user code — the repo publishes it (plus the verification URL) via
/// its uiState and polls `/oauth/pin/{user_code}` in the background until the user approves the
/// code at simkl.com/pin on another device (or it expires). Once connected, Simkl becomes usable
/// as a Library Source / Watch Progress Source (Content Sources pane), and both players scrobble it
/// as you play: their start and stop go through `TrackingScrobbleCoordinator.scrobbleOtherTrackers`
/// (every connected tracker but Trakt, which keeps its direct `TraktScrobbleRepository` calls), and a
/// stop commits into the Simkl snapshot, so Continue Watching follows the episode just played.
/// Registering the SCROBBLE capability alone reaches nothing: the players have to make that call.
///
/// Structurally a clone of `TraktViewModel` — same published shape, same start/stop/connect/
/// cancelActivation/disconnect surface — so the Settings pane can render both with one card layout.
@MainActor
final class SimklViewModel: ObservableObject {
    @Published private(set) var credentialsConfigured = true
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var username: String?
    /// Non-nil while a PIN flow is pending approval — drives the activation card.
    @Published private(set) var deviceUserCode: String?
    @Published private(set) var deviceVerificationUrl: String?
    @Published private(set) var errorMessage: String?

    // MARK: - Manual sync ("Sync Now") + Simkl features (deferred-parity set)

    /// True while a manual or background snapshot refresh is running — drives the Sync Now row's
    /// spinner/label swap.
    @Published private(set) var isSyncing = false
    /// Whatever went wrong most recently: our own `refresh` call throwing, else the shared sync
    /// state's own message. Rendered as a non-blocking caption under the row.
    @Published private(set) var syncErrorMessage: String?
    /// Timestamp of the last committed snapshot (`SimklSyncSnapshot.lastSyncedAtEpochMs`), nil
    /// until the first successful sync.
    @Published private(set) var lastSyncedAt: Date?
    /// Chip/menu key for the anime-ID preference — "imdb", "mal" or "kitsu". A string key rather
    /// than the bridged Kotlin enum, matching `SettingsViewModel.librarySourceMode`'s pattern, so
    /// the view never has to switch over a Kotlin enum entry.
    @Published private(set) var animeIdPreference = "imdb"

    private var watcher: FlowWatcher?
    private var syncWatcher: FlowWatcher?
    private var trackingSettingsWatcher: FlowWatcher?

    /// Last emission from `SimklSyncRepository.state`, kept so the published trio above can be
    /// recomputed from BOTH it and the local in-flight/failure flags in one place.
    private var syncState: SimklSyncUiState?
    /// Set when our own `refresh` call comes back with an error. A fast failure (no client id, no
    /// network stack) never reaches the shared state's `errorMessage`, so without this the row
    /// would silently do nothing. Cleared on the next Sync Now press — or automatically once a
    /// LATER refresh (e.g. a background/automatic one) commits a newer snapshot (Codex review:
    /// without that, a stale failure caption outlives the recovery until the user retries).
    private var localSyncFailure: String?
    /// `lastSyncedAtEpochMs` at the moment `localSyncFailure` was set; a newer committed snapshot
    /// clears the failure in `publishSyncState`.
    private var localSyncFailureSnapshotStamp: Int64?
    /// True between the Sync Now press and its completion. Combined with the shared state's
    /// `isLoading` because a refresh that is rejected before it starts loading never flips that
    /// flag — deriving the spinner from the flow alone can leave the row stuck (or never spin).
    private var syncRequestInFlight = false

    func start() {
        guard watcher == nil else { return }
        SimklAuthRepository.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        watcher = FlowWatcherKt.watch(SimklAuthRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? SimklAuthUiState else { return }
            self.credentialsConfigured = state.credentialsConfigured
            self.isConnected = state.mode == .connected
            self.isLoading = state.isLoading
            self.username = state.username
            self.deviceUserCode = state.deviceUserCode
            self.deviceVerificationUrl = state.deviceVerificationUrl
            let error = state.errorMessage ?? ""
            self.errorMessage = error.isEmpty ? nil : error
        }

        // Sync state (snapshot freshness + in-flight + error). `ensureLoaded()` first, exactly like
        // upstream's Compose card does before it collects this flow: it seeds the state from the
        // cached snapshot so "Last synced …" is right on the first frame.
        SimklSyncRepository.shared.ensureLoaded()
        syncWatcher = FlowWatcherKt.watch(SimklSyncRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? SimklSyncUiState else { return }
            self.syncState = state
            self.publishSyncState()
        }

        // Anime ID preference. Persisted through the provider-neutral tracking settings facade
        // (`TrackingSettingsUiState` is a Kotlin typealias for `TraktSettingsUiState`, so that's
        // what the emission casts to — same as SettingsViewModel's watcher on this flow).
        TrackingSettingsRepository.shared.ensureLoaded()
        trackingSettingsWatcher = FlowWatcherKt.watch(TrackingSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TraktSettingsUiState else { return }
            self.animeIdPreference = Self.animeIdKey(state.simklAnimeIdPreference)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        syncWatcher?.cancel()
        syncWatcher = nil
        trackingSettingsWatcher?.cancel()
        trackingSettingsWatcher = nil
        // Note: an in-flight PIN flow keeps polling inside the shared repo even while
        // unsubscribed, so leaving Settings mid-activation doesn't abort the sign-in. The same is
        // true of an in-flight sync: `SimklSyncRepository` owns its own scope, so leaving Settings
        // mid-sync lets it finish and commit.
    }

    func connect() {
        SimklAuthRepository.shared.onStartDeviceFlow(profileId: ProfileRepository.shared.activeProfileId)
    }

    func cancelActivation() {
        SimklAuthRepository.shared.onCancelDeviceFlow(profileId: ProfileRepository.shared.activeProfileId)
    }

    func disconnect() {
        SimklAuthRepository.shared.onDisconnectRequested(profileId: ProfileRepository.shared.activeProfileId)
    }

    // MARK: - Sync Now

    /// Manual full refresh of the Simkl snapshot — the tvOS equivalent of upstream's "Sync now"
    /// button on the Simkl provider card.
    ///
    /// `USER_INITIATED` deliberately bypasses the 15-minute freshness gate in
    /// `shouldRunSimklRefresh` (that gate only applies to `AUTOMATIC`), so pressing this always
    /// hits the network — which is the entire point of the row.
    ///
    /// Never wedges: the completion always fires (Kotlin converts even cancellation into an
    /// error), and the in-flight flag is cleared there before anything else. A press while a sync
    /// is already running is a no-op rather than a queued second network call.
    func syncNow() {
        guard !isSyncing else { return }
        localSyncFailure = nil
        localSyncFailureSnapshotStamp = nil
        syncRequestInFlight = true
        publishSyncState()

        SimklSyncRepository.shared.refresh(intent: TrackingRefreshIntent.userInitiated) { [weak self] succeeded, error in
            // The suspend bridge resolves on whichever thread finished the coroutine, so hop back
            // to the main actor before touching any @Published property.
            Task { @MainActor in
                guard let self else { return }
                self.syncRequestInFlight = false
                if let error {
                    self.localSyncFailure = error.localizedDescription
                } else if succeeded?.boolValue != true {
                    // Codex review: the engine reports handled failures (e.g. network errors it
                    // absorbed) as `false` with a nil bridge error. Treat that as a failure too —
                    // the shared state's errorMessage carries the specifics, and skipping the
                    // read-model refresh below keeps the coordinator's stop-on-failed-provider
                    // rule (its adapters could otherwise fire a duplicate failed network sync).
                    let remoteMessage = self.syncState?.errorMessage ?? ""
                    self.localSyncFailure = remoteMessage.isEmpty
                        ? String(localized: "Sync didn't complete. Try again.")
                        : remoteMessage
                }
                if self.localSyncFailure != nil {
                    self.localSyncFailureSnapshotStamp =
                        self.syncState?.snapshot.lastSyncedAtEpochMs?.int64Value
                }
                self.publishSyncState()
                self.refreshActiveSourceIfSimklOwnsIt()
            }
        }
    }

    /// Second half of upstream's coordination rule: once the provider snapshot is fresh, the
    /// application read models built on top of it (Continue Watching / watched) are rebuilt — but
    /// only when Simkl is the source they are currently built from.
    ///
    /// Upstream calls `WatchProgressSourceCoordinator.refreshProviderAndActiveSource(...)`, which
    /// wraps both halves. That seam takes a `suspend () -> Boolean`, which crosses the ObjC bridge
    /// as `KotlinSuspendFunction0` — Swift cannot hand one over without implementing a Kotlin
    /// function type, so the two halves are called directly instead, gated on the same rule the
    /// coordinator applies internally. `activeSourceState` is the source actually APPLIED to the
    /// repositories (not the stored preference), which is exactly what the coordinator compares.
    private func refreshActiveSourceIfSimklOwnsIt() {
        guard localSyncFailure == nil else { return }
        guard let applied = WatchProgressRepository.shared.activeSourceState.value_ as? WatchProgressSource,
              applied == .simkl else { return }
        // force: false — the snapshot was just refreshed above; this only re-projects it.
        WatchProgressSourceCoordinator.shared.refreshActiveSource(
            profileId: ProfileRepository.shared.activeProfileId,
            force: false
        ) { _, _ in }
    }

    /// Single place the sync-related published properties are derived, so the local in-flight /
    /// failure flags and the shared flow can never contradict each other.
    private func publishSyncState() {
        isSyncing = syncRequestInFlight || (syncState?.isLoading ?? false)

        // A refresh that committed a NEWER snapshot than the one the failure was recorded
        // against means some later sync succeeded (background/automatic included) — retire the
        // stale local failure instead of showing it until the next manual press.
        if localSyncFailure != nil, !isSyncing,
           let current = syncState?.snapshot.lastSyncedAtEpochMs?.int64Value,
           current > (localSyncFailureSnapshotStamp ?? Int64.min) {
            localSyncFailure = nil
            localSyncFailureSnapshotStamp = nil
        }

        let remoteMessage = syncState?.errorMessage ?? ""
        syncErrorMessage = localSyncFailure ?? (remoteMessage.isEmpty ? nil : remoteMessage)

        if let epochMs = syncState?.snapshot.lastSyncedAtEpochMs {
            lastSyncedAt = Date(timeIntervalSince1970: epochMs.doubleValue / 1000)
        } else {
            lastSyncedAt = nil
        }
    }

    // MARK: - Anime ID preference

    /// Persists the anime canonical-ID choice. The shared setter also calls
    /// `SimklSyncRepository.invalidateProjections()` (the choice feeds `SimklProjections`), so no
    /// extra refresh is needed here — library/watched/CW recompute from the cached snapshot.
    func setAnimeIdPreference(_ key: String) {
        let preference: SimklAnimeIdPreference
        switch key {
        case "mal": preference = .mal
        case "kitsu": preference = .kitsu
        case "tvdb": preference = .tvdb
        default: preference = .imdb
        }
        TrackingSettingsRepository.shared.setSimklAnimeIdPreference(preference: preference)
    }

    /// Bridged Kotlin enum → chip key. Compared with `==` rather than switched over, same caution
    /// as `SettingsViewModel.librarySourceModeKey`: Kotlin enum entries do not import as an
    /// exhaustively-switchable Swift enum.
    private static func animeIdKey(_ preference: SimklAnimeIdPreference) -> String {
        if preference == .mal { return "mal" }
        if preference == .kitsu { return "kitsu" }
        if preference == .tvdb { return "tvdb" }
        return "imdb"
    }
}
