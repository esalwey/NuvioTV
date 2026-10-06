import Combine
import Foundation
import SharedCore

/// Orchestrates the Home/Catalog screen end-to-end on top of SharedCore.
///
/// Pipeline (all shared Kotlin):
///   1. `AddonRepository.initialize()` loads any persisted addons (NSUserDefaults-backed on tvOS).
///   2. If none are installed yet, seed the default Cinemeta catalog addon so the screen has content.
///   3. Whenever the installed-addon set changes, push the enabled addons (those with a loaded
///      manifest) into `HomeRepository.refresh(...)`.
///   4. `HomeRepository.uiState` emits the assembled catalog sections, which we republish for SwiftUI.
///
/// Both flows are observed through the hand-written `FlowWatcher` bridge (no SKIE / kmp-nativecoroutines).
/// One Home row: either an addon catalog section or a collection (folder tiles). Interleaved per
/// the user's Home Rows settings order (`HomeCatalogSettingsItem`, collections keyed
/// `collection_<id>`), mirroring mobile's Home composition.
enum HomeRow: Identifiable {
    case catalog(HomeCatalogSection)
    case collection(NuvioCollection)

    var id: String {
        switch self {
        case .catalog(let section): return section.key
        case .collection(let collection): return "collection_\(collection.id)"
        }
    }
}

/// Wave H (BUG-86): what `HomeViewModel.homeWatcher` does with ONE `HomeUiState` publish, decided
/// purely from the gate fields so the routing itself is unit-testable (`HeroCommitCoordinatorTests`)
/// without a live pipeline.
enum HeroPublishRoute: Equatable {
    /// The gate is still Armed: keep heroItems/sections/rows exactly as painted.
    case hold
    /// Released with no hero to paint — Show Hero is off, or this release genuinely has no
    /// candidate. Rows publish immediately; the commit coordinator is reset so a hero arriving
    /// later is treated as a new head.
    case noHero
    /// Released with a hero: hand the head to `HeroCommitCoordinator.evaluateHeadChange`.
    case evaluateHead

    /// The whole table. `heroOff` is only a LABEL on one of the two no-hero cases: the deciding
    /// question is whether a released publish carries a head at all.
    ///
    /// The distinction matters because `decideHeroGate` (`HeroCommitGate.kt`) checks `heroOff`,
    /// `reset` and `timeout` BEFORE the candidate-empty term, so a released publish with an empty
    /// hero is a perfectly reachable state on a profile whose hero-source catalogs yield nothing —
    /// a dead add-on in both hero slots, or `hideUnreleasedContent` emptying an upcoming-style
    /// catalog. Routing that to `hold` (an earlier revision did, for every reason except
    /// `heroOff`) froze Home on the empty state with `isLoading = false` for the rest of the
    /// session, because nothing downstream ever assigned `sections` again.
    ///
    /// BUG-86 hero-off rows (beta.18) — `rowsReleased`. A released publish is not automatically a
    /// publish whose ROWS are final. Two of Kotlin's five release reasons answer the hero question
    /// without consulting a single input (`heroOff`, `noSources`), so on a "Show Hero" OFF profile
    /// the gate releases on its very first evaluation and every publish the launch sync burst then
    /// drives is a released one. Adopting `sections` from those was the tester's build-117 photo:
    /// rows open at 1.7 s with a collection first, the burst reorders at 2.5 s with a catalog
    /// first, and the FEAT-15 focus panel — whose resting title is the first item of the first
    /// catalog row — repaints with a different title. `HomeUiState.rowsGateReleased` is false on
    /// exactly those publishes, and holding on it keeps the rows and the panel painting once.
    ///
    /// Defaulted to `true` so the flag reads as an addition to the table rather than a rewrite of
    /// it: every reason that commits a hero already carries rows the burst is folded into.
    static func decide(gateReleased: Bool, gateReason: String?, heroIsEmpty: Bool,
                       rowsReleased: Bool = true) -> HeroPublishRoute {
        guard gateReleased else { return .hold }
        guard rowsReleased else { return .hold }
        if gateReason == "heroOff" || heroIsEmpty { return .noHero }
        return .evaluateHead
    }
}

/// Codex branch review round 8: what `HomeViewModel.onAddonsChanged` does about a change in the
/// ready-addon set, decided purely from before/after signatures so the routing is unit-testable
/// without a live pipeline (`HeroCommitCoordinatorTests`).
///
/// tvOS used to key its "did the ready set change" guard on manifest URLs alone. A cloud-synced
/// rename (`ManagedAddon.displayTitle`, from a pulled `userSetName`) never moves a manifest URL, so
/// the guard swallowed the change entirely: `syncCatalogs` never ran (Home Rows settings kept the
/// stale `addonName`) and `HomeRepository.refresh` never ran (the row subtitle kept the stale
/// name) until an unrelated manifest change or relaunch. Compose does not have this bug because its
/// trigger signature already includes `displayTitle` (`HomeCatalogDefinitions.buildHomeCatalogRefreshSignature`).
///
/// `.metadataOnly` and `.refresh` both mean "call `syncCatalogs` and `refresh`" — they differ only
/// in the `force` flag passed to `HomeRepository.refresh`. A manifest-URL-set change needs
/// `force: true` (new content to fetch). A title-only change needs `force: false`, so the shared
/// `refresh()` can take its own `isMetadataOnlyDefinitionChange` branch and republish the existing
/// sections under the new name/caption instead of re-fetching, pruning or moving the pinned hero
/// (see `HomeCatalogDefinitions.kt`, `HomeRepository.kt:refresh`). `force: true` always skips that
/// branch on the Kotlin side, so routing every rename through it as before would have refetched.
enum AddonChangeRoute: Equatable {
    /// Neither the manifest-URL set nor any display title changed. Nothing to do.
    case none
    /// The manifest-URL set is unchanged; only a display title moved. Sync + non-forced refresh.
    case metadataOnly
    /// The manifest-URL set itself changed (an addon installed, removed, enabled or disabled).
    /// Sync + forced refresh, same as before this fix.
    case refresh

    /// - Parameters:
    ///   - previousManifestSignature: the manifest-URL-only signature stored from the last call.
    ///   - manifestSignature: the manifest-URL-only signature for the CURRENT ready set.
    ///   - previousTitleSignature: the combined (manifest URL + display title) signature stored
    ///     from the last call.
    ///   - titleSignature: the combined signature for the CURRENT ready set.
    static func decide(previousManifestSignature: String, manifestSignature: String,
                       previousTitleSignature: String, titleSignature: String) -> AddonChangeRoute {
        guard titleSignature != previousTitleSignature else { return .none }
        return manifestSignature == previousManifestSignature ? .metadataOnly : .refresh
    }
}

/// Codex branch review round 9: whether an add-on emission with NO ready add-on may open the rows
/// gate, i.e. whether "this profile has no catalog-bearing add-on" is a settled fact yet.
///
/// `HomeViewModel` attaches its `AddonRepository.uiState` watcher before it calls
/// `AddonRepository.initialize()`, so the FIRST thing every cold launch delivers is the
/// repository's initial state: no add-ons, no manifest fetch in flight, and no refresh signature
/// stored yet. The escape used to read that as terminal — the same shape a genuinely
/// add-on-less profile produces — and opened the rows gate before the hero had committed, after
/// which the collections and catalog-settings watchers painted and reordered rows underneath it.
/// That is exactly the launch double-build `RowsGate` exists to prevent.
///
/// The fix is a positive signal rather than an absence of one: `AddonsUiState.isInitialized`,
/// which the repository sets once it has loaded the profile's local add-on list (or a server pull
/// has applied one). It rides the state itself, so this decision is made from one consistent
/// snapshot instead of racing a side-channel flow.
enum AddonBootstrapRoute: Equatable {
    /// At least one enabled add-on has a loaded manifest: the normal refresh path owns this
    /// emission and the rows gate is not this watcher's business.
    case none
    /// Nothing ready, and "nothing ready" is not yet a fact — bootstrap has not settled, or a
    /// manifest is still being fetched, or the default add-on seed has not yet had its say, or a
    /// catalog-bearing refresh has already run (in which case the Kotlin gate's own
    /// `HERO_COMMIT_GATE_TIMEOUT_MS` is the backstop). Hold the rows.
    case holdRows
    /// Bootstrap settled with no enabled add-on that can ever produce a catalog, and no refresh
    /// has run: nothing will release the Kotlin hero gate, so open the rows here rather than hold
    /// a collections-only Home blank forever. The same conclusion `HeroGateReason.NO_SOURCES`
    /// reaches on the Kotlin side.
    case openRowsNoSources

    /// - Parameters:
    ///   - isInitialized: `AddonsUiState.isInitialized` — add-on bootstrap has run for this profile.
    ///   - readyIsEmpty: no enabled add-on has a loaded manifest.
    ///   - manifestsPending: an enabled add-on is still fetching its manifest.
    ///   - seedPending: the default add-on seed may still land an add-on on this profile: it has
    ///     not been attempted yet (a signed-in account waits for the first server pull), or it is
    ///     in flight. False once it has failed (Codex round 10), which on an empty list is the
    ///     only way that list ever becomes a fact.
    ///   - hasRefreshed: a catalog-bearing refresh has already run on this profile
    ///     (`lastManifestSignature` is non-empty).
    static func decide(isInitialized: Bool, readyIsEmpty: Bool,
                       manifestsPending: Bool, seedPending: Bool,
                       hasRefreshed: Bool) -> AddonBootstrapRoute {
        guard readyIsEmpty else { return .none }
        guard isInitialized, !manifestsPending, !seedPending, !hasRefreshed else { return .holdRows }
        return .openRowsNoSources
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var heroItems: [MetaPreview] = []
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var rows: [HomeRow] = []
    @Published private(set) var continueWatching: [WatchProgressEntry] = []
    /// Home "Upcoming" row: next airing episode per followed show (shared
    /// `UpcomingEpisodesRepository`). Empty while the row is disabled or nothing is airing.
    @Published private(set) var upcoming: [UpcomingEpisodeItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    /// Upstream 085e8dc6 (#1819): every enabled add-on's manifest failed to load and nothing is
    /// still fetching. Distinct from `errorMessage` (HomeRepository's catalog error), which can
    /// never fire here — HomeRepository is only refreshed once a manifest is ready — so without
    /// this Home sat on "Setting up your catalogs…" forever with no error and no retry.
    @Published private(set) var addonManifestError: String?
    /// BUG-86 hero-off rows (beta.18, first fixture run of test31 leg D): the FEAT-15 focus panel
    /// seeds from `rows` first, then Continue Watching, then a folder — and Continue Watching is NOT
    /// behind the rows gate, so on a hero-off profile the panel painted the CW title at 5.66 s while
    /// the rows were still held (`rowsWait=sync`) and repainted the first catalog row's title 850 ms
    /// later when they opened: the double paint by another door. `HomeView.heroPanelSeed` now
    /// returns nil until this reads true, so the panel's first paint is the rows' first paint.
    /// Mirrors `rowsGate.isOpen`; flips in `openRowsGateAndRebuild()` and on `reset()`.
    @Published private(set) var rowsGateOpen = false

    /// H-1A (beta.15): a per-instance id from the shared hero probe counter, stamped into every
    /// probe line this view model logs (`vm=<n>`). A profile-scoped sync pull flipping the theme
    /// can `.id(appTheme.themeName)`-remount `ContentView` minutes after cold launch, which spins
    /// up a SECOND `HomeViewModel` while the first is still tearing down — without this stamp the
    /// two instances' publish lines interleave in the probe log under one identity and read as one
    /// view model publishing twice. See `AppThemeModel`'s guarded theme assignment for the actual
    /// fix; this id is purely diagnostic.
    let vmId = HomeHeroProbe.newInstanceId()

    /// Stremio's default community catalog addon — gives the tvOS build real content out of the box.
    private let cinemetaManifestUrl = "https://v3-cinemeta.strem.io/manifest.json"

    private var addonWatcher: FlowWatcher?
    /// Addon-wipe guard (2026-08-28): watches `AddonRepository.serverPullSettled` so a gated seed
    /// (see `maybeSeedDefaultAddon()`) gets retried once the signed-in account's first pull lands.
    private var seedGateWatcher: FlowWatcher?
    private var homeWatcher: FlowWatcher?
    /// Codex beta.18 r2 (P2): the no-sources add-on bootstrap route used to open the rows gate on its
    /// own, bypassing the Kotlin rows hold. When Kotlin has not decided yet and the launch sync burst
    /// is still running, this watches `LaunchSyncSignal` for the settle instead (see
    /// `openRowsForNoSourcesBootstrap`). Cancelled with the other watchers.
    private var noSourcesSyncWatcher: FlowWatcher?
    /// Codex beta.18 r5 (P2): bumped whenever catalog loading takes over from the no-sources
    /// bootstrap (a sync pull enabling an add-on), so a wait installed for the add-on-less shape can
    /// never open the rows over Kotlin's own hold or the hero art prewarm. Both completions check it.
    private var noSourcesWaitGeneration = 0
    private var progressWatcher: FlowWatcher?
    private var progressSourceWatcher: FlowWatcher?
    /// CW-2: the Up Next cards merged into `continueWatching` (profile-scoped, reset in `stop()`).
    private let nextUp = ContinueWatchingNextUpModel()
    private var traktSettingsWatcher: FlowWatcher?
    /// Last Trakt continue-watching days cap the row was built with; `nil` until the settings
    /// watcher's replay lands. Profile-scoped — cleared with the watchers in `teardownPipeline()`.
    private var lastTraktContinueWatchingDaysCap: Int32?
    private var upcomingWatcher: FlowWatcher?
    private var collectionsWatcher: FlowWatcher?
    private var catalogSettingsWatcher: FlowWatcher?
    private var collections: [NuvioCollection] = []
    private var settingsItems: [HomeCatalogSettingsItem] = []
    private var didSeed = false
    /// Codex round 10 (P2): the default seed's `addAddon` failed and left the list empty (an
    /// offline fresh install, say). `addAddon` adds nothing on failure, so no add-on emission ever
    /// follows; this is the term that lets the empty, initialized list open the rows gate instead
    /// of holding a collections-only Home blank for the session. Profile-scoped like `didSeed`.
    private var seedFailed = false
    /// Bumped with every seed attempt and every profile reset so a stale completion cannot mark
    /// a newer profile's seed as failed.
    private var seedAttempt = 0
    /// Guards against redundant `refresh` calls — only re-refresh when the ready-addon set changes.
    /// Combined signature: manifest URL AND display title per ready addon (`AddonChangeRoute`
    /// Codex round 8). A rename alone moves this even though `lastManifestSignature` does not, so
    /// the guard no longer swallows a cloud-synced `displayTitle` change the way a manifest-URL-only
    /// signature did.
    private var lastRefreshSignature = ""
    /// Manifest-URL-only signature for the ready set, tracked separately from
    /// `lastRefreshSignature` so `onAddonsChanged` can tell a rename (same manifest set, force:
    /// false) apart from an actual add/remove/enable/disable (different manifest set, force: true)
    /// — see `AddonChangeRoute.decide`.
    private var lastManifestSignature = ""
    /// Wave H (BUG-86): the Swift half of the hero commit protocol — see `HomeHeroCommit.swift`.
    /// Owns the committed head identity/hash and prewarms its artwork before `homeWatcher` assigns
    /// `heroItems`/`sections`. Reset in `stop()` (profile-scoped, like the model itself).
    private let heroCommitCoordinator = HeroCommitCoordinator()
    /// The in-flight `prepare()` for the current candidate head, if any. Cancelled whenever a newer
    /// publish supersedes it before it lands — see `heroCommitGeneration`.
    private var pendingHeroCommitTask: Task<Void, Never>?
    /// Bumped every time a new head starts a `prepare()`, AND every time a route cancels the
    /// pending one without starting a replacement (`.noHero`, `stop()`); a completion whose
    /// generation no longer matches is stale and must not paint (same idiom as
    /// `pipelineGeneration`). Cancellation alone is not enough to invalidate a completion:
    /// `prepare()` returns normally after observing cancellation, so the continuation would run
    /// against an unchanged generation and repaint the captured hero over the empty state.
    private var heroCommitGeneration = 0
    /// Codex r1 (P2): the head `prepare()` is currently prewarming, if any. Post-gate publishes
    /// keep arriving (catalog batches, enrichment, settings sync) and, until `commit` runs, the
    /// coordinator has no committed key, so every one of them classifies as `.newHead` and would
    /// cancel and restart the 1.5 s art wait, deferring the first hero and rows indefinitely. A
    /// publish carrying THIS key+hash is instead absorbed into `latestPendingState`.
    private var pendingHeadKey: String?
    private var pendingHeadHash: String?
    /// The newest state seen for `pendingHeadKey` while its `prepare()` was in flight. The commit
    /// continuation publishes this rather than the state it captured, so absorbing a publish never
    /// costs the rows/hero list it carried.
    private var latestPendingState: HomeUiState?
    /// `first=` on the `commit` probe line — true for the session's first genuine hero commit only.
    private var didLogFirstHeroCommit = false
    /// Diagnostic companion to `lastNonEmptyHeroHead` (`hash=`/`hashChanged=` on the `publish` probe
    /// line) — NOT the coordinator's own `committedHash` (that tracks the last COMMITTED payload;
    /// this tracks the last PUBLISHED one, so the diagnostic fires on every publish, held or not).
    private var lastNonEmptyHeroHash: String?
    /// BUG-86 hero-off rows (beta.18): the last `heroRankingDebug` string logged by the hero-EMPTY
    /// probe branch, so a "Show Hero" OFF launch contributes one line per distinct gate state
    /// rather than one per publish. See that branch for the hero-off photo contract.
    private var lastHeroOffProbeDebug: String?
    /// `rows` probe line dedup key (deliverable 3): the ordered row id list last logged, so the
    /// line only fires when it actually changes.
    private var lastProbedRowIds: [String] = []
    /// Codex r2 (P1): the ROWS half of the commit gate (see `RowsGate` in `HomeHeroCommit.swift`).
    /// Closed until the first `.noHero`/commit publish, so the collections and catalog-settings
    /// watchers cannot repaint or reorder the rows out from under a hero that has not committed
    /// yet. Profile-scoped, reset in `stop()` alongside the coordinator.
    private var rowsGate = RowsGate()
    /// The held-rebuild count carried from `RowsGate.open()` to the FIRST `rows` probe line logged
    /// afterwards (`heldRebuilds=`). Cleared the moment that line is emitted, so the field appears
    /// exactly once per open.
    private var pendingHeldRebuildsProbe: Int?
    /// True exactly while the watcher pipeline below is live (0→1 acquired … 1→0 released).
    private var started = false
    /// H-1B-ii (beta.15): how many views currently hold this model. See `acquire()`.
    private var retainCount = 0
    /// H-1B-ii: releases still OWED by views that were unmounted out from under a hard `stop()`.
    /// A hard stop discards the whole retain count, but the views that contributed to it still run
    /// their `onDisappear → release()` afterwards; those releases are expected, not underflow, so
    /// they are absorbed here instead of tripping the DEBUG assertion.
    private var hardStopAbsorb = 0
    /// Codex wave-4 r3 (P1): `FlowWatcher.cancel()` is cooperative — a delivery already queued when
    /// the pipeline tears down can still run AFTER `stop()` cleared the profile-scoped state, and
    /// on a model that now outlives the profile that means the PREVIOUS profile's data repopulating
    /// Home (the collections callback would even `syncCollections` the old definitions under the
    /// new profile). Every watcher closure captures the generation current at registration and
    /// bails when it no longer matches; both teardown and each restart bump it, so late deliveries
    /// from an earlier pipeline are inert forever.
    private var pipelineGeneration = 0

    // MARK: - Lifecycle
    //
    // H-1B-ii (beta.15): this model is owned by `ContentView` — ABOVE the `.id(appTheme.themeName)`
    // rebuild boundary — not by `HomeView`. A profile-scoped sync pull that flips the theme minutes
    // after launch re-identifies the whole tree, and when `HomeView` owned the model via
    // `@StateObject` that meant: a brand-new `HomeViewModel`, a replayed StateFlow publish
    // (duplicate hero head), `lastRefreshSignature == ""` → a second forced full
    // `HomeRepository.refresh`, and two hero paint pipelines alive across the swap (the tester's
    // "doubled hero"). The data now outlives view identity, so the swap is invisible to the
    // pipeline — but only if the hand-off is REFCOUNTED:
    //
    //   SwiftUI inserts the incoming subtree BEFORE removing the outgoing one, so the new
    //   `HomeView.onAppear` runs BEFORE the old `HomeView.onDisappear`. A naive hoist that kept
    //   plain start()/stop() would therefore tear the watchers down immediately AFTER the new view
    //   had already started them, leaving Home permanently dead. With a refcount the sequence is
    //   1 → 2 → 1: no teardown, no restart, nothing republished.
    //
    // Normal steady state is 0 or 1: `HomeView.onDisappear` effectively only fires on shell
    // teardown (neither a Detail push nor a tab switch fires it — see `HomeHeroBackdrop`), so the
    // count only ever transiently reaches 2 during a theme `.id()` swap.

    /// Balanced retain. Runs the pipeline exactly once on 0→1; every later holder just bumps the
    /// count. Every `acquire()` MUST be paired with a `release()` (or subsumed by `stop()`).
    func acquire() {
        retainCount += 1
        if HomeHeroProbe.enabled {
            // H-1A's probe intent, adapted: the old unconditional entry log existed so a redundant
            // `start()` — the shape a duplicate-instance bug produced — still left a trace. Under
            // refcounting a second holder is legitimate, so retain traffic gets its OWN line and
            // `vm start`/`vm stop` keep meaning "the pipeline actually started/stopped".
            HomeHeroProbe.log(String(format: "vm acquire id=%d rc=%d sinceLaunch=%dms", vmId, retainCount, HomeHeroProbe.sinceLaunchMs))
        }
        guard retainCount == 1 else { return }
        startPipeline()
    }

    /// Balanced release. Tears the pipeline down only on 1→0. Underflow clamps at zero — and in
    /// DEBUG asserts, unless it is a release owed to a preceding hard `stop()` (see
    /// `hardStopAbsorb`); a release build must never crash on an unbalanced release.
    func release() {
        // Absorbed FIRST, before the count is touched: a hard `stop()` already discarded the
        // retains these releases balance, so they must not decrement anything — the arrival of
        // `onDisappear` is not ordered against a later re-entry. (Profile exit → hard stop →
        // re-enter a profile → the NEW HomeView's `acquire()` can land before the OLD view's
        // `onDisappear`; decrementing there would tear down the pipeline the new view just
        // started, leaving Home permanently empty.) Worst case this leaks a retain, which the
        // next hard stop clears — strictly preferable to a premature teardown.
        if hardStopAbsorb > 0 {
            hardStopAbsorb -= 1
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "vm release id=%d rc=%d (post-hard-stop, absorbed) sinceLaunch=%dms", vmId, retainCount, HomeHeroProbe.sinceLaunchMs))
            }
            return
        }
        guard retainCount > 0 else {
            // Genuine underflow: an unpaired release with no hard stop to explain it. Clamp (a
            // release build must never crash here) and shout in DEBUG.
            #if DEBUG
            assertionFailure("HomeViewModel.release() underflow — an unpaired release() (vm=\(vmId))")
            #endif
            retainCount = 0
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "vm release id=%d rc=0 (underflow clamped) sinceLaunch=%dms", vmId, HomeHeroProbe.sinceLaunchMs))
            }
            return
        }
        retainCount -= 1
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "vm release id=%d rc=%d sinceLaunch=%dms", vmId, retainCount, HomeHeroProbe.sinceLaunchMs))
        }
        guard retainCount == 0 else { return }
        teardownPipeline()
    }

    /// Hard teardown, regardless of who still holds the model. Used on profile switch / sign-out:
    /// everything below is PROFILE-SCOPED (the shared repositories are re-scoped by
    /// `ActiveProfileProvider`), and now that the model outlives `HomeView` the old implicit
    /// "the view went away, so the watchers went away" teardown no longer happens on its own.
    /// The outstanding retains are remembered in `hardStopAbsorb` so the unmounting views'
    /// `release()` calls don't read as underflow.
    func stop() {
        hardStopAbsorb += retainCount
        retainCount = 0
        teardownPipeline()
        // Codex wave-4 (P1): these two guards are PROFILE-SCOPED state on a model that now
        // outlives the profile. Without the reset, switching to a profile whose ready-addon URLs
        // happen to match the previous profile's would hit the `signature != lastRefreshSignature`
        // equality guard and skip the one forced Home refresh that repopulates the cleared
        // `HomeRepository` — leaving Home empty; `didSeed` would likewise block Cinemeta seeding
        // for a newly selected empty profile.
        lastRefreshSignature = ""
        lastManifestSignature = ""
        didSeed = false
        seedFailed = false
        seedAttempt += 1
        // Codex wave-4 r2 (P1): the published content and internal snapshots are profile-scoped
        // too. Left populated, the next profile's `HomeView` renders the PREVIOUS profile's hero,
        // rows, Continue Watching, and Upcoming until the freshly attached watchers replay —
        // profile data crossing the profile boundary. Same cascade rule as the account-data wipe
        // registry: in-memory account/profile-scoped state joins the teardown.
        heroItems = []
        sections = []
        rows = []
        continueWatching = []
        nextUp.reset()
        upcoming = []
        isLoading = false
        errorMessage = nil
        addonManifestError = nil
        collections = []
        settingsItems = []
        lastNonEmptyHeroHead = nil
        // Wave H: profile-scoped hero commit state joins the same wipe cascade.
        lastNonEmptyHeroHash = nil
        // BUG-86 hero-off rows (beta.18): so does the hero-off probe's dedup key — the next
        // profile's first gate state must log even when its debug string matches this one's.
        lastHeroOffProbeDebug = nil
        lastProbedRowIds = []
        pendingHeldRebuildsProbe = nil
        didLogFirstHeroCommit = false
        // Internal review r1 (P2): the pending-commit + rows-gate half of this cascade moved into
        // `resetHeroCommitState()`, which the `teardownPipeline()` above already ran. It is called
        // again here on purpose: `teardownPipeline()` no-ops when the pipeline was never started
        // (`guard started`), and a hard stop must never carry a previous profile's commit
        // bookkeeping into the next one. Idempotent - the generation bump is monotonic and every
        // other field is set to nil.
        resetHeroCommitState()
    }

    /// Internal review r1 (P2): the hero-commit half of a pipeline teardown, shared by
    /// `teardownPipeline()` (every 1 -> 0 `release()`) and the hard `stop()`.
    ///
    /// `release()` used to run `teardownPipeline()` alone, which only bumps `pipelineGeneration`.
    /// A `prepare()` still in flight then fails the `pipelineGeneration == gen` guard in its
    /// continuation and returns WITHOUT clearing `pendingHeroCommitTask` / `pendingHeadKey` /
    /// `pendingHeadHash` / `latestPendingState`. The next `acquire()`'s first released publish for
    /// that same head therefore looked like "this head is already preparing" to
    /// `HeroPendingCommitRoute.decide` (non-nil task, matching key AND hash), routed `.absorb`, and
    /// returned - forever, because nothing was actually in flight to commit and clear the
    /// bookkeeping. The rows gate was left exactly as the torn-down pipeline had it (open, if the
    /// old run had committed) rather than re-gating the new run's first paint. Resetting both here
    /// means a teardown always leaves the model in the shape a freshly constructed one starts in.
    private func resetHeroCommitState() {
        pendingHeroCommitTask?.cancel()
        pendingHeroCommitTask = nil
        pendingHeadKey = nil
        pendingHeadHash = nil
        latestPendingState = nil
        // Bumped, not merely nil'd, for the same reason the `.noHero` route bumps it: `prepare()`
        // returns NORMALLY after observing cancellation, so only a generation mismatch can stop a
        // continuation already queued behind the `cancel()` above.
        heroCommitGeneration += 1
        heroCommitCoordinator.reset()
        rowsGate.reset()
        rowsGateOpen = rowsGate.isOpen
        // Internal review r1 (P3): per pipeline RUN, not per process. Left true, a restarted
        // pipeline never marks the `first_hero` milestone again and the launch trace silently
        // loses the measurement for the run that is actually on screen.
        didTraceFirstHero = false
    }

    private func startPipeline() {
        guard !started else { return }
        started = true
        pipelineGeneration += 1
        let gen = pipelineGeneration
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "vm start id=%d sinceLaunch=%dms", vmId, HomeHeroProbe.sinceLaunchMs))
        }

        // Home output → SwiftUI. Wave H (BUG-86, the hero commit protocol): HomeRepository holds
        // heroItems/sections behind `heroGateReleased` until every input that could still move the
        // head has settled (see HeroCommitGate.kt), then commits once and freezes the payload. This
        // watcher mirrors that on the Swift side via `heroCommitCoordinator` — heroItems/sections
        // are assigned, and rows rebuilt, only in the cases the coordinator decides are safe, so
        // the hero and the rows under it always paint together, exactly once, per head.
        homeWatcher = FlowWatcherKt.watch(HomeRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let state = emitted as? HomeUiState else { return }
            self.isLoading = state.isLoading
            self.errorMessage = state.errorMessage

            // Codex r1 (P2): the carousel TAIL moved while the painted head survived. Kotlin
            // added or removed a non-head hero entry (an addon's hero-source catalog finishing,
            // `hideUnreleasedContent` pruning one) and republished the revised list with the
            // survivors' payloads frozen. The same-head branch below never assigned `heroItems`,
            // so the carousel and the page-dot count kept removed items and missed newcomers for
            // the rest of the session. Computed here so the `publish` line can carry it too.
            let heroTailChanged = HeroCommitCoordinator.heroTailChanged(
                painted: self.heroItems.map { HeroCommitCoordinator.headKey($0) },
                incoming: state.heroItems.map { HeroCommitCoordinator.headKey($0) }
            )

            // BUG-42 (beta.13): release-safe hero commit probe — one line per hero-bearing publish,
            // naming the head so a device log shows whether it ever moved after first paint.
            if HomeHeroProbe.enabled, state.heroItems.isEmpty, !self.heroItems.isEmpty {
                // An A → empty → B sequence must not hide the A→B change from the probe.
                HomeHeroProbe.log(String(format: "publish vm=%d n=0 (hero emptied) %@ sinceLaunch=%dms", self.vmId, state.heroRankingDebugSnapshot ?? HomeRepository.shared.heroRankingDebug, HomeHeroProbe.sinceLaunchMs))
            }
            if !state.heroItems.isEmpty {
                let headItem = state.heroItems.first
                let head = headItem.map { HeroCommitCoordinator.headKey($0) } ?? "-"
                let headHash = headItem.map { HeroCommitCoordinator.headHashHex($0) }
                let previousHead = self.lastNonEmptyHeroHead
                let headChanged = previousHead != nil && previousHead != head
                // Wave H (design-doc instrumentation gap 1/2): a SAME-head publish whose payload
                // hash moved is exactly the raw-then-enriched repaint this whole protocol exists to
                // prevent — the committed payload is frozen, so this should read 0 on any healthy
                // launch. `gate=` itself already rides `heroRankingDebug` below (read from the
                // state's publish-time snapshot so the line cannot describe a later repository state)
                // (idle|held|released:<reason>); this adds the fields that line lacked.
                let hashChanged = !headChanged && self.lastNonEmptyHeroHash != nil && self.lastNonEmptyHeroHash != headHash
                self.lastNonEmptyHeroHead = head
                self.lastNonEmptyHeroHash = headHash
                // `inRows` = the head is one of the published catalog items (catalog hero) vs not
                // (collection-fallback hero) — tells the two hero sources apart in a log pull.
                let inRows = state.sections.contains { section in
                    section.items.contains { $0.type == headItem?.type && $0.id == headItem?.id }
                }
                let ids = state.heroItems.map { "\($0.type):\($0.id)" }.joined(separator: ",")
                if HomeHeroProbe.enabled {
                    HomeHeroProbe.log(String(format: "publish vm=%d n=%d head=%@ headChanged=%d hash=%@ hashChanged=%d inRows=%d sections=%d loading=%d %@ sinceLaunch=%dms ids=%@ tail=%d",
                          self.vmId, state.heroItems.count, head, headChanged ? 1 : 0, String((headHash ?? "").suffix(8)), hashChanged ? 1 : 0, inRows ? 1 : 0, state.sections.count,
                          state.isLoading ? 1 : 0, state.heroRankingDebugSnapshot ?? HomeRepository.shared.heroRankingDebug, HomeHeroProbe.sinceLaunchMs, ids, heroTailChanged ? 1 : 0))
                }
            } else if HomeHeroProbe.enabled {
                // BUG-86 hero-off rows (beta.18): the branch above logs one line per HERO-BEARING
                // publish, so a "Show Hero" OFF profile produced no `publish` line at all and the
                // `gate=`/`rowsWait=` fields — the entire diagnosis for this launch shape — never
                // reached the About pane. The tester's build-117 photo is exactly that hole: rows,
                // present and paint lines, and nothing saying what the gate had decided.
                //
                // THE HERO-OFF PHOTO CONTRACT (what a good About-pane photo shows, in order):
                //   1. `publish vm=1 n=0 heroOff=1 … gate=released:heroOff rowsWait=settled
                //      rowsWaitMs=<≤4000>` — the hero answered immediately, the rows waited for
                //      the launch sync burst and got it. `rowsWait=timeout` is the same contract
                //      with a slow or absent burst: diagnosable, never silent.
                //   2. exactly ONE `rows … rowsGate=open` line, carrying `heldRebuilds=<n>`.
                //   3. one `present … same=0` followed by one `paint … first=1` — the focus panel
                //      painting its resting title once.
                // BAD, and the shape this wave fixes: a SECOND `rows` line whose `settingsSig=`
                // has changed, followed by a `present` line with a different `item=`. That is the
                // burst reordering the rows under a panel that had already painted.
                //
                // Deduped on the debug string rather than logged per publish: while the rows are
                // held every publish emits an equal `HomeUiState` (the StateFlow suppresses most
                // of them, but not the ones whose unrelated fields moved), and 57 lines is the
                // whole About pane.
                let debug = state.heroRankingDebugSnapshot ?? HomeRepository.shared.heroRankingDebug
                if debug != self.lastHeroOffProbeDebug {
                    self.lastHeroOffProbeDebug = debug
                    HomeHeroProbe.log(String(format: "publish vm=%d n=0 heroOff=%d %@ sinceLaunch=%dms",
                                             self.vmId, state.heroGateReason == "heroOff" ? 1 : 0,
                                             debug, HomeHeroProbe.sinceLaunchMs))
                }
            }

            // Wave H hold: while the gate is still Armed, hold heroItems/sections/rows exactly as
            // painted, so whatever is already on screen (or the "Loading catalogs…" placeholder)
            // stays put rather than flashing an intermediate, not-yet-final layout. The release is
            // the only thing that unblocks this watcher — see `HeroPublishRoute.decide` for why an
            // empty hero on a RELEASED publish must never route back into the hold.
            switch HeroPublishRoute.decide(gateReleased: state.heroGateReleased,
                                           gateReason: state.heroGateReason,
                                           heroIsEmpty: state.heroItems.isEmpty,
                                           rowsReleased: state.rowsGateReleased) {
            case .hold:
                return

            case .noHero:
                // No hero to commit: either it is structurally off for this profile, or this
                // release genuinely has no candidate. Either way there is no art to wait on, so
                // the rows publish immediately with no coordinator involvement. The coordinator is
                // reset so that if a hero DOES arrive later (a re-enabled add-on, a Hero Sources
                // change) it is evaluated as a new head and goes through the normal prepare +
                // commit path rather than being mistaken for the already-committed one.
                //
                // Codex r1 (P1): the generation bump is what actually INVALIDATES the cancelled
                // prepare. `prepare()` observes cancellation and returns normally, so without the
                // bump its continuation still sees a matching generation and repaints the captured
                // hero straight back over the empty state this route just published. That is the
                // exact shape of disabling Show Hero, or losing the hero's source, mid-prewarm.
                self.heroCommitGeneration += 1
                self.pendingHeroCommitTask?.cancel()
                self.pendingHeroCommitTask = nil
                self.pendingHeadKey = nil
                self.pendingHeadHash = nil
                self.latestPendingState = nil
                self.heroCommitCoordinator.reset()
                self.heroItems = state.heroItems
                self.sections = state.sections
                // Codex r2 (P1): this publish IS the commit for a heroless profile, so it is also
                // what opens the rows gate. Both `.noHero` shapes open it: hero structurally off
                // (`heroGateReason == "heroOff"`, which opened the rows on its first publish
                // before this gate existed and must keep doing so), and a release that simply has
                // no candidate.
                self.openRowsGateAndRebuild()
                return

            case .evaluateHead:
                break
            }

            guard let head = state.heroItems.first else { return }
            let headKey = HeroCommitCoordinator.headKey(head)
            let headHash = HeroCommitCoordinator.headHashHex(head)

            switch self.heroCommitCoordinator.evaluateHeadChange(headKey: headKey, headHash: headHash) {
            case .sameHeadSameHash, .sameHeadHashChanged:
                // Same head (the hash diagnostic, including `hashChanged=1`, already logged above):
                // never re-assign heroItems wholesale — the anti-repaint invariant — but rows may
                // still change under it post-commit.
                //
                // Codex r1 (P2): the carousel TAIL is exempt. A publish that adds or removes a
                // non-head hero entry left the painted list frozen forever, so the pages and the
                // dot count drifted from what the repository actually holds. The committed head
                // OBJECT is carried across verbatim rather than taken from `state`: on a
                // `.sameHeadHashChanged` publish the incoming head carries a drifted payload, and
                // adopting it here would be precisely the repaint this protocol forbids. Keeping
                // it also means `HomeView.displayHero` and `heroPayloadSignature` are unmoved at
                // index 0, so `HeroArtResolver.present` is never re-entered for the head. Seen
                // live on the fixture: test31 Leg B logs one `publish ... tail=1` at 9.9 s, same
                // head and same hash, whose revised list the old branch dropped on the floor.
                if heroTailChanged {
                    self.heroItems = [self.heroItems[0]] + state.heroItems.dropFirst()
                }
                self.sections = state.sections
                self.requestRowsRebuild()

            case .newHead:
                // Codex r1 (P2): until `commit` runs the coordinator has no committed key, so
                // EVERY released publish still classifies as `.newHead`, including the post-gate
                // churn (catalog batches, enrichment landing, a settings sync) that arrives while
                // the head's own art is prewarming. Restarting `prepare()` for each of those reset
                // the 1.5 s art budget and could defer the first hero and rows indefinitely. A
                // publish for the head already in flight is absorbed instead: the running prepare
                // keeps its clock, and its continuation commits the LATEST state rather than the
                // one it captured, so nothing that arrived in the meantime is lost.
                if HeroPendingCommitRoute.decide(pendingHeadKey: self.pendingHeadKey,
                                                 pendingHeadHash: self.pendingHeadHash,
                                                 hasPendingTask: self.pendingHeroCommitTask != nil,
                                                 headKey: headKey, headHash: headHash) == .absorb {
                    self.latestPendingState = state
                    return
                }

                // A genuinely new head (including the session's first-ever commit). Prewarm its
                // art, then commit heroItems + sections + rebuild rows in one main-actor turn.
                self.heroCommitGeneration += 1
                let commitGen = self.heroCommitGeneration
                self.pendingHeroCommitTask?.cancel()
                let capturedState = state
                let firstCommit = !self.didLogFirstHeroCommit
                self.pendingHeadKey = headKey
                self.pendingHeadHash = headHash
                self.latestPendingState = nil
                self.pendingHeroCommitTask = Task { [weak self] in
                    guard let self else { return }
                    let outcome = await self.heroCommitCoordinator.prepare(capturedState)
                    // Superseded by a newer head, cancelled outright (`.noHero`, `stop()`), or the
                    // pipeline tore down while prepare() was in flight: never paint stale content
                    // on top of whatever landed since. `prepare()` returns NORMALLY after observing
                    // cancellation, so the cancellation check has to be made here as well as by
                    // generation.
                    guard !Task.isCancelled,
                          self.pipelineGeneration == gen,
                          self.heroCommitGeneration == commitGen else { return }
                    // Whatever the newest publish for this same head carried, if one was absorbed.
                    let commitState = self.latestPendingState ?? capturedState
                    self.heroCommitCoordinator.commit(headKey: headKey, headHash: headHash)
                    self.didLogFirstHeroCommit = true
                    self.heroItems = commitState.heroItems
                    self.sections = commitState.sections
                    // The single gated rebuild: hero, sections and rows land in one main-actor
                    // turn, from the LATEST state, with whatever the watchers held folded in.
                    self.openRowsGateAndRebuild()
                    self.pendingHeroCommitTask = nil
                    self.pendingHeadKey = nil
                    self.pendingHeadHash = nil
                    self.latestPendingState = nil
                    if HomeHeroProbe.enabled {
                        HomeHeroProbe.log(String(format: "commit vm=%d head=%@ art=%@ waited=%dms first=%d sinceLaunch=%dms",
                              self.vmId, headKey, outcome.status, outcome.waitedMs, firstCommit ? 1 : 0, HomeHeroProbe.sinceLaunchMs))
                    }
                    // BUG-42 moved the hero's metadata commit BEHIND TMDB enrichment, so hero first
                    // paint is not implied by `first_rows` and needs its own milestone to stay
                    // measurable against the BUG-26 baseline. Codex r1 (P2): it is marked HERE, at
                    // the commit, rather than on the first non-empty publish. The old placement
                    // ran before the art prewarm and before `heroItems` was ever assigned, so it
                    // under-reported the latency by up to the full 1.5 s budget and could fire for
                    // a candidate that a `.noHero` release then made sure never painted at all.
                    // beta.13: also emitted on release builds behind `debug.homeHeroProbe`, so the
                    // check this row prescribed three times can run on the reporter's build class.
                    if !self.didTraceFirstHero {
                        self.didTraceFirstHero = true
                        #if DEBUG
                        LaunchTrace.mark("first_hero n=\(commitState.heroItems.count)")
                        #else
                        if HomeHeroProbe.enabled { HomeHeroProbe.log(String(format: "first_hero n=%d sinceLaunch=%dms", commitState.heroItems.count, HomeHeroProbe.sinceLaunchMs)) }
                        #endif
                    }
                }
            }
        }

        // Collections (synced from the cloud / curated on mobile) → folder-tile rows. Registering
        // them with HomeCatalogSettingsRepository (like mobile's HomeScreen does) lets the Home Rows
        // settings order/enable them alongside addon catalogs.
        collectionsWatcher = FlowWatcherKt.watch(CollectionRepository.shared.collections) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let collections = emitted as? [NuvioCollection] else { return }
            self.collections = collections.filter { !$0.folders.isEmpty }
            HomeCatalogSettingsRepository.shared.syncCollections(collections: collections)
            self.requestRowsRebuild()
        }
        catalogSettingsWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.settingsItems = state.items
            self.requestRowsRebuild()
        }

        // Installed addons → drive Home refresh.
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let state = emitted as? AddonsUiState else { return }
            self.onAddonsChanged(state)
        }

        // Addon-wipe guard (2026-08-28): covers the signed-in fresh-account case. The addon list's
        // own empty-state emission is gated by `maybeSeedDefaultAddon()` while the first server pull
        // hasn't settled yet, so nothing re-evaluates the seed once that emission has already come
        // and gone — this watcher is what retries it: when the pull settles and the current addon
        // state is STILL empty (a genuinely empty account, not one whose addons just arrived), seed.
        seedGateWatcher = FlowWatcherKt.watch(AddonRepository.shared.serverPullSettled) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen else { return }
            let settled = (emitted as? KotlinBoolean)?.boolValue == true
            guard settled else { return }
            guard let state = AddonRepository.shared.uiState.value_ as? AddonsUiState, state.addons.isEmpty else { return }
            let seedWasSettled = self.seedFailed
            self.maybeSeedDefaultAddon()
            // ADD-1: a declined seed (see maybeSeedDefaultAddon) triggers no add-on emission of its
            // own, so re-run the bootstrap decision here, as the failed-seed completion does.
            if !seedWasSettled, self.seedFailed { self.onAddonsChanged(state) }
        }

        // Watch progress → Continue Watching row.
        progressWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] _ in
            guard let self, self.pipelineGeneration == gen else { return }
            self.refreshContinueWatching()
        }

        // BUG-75: the row's two gates (the active provider's dropped-show filter and its recency
        // window) live OUTSIDE `uiState` — switching progress source or changing the Trakt
        // continue-watching days cap changes what the row should contain without touching a single
        // progress entry. Without these two watchers the row keeps the previous gates until the
        // next unrelated progress emission.
        progressSourceWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.activeSourceState) { [weak self] _ in
            guard let self, self.pipelineGeneration == gen else { return }
            self.refreshContinueWatching()
        }
        // `TraktSettingsUiState` also carries library/more-like-this preferences the row does not
        // read, so recompute only when the days cap actually moved — a republished row otherwise
        // re-renders (and can disturb focus) for a setting it does not depend on.
        traktSettingsWatcher = FlowWatcherKt.watch(TraktSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen,
                  let state = emitted as? TraktSettingsUiState else { return }
            guard self.lastTraktContinueWatchingDaysCap != state.continueWatchingDaysCap else { return }
            self.lastTraktContinueWatchingDaysCap = state.continueWatchingDaysCap
            self.refreshContinueWatching()
        }
        // CW-2: Up Next cards join the row — their own inputs (watched items, Continue Watching
        // preferences) and every card that resolves rebuild it too.
        nextUp.onChange = { [weak self] in
            guard let self, self.pipelineGeneration == gen else { return }
            self.refreshContinueWatching()
        }
        nextUp.start()

        // BUG-86 hero-off rows (beta.18): applied BEFORE `AddonRepository.initialize()`, not
        // alongside the burst sim below, because initialize()'s first add-on emission can drive
        // `onAddonsChanged` → `HomeRepository.refresh` synchronously, and refresh is what arms the
        // hero gate and takes its first `snapshot().heroEnabled`. Setting it afterwards would leave
        // the launch this knob exists to reproduce reading as hero-ON. Inert unless both launch
        // args are set — see `HomeHeroOffArgs`.
        if HomeHeroOffArgs.enabled {
            HomeCatalogSettingsRepository.shared.debugForceHeroOff = true
        }
        AddonRepository.shared.initialize()
        // Wave H (BUG-86): deterministic, offline replay of the launch sync burst — see
        // `HomeLaunchBurstSimArgs`/`HomeLaunchBurstSim.kt`. Inert unless both launch args are set.
        if HomeLaunchBurstSimArgs.enabled {
            HomeLaunchBurstSim.shared.arm(burstAfterFirstPublishMs: 1000, failFirstHeroSources: true, enrichmentDelayMs: 2500)
        }
        WatchProgressRepository.shared.ensureLoaded()
        CollectionRepository.shared.initialize()
        #if DEBUG
        applyCollectionsSeedIfRequested()
        #endif
    }

    #if DEBUG
    /// Sim-only knob for headless UI tests of the TMDB filter editor (`TmdbFilterEditorView`):
    /// launch with `-debug.collectionsSeedJsonB64 '<base64 of json>'` (an exported-collections
    /// JSON array, same shape as `CollectionRepository.exportToJson()`; base64 because the
    /// launch-argument domain of NSUserDefaults parses bracket/brace-led values as old-style
    /// plists and drops raw JSON) — `-debug.collectionsSeedJson` with raw JSON is accepted too
    /// for hand use. The payload is imported ONCE per launch, right after
    /// `CollectionRepository.initialize()`, so a folder with a tmdb DISCOVER source exists without
    /// a signed-in account. In a signed-in session the next foreground pull may overwrite it
    /// (remote wins) — use in guest mode. Invalid JSON is rejected by the shared `validateJson`
    /// (logged, nothing imported).
    private static var didApplyCollectionsSeed = false
    private func applyCollectionsSeedIfRequested() {
        guard !Self.didApplyCollectionsSeed else { return }
        let defaults = UserDefaults.standard
        var seed = defaults.string(forKey: "debug.collectionsSeedJson") ?? ""
        if seed.isEmpty, let b64 = defaults.string(forKey: "debug.collectionsSeedJsonB64"), !b64.isEmpty {
            seed = Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if seed.isEmpty { NSLog("[CollectionsSeed] imported=false error=base64 payload did not decode") }
        }
        guard !seed.isEmpty else { return }
        let json = seed
        Self.didApplyCollectionsSeed = true
        let validation = CollectionRepository.shared.validateJson(jsonString: json)
        guard validation.valid else {
            NSLog("[CollectionsSeed] imported=false error=%@", validation.error ?? "invalid JSON")
            return
        }
        // Kotlin `Result<List<Collection>>` crosses the bridge as the unboxed value: the array on
        // success, an opaque failure object otherwise (never throws — runCatching inside).
        let result = CollectionRepository.shared.importFromJson(jsonString: json)
        if let imported = result as? [NuvioCollection] {
            NSLog("[CollectionsSeed] imported=true collections=%d folders=%d", imported.count, imported.reduce(0) { $0 + $1.folders.count })
        } else {
            NSLog("[CollectionsSeed] imported=false result=%@", String(describing: result))
        }
    }
    #endif

    /// Rebuilds the Continue Watching row from the shared provider-aware builder. Called by every
    /// watcher that can change what the row contains: the progress entries themselves, the active
    /// progress source, the Trakt continue-watching days cap — and the Up Next cards (CW-2).
    private func refreshContinueWatching() {
        let row = nextUp.row(inProgress: inProgressContinueWatching())
        // A rebuild that changes nothing (a watched or preference emission elsewhere, a card that
        // resolved to what the row already shows) republishes nothing.
        if row != continueWatching { continueWatching = row }
    }

    private func inProgressContinueWatching() -> [WatchProgressEntry] {
        WatchProgressRepository.shared.continueWatchingRow(
            limit: ContinueWatchingRowKt.ContinueWatchingRowScanLimit
        )
    }

    /// "Remove from Continue Watching". CW-3: the whole title leaves the row (mobile
    /// `removeProgress(contentId)`), not the one episode an older in-progress episode of the same
    /// show would replace at once — and the Up Next card its episode marks would put back is
    /// dismissed with it. An Up Next card itself is dismissed until another episode is finished.
    ///
    /// CW alias fix (REMAINING_FIX #2): the row shows a series stored under several ids (`tmdb:…`
    /// and `tt…`) as one card, so the removal takes every one of them — otherwise the other id's
    /// card would take the removed one's place. The shared side removes all their rows at once,
    /// locally and, with Nuvio Sync, on the account (`removeContinueWatchingProgress`).
    func removeFromContinueWatching(_ entry: WatchProgressEntry) {
        if ContinueWatchingNextUpModel.isNextUp(entry) {
            nextUp.dismiss(entry, inProgress: inProgressContinueWatching())
            return
        }
        let contentIds = WatchProgressRepository.shared.continueWatchingCardContentIds(card: entry)
        // The replacement Up Next cards, as the seeds stand before the removal (a provider's
        // completed history) and after it (explicit episode marks) — under every id of the series,
        // see `replacementDismissKeys`.
        var replacements = nextUp.replacementDismissKeys(for: entry, inProgress: inProgressContinueWatching())
        WatchProgressRepository.shared.removeContinueWatchingProgress(contentIds: contentIds)
        replacements.formUnion(nextUp.replacementDismissKeys(for: entry, inProgress: inProgressContinueWatching()))
        nextUp.dismiss(keys: replacements)
    }

    /// The real teardown. Idempotent (`started` gates it) so a hard `stop()` on an already-stopped
    /// model is a no-op and, crucially, does NOT emit a spurious `vm stop` probe line — those two
    /// lines keep meaning "the pipeline actually started/stopped", never "someone asked".
    private func teardownPipeline() {
        guard started else { return }
        // Codex wave-4 r3: bump BEFORE cancelling — `cancel()` is cooperative, and any delivery
        // already queued behind it must find the generation stale and bail (see
        // `pipelineGeneration`'s doc).
        pipelineGeneration += 1
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "vm stop id=%d sinceLaunch=%dms", vmId, HomeHeroProbe.sinceLaunchMs))
        }
        addonWatcher?.cancel()
        seedGateWatcher?.cancel()
        homeWatcher?.cancel()
        noSourcesSyncWatcher?.cancel()
        progressWatcher?.cancel()
        progressSourceWatcher?.cancel()
        nextUp.stop()
        traktSettingsWatcher?.cancel()
        collectionsWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        addonWatcher = nil
        seedGateWatcher = nil
        homeWatcher = nil
        noSourcesSyncWatcher = nil
        progressWatcher = nil
        progressSourceWatcher = nil
        traktSettingsWatcher = nil
        lastTraktContinueWatchingDaysCap = nil
        collectionsWatcher = nil
        catalogSettingsWatcher = nil
        stopUpcoming()
        // Internal review r1 (P2): the hero-commit protocol is pipeline-scoped, not merely
        // profile-scoped - see `resetHeroCommitState()` for the `.absorb`-forever route a teardown
        // used to leave behind.
        resetHeroCommitState()
        started = false
    }

    /// Upcoming row (gated by the `home_upcoming_row_enabled` toggle, so it is started separately
    /// from the main pipeline — `HomeView.onAppear` calls it right after `acquire()` when the
    /// toggle is on, and it is NOT refcounted: it is idempotent both ways, and the pipeline
    /// teardown below stops it wholesale). Re-entering Home also nudges a cheap refresh so a calendar
    /// rollover while the app sat in the background re-labels TODAY / TOMORROW.
    func startUpcoming() {
        if upcomingWatcher == nil {
            // Same generation guard as the main pipeline's watchers (Codex wave-4 r3): a delivery
            // queued at teardown time must not repopulate `upcoming` after the profile-scoped clear.
            let gen = pipelineGeneration
            upcomingWatcher = FlowWatcherKt.watch(UpcomingEpisodesRepository.shared.uiState) { [weak self] emitted in
                guard let self, self.pipelineGeneration == gen, let state = emitted as? UpcomingEpisodesUiState else { return }
                self.upcoming = state.items
            }
            UpcomingEpisodesRepository.shared.ensureStarted()
        } else {
            UpcomingEpisodesRepository.shared.refresh(force: false)
        }
    }

    /// Tears the sweep down too (not just the Swift watcher) — off means no library/progress
    /// observation and no metadata fetches, which is what the Settings row promises.
    func stopUpcoming() {
        upcomingWatcher?.cancel()
        upcomingWatcher = nil
        UpcomingEpisodesRepository.shared.stop()
        upcoming = []
    }

    /// Codex r2 (P1): the ONLY way any watcher asks for a row rebuild.
    ///
    /// While the rows gate is closed (before the hero commits) the request is dropped and counted,
    /// not queued: `rebuildRows()` always reads the CURRENT `sections`/`collections`/`settingsItems`
    /// snapshots, which the watchers keep updating regardless, so the single rebuild performed by
    /// `openRowsGateAndRebuild()` already carries everything the held requests would have.
    private func requestRowsRebuild() {
        guard rowsGate.request() == .rebuild else { return }
        rebuildRows()
    }

    /// Opens the rows gate and performs the one commit-time rebuild. Called from the two routes
    /// that publish a commit: `.noHero` (including `heroGateReason == "heroOff"`, which opened the
    /// rows on its first publish before this gate existed) and the commit continuation.
    /// Codex beta.18 r2 (P2): `AddonBootstrapRoute.openRowsNoSources` (a settled add-on bootstrap
    /// with nothing ready — offline fresh install, failed seed, add-on-less profile) opened the Swift
    /// rows gate directly, so on a signed-in profile whose launch sync burst was still running the
    /// collections/settings watchers could rebuild and seed the focus panel before the pull landed:
    /// the reorder-then-repaint the Kotlin rows hold (`HeroGateDecision.rowsReleased`) exists to
    /// prevent, by another door. Three cases, no second decision table:
    ///   1. Kotlin has decided (`heroGateReleased`): honour its rows decision — open now if the rows
    ///      are released, otherwise the released publish routes `.noHero` and opens them.
    ///   2. Kotlin has not decided and the launch sync is RUNNING: wait for the settle on
    ///      `LaunchSyncSignal`, bounded by the same 4 s budget the Kotlin hold uses, then open.
    ///   3. Otherwise (settled, not applicable, signed out): open now, exactly as before.
    private func openRowsForNoSourcesBootstrap() {
        let latest = HomeRepository.shared.currentUiState
        if latest.heroGateReleased {
            if latest.rowsGateReleased { openRowsGateAndRebuild() }
            return
        }
        // Codex beta.18 r4 (P1): a wait already installed stays installed — add-on bootstrap,
        // server pulls and retries all re-enter this method before the burst settles, and the old
        // `watcher == nil` guard turned every re-entry into an immediate open.
        if noSourcesSyncWatcher != nil { return }
        if rowsGateOpen { return }
        let gen = pipelineGeneration
        let waitGen = noSourcesWaitGeneration
        // Codex beta.18 r4 (P1): `Idle` with a launch sync still expected is NOT settled (the burst
        // has not started yet) — the same term `decideHeroGate` uses, read through Kotlin.
        guard !HomeRepository.shared.launchSyncSettled else {
            openRowsGateAndRebuild()
            return
        }
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "rowsWait bootstrap=noSources sync=unsettled sinceLaunch=%dms", HomeHeroProbe.sinceLaunchMs))
        }
        noSourcesSyncWatcher = FlowWatcherKt.watch(LaunchSyncSignal.shared.state) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, self.noSourcesWaitGeneration == waitGen,
                  !self.rowsGateOpen else { return }
            _ = emitted
            // Read the state back through the Kotlin accessor rather than casting the emitted
            // value: the nested enum's Swift name is an interop detail nothing else here relies on.
            guard HomeRepository.shared.launchSyncSettled else { return }
            self.noSourcesSyncWatcher?.cancel()
            self.noSourcesSyncWatcher = nil
            self.openRowsGateAndRebuild()
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.pipelineGeneration == gen, self.noSourcesWaitGeneration == waitGen,
                  !self.rowsGateOpen else { return }
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "rowsWait bootstrap=noSources timeout sinceLaunch=%dms", HomeHeroProbe.sinceLaunchMs))
            }
            self.noSourcesSyncWatcher?.cancel()
            self.noSourcesSyncWatcher = nil
            self.openRowsGateAndRebuild()
        }
    }

    private func openRowsGateAndRebuild() {
        if let held = rowsGate.open() {
            pendingHeldRebuildsProbe = held
        }
        rowsGateOpen = true
        rebuildRows()
    }

    /// Interleaves catalog sections and collection rows per the Home Rows settings order (enabled
    /// items only), mirroring mobile's Home composition. Anything the settings don't know about yet
    /// (fresh install, settings sync lag) is appended in its natural order so nothing disappears.
    private func rebuildRows() {
        var built: [HomeRow] = []
        var usedSectionKeys = Set<String>()
        var usedCollectionIds = Set<String>()
        // First-wins dedup instead of `uniqueKeysWithValues`, which TRAPS on duplicates — the
        // shared module tolerates duplicate ids/keys in the wild (see
        // `visibleCollectionsWithUniqueIds` in HomeCatalogSettingsRepository.kt), so tvOS must too.
        let sectionsByKey = Dictionary(sections.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let collectionsById = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for item in settingsItems {
            if item.isCollection {
                guard let id = item.collectionId else { continue }
                usedCollectionIds.insert(id)
                guard item.enabled, let collection = collectionsById[id] else { continue }
                built.append(.collection(collection))
            } else {
                usedSectionKeys.insert(item.key)
                guard item.enabled, let section = sectionsByKey[item.key] else { continue }
                built.append(.catalog(section))
            }
        }

        // Anything settings don't know about yet keeps rendering (disabled items were marked
        // "used" above, so they stay hidden).
        for section in sections where !usedSectionKeys.contains(section.key) {
            built.append(.catalog(section))
        }
        for collection in collections where !usedCollectionIds.contains(collection.id) {
            built.append(.collection(collection))
        }

        rows = built

        // Wave H (BUG-86 diagnostics, deliverable 3): the ordered row IDENTITY list, not merely a
        // count — a reorder with the same count (the launch sync burst's signature move) is exactly
        // what a healthy commit must never do after the hero's first paint, and a plain `n=`
        // wouldn't show it. Release-safe, like every other Wave H probe line.
        if HomeHeroProbe.enabled {
            let rowIds = built.map(\.id)
            if rowIds != lastProbedRowIds {
                lastProbedRowIds = rowIds
                let first3 = rowIds.prefix(3).joined(separator: ",")
                // Internal review r1 (P3): `first=` shows only three ids, so the reorder oracle in
                // test31 could not see a swap that happened at position 4 or later - the launch
                // sync burst rewrites EVERY `order`, so the shared-id order check has to run over
                // the whole list. Two append-only tokens, `first=` deliberately unchanged so the
                // device photo pass and every older log keep parsing:
                //   `order=` - the ordered list the oracle actually compares, as one 8-hex DIGEST
                //     per row id rather than the ids themselves. The oracle only ever compares the
                //     relative position of ids present in two lines, so a stable per-id token is
                //     all it needs, and the real ids are 60-90 characters each here (addon
                //     namespace + type + catalog id): spelling out 35 of them put ~2.4 KB on one
                //     line, which is fine in the console but swamps the 57-line About pane this
                //     probe exists to be PHOTOGRAPHED from. Digests keep the whole list inside a
                //     publish line's own order of magnitude. `first=` still carries three real ids
                //     for the human reading the pane. Capped at `rowsOrderProbeMaxIds` on a whole-
                //     token boundary, with `+N` naming what was cut.
                //   `rowsHash=` - FNV-1a over the FULL joined list (`HeroCommitCoordinator`'s own
                //     hash, already covered by known-vector tests), so a change PAST the cap is
                //     still visible on the line even though `order=` cannot show it.
                //   `settingsSig=` - see `settingsOrderSignature`. Says WHY a reorder happened,
                //     which is what separates a legitimate post-commit reorder (a Home Rows order
                //     the user changed on another device, landing from a cloud pull) from rows
                //     reshuffling under a settings order that never moved.
                let digests = rowIds.map { String(HeroCommitCoordinator.fnv1a64Hex($0).prefix(8)) }
                var order = digests.prefix(Self.rowsOrderProbeMaxIds).joined(separator: ",")
                if digests.count > Self.rowsOrderProbeMaxIds {
                    order += "+\(digests.count - Self.rowsOrderProbeMaxIds)"
                }
                let rowsHash = HeroCommitCoordinator.fnv1a64Hex(rowIds.joined(separator: "|"))
                // Codex r2, append-only: `rowsGate=` must read `open` on every line a healthy
                // launch produces (the funnel above is the only caller, and it only rebuilds when
                // the gate is open), so a `held` here is a standing assertion that some caller
                // bypassed `requestRowsRebuild()`. `heldRebuilds=` rides the first line after the
                // gate opens and says how many watcher rebuilds the hold absorbed.
                var line = String(format: "rows vm=%d n=%d first=%@ sinceLaunch=%dms rowsGate=%@",
                                  vmId, built.count, first3, HomeHeroProbe.sinceLaunchMs,
                                  rowsGate.isOpen ? "open" : "held")
                line += " order=\(order) rowsHash=\(rowsHash) settingsSig=\(settingsOrderSignature())"
                if let held = pendingHeldRebuildsProbe {
                    pendingHeldRebuildsProbe = nil
                    line += String(format: " heldRebuilds=%d", held)
                }
                HomeHeroProbe.log(line)
            }
        }

        #if DEBUG
        // BUG-26: time-to-content milestones. First non-empty rows = the KMP fetch layer has
        // delivered; subsequent count growth shows the fan-out filling in.
        if !built.isEmpty {
            if !didTraceFirstRows {
                didTraceFirstRows = true
                LaunchTrace.mark("first_rows n=\(built.count) hero=\(heroItems.count)")
            } else if built.count != lastTracedRowCount {
                LaunchTrace.mark("rows n=\(built.count)")
            }
            lastTracedRowCount = built.count
        }
        #endif
    }

    /// An 8-hex digest of the Home Rows settings ORDER — the ordered identities of `settingsItems`,
    /// which is the list `rebuildRows()` walks and therefore the only thing that can make two row
    /// lists with the same members come out in a different sequence.
    ///
    /// It rides the `rows` probe line so the reorder oracle in `test31HeroCommitsOnce` can tell the
    /// two post-commit reorders apart. A cloud pull landing the user's real Home Rows order a
    /// second after first paint moves this digest, and reordering the rows to match it is the app
    /// doing its job (`RowsGate`'s own contract: the gate makes the FIRST paint atomic, it does not
    /// freeze rows for the session). Rows that reshuffle while this digest is unmoved are the
    /// BUG-86 symptom instead — an unstable rebuild, not a settings change — and stay a failure.
    ///
    /// Identity, not display state: `enabled` is deliberately out, because disabling a row removes
    /// it rather than moving it, and folding that in would make an unrelated toggle look like an
    /// order change to the oracle.
    private func settingsOrderSignature() -> String {
        let identities = settingsItems.map { item -> String in
            item.isCollection ? "c:\(item.collectionId ?? "")" : "s:\(item.key)"
        }
        return String(HeroCommitCoordinator.fnv1a64Hex(identities.joined(separator: "|")).prefix(8))
    }

    /// BUG-42 (beta.13): outside `#if DEBUG` — the first-hero milestone is also emitted on release
    /// builds behind `debug.homeHeroProbe`.
    /// Internal review r1 (P3): how many row-id digests the `rows` probe line's `order=` token
    /// carries. Bounded so one line stays photographable and survives the About pane's AX read;
    /// `rowsHash=` on the same line covers whatever the cap elides. 40 clears every row count this
    /// fixture profile produces (35 at its fullest) at ~360 characters.
    private static let rowsOrderProbeMaxIds = 40
    private var didTraceFirstHero = false
    /// BUG-42 probe: last non-empty head, so a change through an empty intermediate still logs.
    private var lastNonEmptyHeroHead: String?
    #if DEBUG
    private var didTraceFirstRows = false
    private var lastTracedRowCount = 0
    #endif

    /// Addon-wipe guard (2026-08-28, docs/addon-wipe-investigation-2026-08-28.md): the seed used to
    /// fire on the FIRST empty emission, which on a clean install + sign-in is before the account's
    /// addon list has ever been pulled — and addAddon's debounced full-replace push then overwrote
    /// the account's addons with just Cinemeta. Guests still seed immediately (nothing to pull);
    /// a signed-in account seeds only after the first pull settles (`seedingAllowed()`), with the
    /// `serverPullSettled` watcher below re-attempting once the pull lands on a still-empty list.
    private func maybeSeedDefaultAddon() {
        guard !didSeed else { return }
        guard AddonRepository.shared.seedingAllowed() else {
            // ADD-1 (upstream 1854dfc3 follow-up): a signed-in account whose add-on list this Apple
            // TV already knew is never re-seeded — an empty list there is the user's own deletion,
            // and the seed's push would bring Cinemeta back on every device. Settle the seed the
            // way a failed one does, so the rows gate opens instead of waiting for it.
            if !seedFailed, AddonRepository.shared.defaultSeedDeclined() { seedFailed = true }
            return
        }
        didSeed = true
        seedAttempt += 1
        let attempt = seedAttempt
        AddonRepository.shared.addAddon(rawUrl: cinemetaManifestUrl) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.seedAttempt == attempt else { return }
                guard error != nil || result is AddAddonResultError else { return }
                // Codex round 10 (P2): nothing was added, so no emission follows. Re-run the
                // bootstrap decision on the list as it stands: still empty and settled means a
                // profile with no source, and the rows open the same way `NO_SOURCES` does.
                self.seedFailed = true
                if let state = AddonRepository.shared.uiState.value_ as? AddonsUiState {
                    self.onAddonsChanged(state)
                }
            }
        }
    }

    private func onAddonsChanged(_ state: AddonsUiState) {
        // First run with an empty store → seed Cinemeta, then wait for the next emission. This also
        // catches the repository's pre-bootstrap INITIAL state, which every cold launch delivers
        // here before `AddonRepository.initialize()` runs (the watcher is attached first): it never
        // reaches the rows-gate escape below, and would not open it if it did — see
        // `AddonBootstrapRoute`, which is the term that makes that true for every shape, not just
        // the empty one.
        if state.addons.isEmpty {
            addonManifestError = nil
            maybeSeedDefaultAddon()
            // Codex round 10 (P2): the settled empty list used to return here without asking
            // `AddonBootstrapRoute`, so a seed that could not land (offline fresh install) left the
            // rows gate shut for the session. The pre-bootstrap emission still holds
            // (`isInitialized` false), and so does one whose seed is pending or in flight.
            let bootstrap = AddonBootstrapRoute.decide(isInitialized: state.isInitialized,
                                                       readyIsEmpty: true,
                                                       manifestsPending: false,
                                                       seedPending: !seedFailed,
                                                       hasRefreshed: !lastManifestSignature.isEmpty)
            if bootstrap == .openRowsNoSources {
                openRowsForNoSourcesBootstrap()
            }
            return
        }

        // Only addons whose manifest has actually loaded can contribute catalogs.
        let ready = AddonModelsKt.enabledAddons(state.addons).filter { $0.manifest != nil }
        // Terminal manifest failure with nothing ready and nothing still fetching → surface it.
        // Pending keeps the existing "Setting up your catalogs…" placeholder (already not a false
        // empty state); Retry re-marks the addons refreshing, which clears this again.
        let manifestsPending = AddonModelsKt.hasPendingEnabledManifests(state.addons)
        let bootstrap = AddonBootstrapRoute.decide(isInitialized: state.isInitialized,
                                                   readyIsEmpty: ready.isEmpty,
                                                   manifestsPending: manifestsPending,
                                                   // The list is not empty, so the seed never runs
                                                   // and has nothing left to say here.
                                                   seedPending: false,
                                                   hasRefreshed: !lastManifestSignature.isEmpty)
        if ready.isEmpty {
            addonManifestError = manifestsPending ? nil : AddonModelsKt.firstEnabledManifestError(state.addons)
            // Codex r2 (P1) safety: no enabled add-on has a loaded manifest and none is still
            // fetching one, so nothing will ever call `HomeRepository.refresh` on this profile and
            // `heroGateReleased` can stay false forever. Holding the rows on that would swallow
            // the collection rows for good on an all-add-ons-disabled or total-manifest-failure
            // profile, which is a blank Home rather than a late one. Open the rows gate here: it
            // is the same conclusion `HeroGateReason.NO_SOURCES` reaches on the Kotlin side, and
            // there are no catalogs left to reorder underneath.
            //
            // Internal review r1 (P2): the "no catalog-bearing refresh has happened yet on this
            // profile" term this escape was missing. Without it, a user disabling the last add-on
            // mid-launch - after a ready set had already armed the Kotlin gate - opened the rows on
            // held sections and rebuilt underneath a hero that had not committed, which is the very
            // reorder the gate exists to prevent. Once a refresh HAS run, the gate's own 4s
            // HERO_COMMIT_GATE_TIMEOUT_MS is the backstop and no escape is needed here.
            // (`lastManifestSignature` and `lastRefreshSignature` are written and cleared together,
            // so either reads the same fact; the manifest one names it.)
            //
            // Codex branch review round 9: and the `isInitialized` term, which is what keeps the
            // repository's pre-bootstrap initial state - empty, nothing pending, no signature yet,
            // delivered to this watcher before `AddonRepository.initialize()` even runs - from
            // looking exactly like a settled add-on-less profile. See `AddonBootstrapRoute`.
            if bootstrap == .openRowsNoSources {
                openRowsForNoSourcesBootstrap()
            }
            return
        }
        addonManifestError = nil

        // Wave H (Hole E follow-on): SET semantics, not list order — a server-driven re-sort of the
        // same addons must not read as "the ready set changed" and force a redundant full refresh
        // (the same principle `HomeCatalogDefinitions.kt`'s cacheKey fix applies on the Kotlin side).
        let manifestSignature = ready.map { $0.manifestUrl }.sorted().joined(separator: "|")
        // Codex branch review round 8: carries `displayTitle` too, so a cloud rename (same manifest
        // URLs, new `userSetName`) moves this signature even though `manifestSignature` above does
        // not — see `AddonChangeRoute`.
        let titleSignature = ready
            .map { "\($0.manifestUrl)#\($0.displayTitle)" }
            .sorted()
            .joined(separator: "|")
        let route = AddonChangeRoute.decide(
            previousManifestSignature: lastManifestSignature,
            manifestSignature: manifestSignature,
            previousTitleSignature: lastRefreshSignature,
            titleSignature: titleSignature
        )
        guard route != .none else { return }
        lastRefreshSignature = titleSignature
        lastManifestSignature = manifestSignature

        // BUG-12: register the catalog definitions with the Home Rows settings BEFORE refreshing,
        // mirroring mobile (HomeScreen.kt:538-541). Without this, `settingsItems` only ever knows
        // collections on the Home path (tvOS previously synced catalogs solely from Settings'
        // onAppear), so rebuildRows() forced every collection row above every catalog row until
        // the user happened to open Settings — the "collections are scrambled" report.
        if HomeHeroProbe.enabled {
            let catalogs = ready.reduce(0) { $0 + ($1.manifest?.catalogs.count ?? 0) }
            let routeLabel = route == .metadataOnly ? "metadataOnly" : "refresh"
            // `bootstrap=` (append-only, Codex round 9): `pre` means this emission arrived before
            // add-on bootstrap settled, `settled` after. Every healthy launch reaches the refresh
            // path with `settled`; a `pre` here would say the ready set came from somewhere other
            // than initialize()/a server pull.
            let bootstrapLabel = state.isInitialized ? "settled" : "pre"
            HomeHeroProbe.log(String(format: "addonsChanged vm=%d ready=%d catalogs=%d sinceLaunch=%dms addonRoute=%@ bootstrap=%@", vmId, ready.count, catalogs, HomeHeroProbe.sinceLaunchMs, routeLabel, bootstrapLabel))
        }
        // A manifest-set change needs the fetch (`force: true`); a rename-only change asks
        // `HomeRepository.refresh` for its non-forced, metadata-only republish path instead — see
        // `AddonChangeRoute`'s doc comment for why `force: true` cannot take that path.
        HomeCatalogSettingsRepository.shared.syncCatalogs(addons: ready)
        // Codex beta.18 r5 (P2): catalog loading takes over from any no-sources bootstrap wait —
        // Kotlin's gate (and the hero art prewarm) now own the rows release, so the wait's
        // pending completions must not open the Swift gate underneath them.
        noSourcesWaitGeneration += 1
        noSourcesSyncWatcher?.cancel()
        noSourcesSyncWatcher = nil
        HomeRepository.shared.refresh(addons: ready, force: route == .refresh)
    }

    /// BUG-35 (beta.12): a catalog row scrolled into view — ask the shared repo to localize its
    /// leading items (bounded, session-deduped; see `HomeRepository.requestRowEnrichment`).
    func rowAppeared(sectionKey: String) {
        HomeRepository.shared.requestRowEnrichment(sectionKey: sectionKey)
    }

    deinit {
        addonWatcher?.cancel()
        seedGateWatcher?.cancel()
        homeWatcher?.cancel()
        noSourcesSyncWatcher?.cancel()
        upcomingWatcher?.cancel()
    }
}

/// STAB-07, Home half (decision D8): whether a Continue Watching card may replay the title's last
/// source directly instead of opening the stream picker, and the playback context it plays.
///
/// The source is the progress record's `lastSourceUrl` (the player's progress recorder writes it
/// with every save, and it comes back with the record from the account). It is replayed only when
/// it is still likely to play:
///  - an in-progress card (an Up Next card has no source yet);
///  - an http(s) URL on a real host, never a loopback address (another device's local proxy);
///  - no expiring credentials in the query (the shared `hasLikelyExpiringPlaybackCredentials`, the
///    rule the mobile link cache applies);
///  - watched within the reuse window: the mobile "Reuse last link" hours when that synced setting
///    is on, else 12 h; never more than 15 min for a debrid host, whose links expire sooner.
///
/// The record does not keep the stream's request headers or binge group, so a source that needed
/// headers fails on its first request, and the player's "Choose Another Source" then falls back to
/// the picker (Home also stops replaying that video for the session). Up Next still works: the
/// player's `NextEpisodeEngine` fetches the episode list itself when the context has none.
enum ContinueWatchingDirectPlay {
    static let defaultWindowSec: TimeInterval = 12 * 3600
    static let debridWindowSec: TimeInterval = 15 * 60
    /// Hosts (and their subdomains) that serve debrid-resolved links.
    static let debridHosts = [
        "real-debrid.com", "rdeb.io", "rdb.so", "alldebrid.com", "debrid.it", "premiumize.me",
        "torbox.app", "debrid-link.com", "debrid-link.fr", "debrid.link", "offcloud.com",
        "easydebrid.com",
    ]

    /// The context to play directly, or nil when the card should open the picker.
    static func context(for entry: WatchProgressEntry, now: Date = Date()) -> PlaybackContext? {
        guard let url = sourceURL(for: entry, now: now, windowSec: reuseWindowSec()) else { return nil }
        let season: Int? = entry.seasonNumber?.value
        let episode: Int? = entry.episodeNumber?.value
        let episodeTitle: String? = entry.episodeTitle
        return PlaybackContext(
            url: url,
            // The picker's header label ("S1E3 · Pilot"), which is what its own player is given.
            title: ProgressRecordTitles.pickerTitle(title: entry.title, season: season,
                                                    episode: episode, episodeTitle: episodeTitle),
            contentType: entry.parentMetaType,
            parentMetaId: entry.parentMetaId,
            videoId: entry.videoId,
            season: season,
            episode: episode,
            poster: nonEmpty(entry.poster),
            background: nonEmpty(entry.background),
            providerName: nonEmpty(entry.providerName),
            providerAddonId: nonEmpty(entry.providerAddonId),
            streamTitle: nonEmpty(entry.lastStreamTitle),
            streamSubtitle: nonEmpty(entry.lastStreamSubtitle),
            externalSubtitles: [],
            synopsis: nonEmpty(entry.pauseDescription),
            episodeStill: nonEmpty(entry.episodeThumbnail),
            // CW-1: the record's title is the series name (a legacy episode label is dropped, as
            // the picker does).
            seriesTitle: ProgressRecordTitles.seriesTitle(entry.title, season: season, episode: episode),
            episodeTitle: nonEmpty(episodeTitle),
            logo: nonEmpty(entry.logo)
        )
    }

    /// The source to replay for `entry`, or nil (see the type's doc for the rules).
    static func sourceURL(for entry: WatchProgressEntry, now: Date, windowSec: TimeInterval) -> URL? {
        guard !ContinueWatchingNextUpModel.isNextUp(entry), entry.isResumable else { return nil }
        let stored: String? = entry.lastSourceUrl
        guard let raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty, !isLoopback(host) else { return nil }
        guard !PlaybackUrlCredentialsKt.hasLikelyExpiringPlaybackCredentials(raw) else { return nil }
        let updatedMs = entry.lastUpdatedEpochMs
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard updatedMs > 0, nowMs >= updatedMs else { return nil }
        let window = isDebrid(host: host) ? min(windowSec, debridWindowSec) : windowSec
        guard Double(nowMs - updatedMs) <= window * 1000 else { return nil }
        return url
    }

    /// The mobile "Reuse last link" window when that synced setting is on, else the tvOS default.
    static func reuseWindowSec() -> TimeInterval {
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState,
              settings.streamReuseLastLinkEnabled else { return defaultWindowSec }
        let hours = Int(settings.streamReuseLastLinkCacheHours)
        guard hours > 0 else { return defaultWindowSec }
        return TimeInterval(min(hours, 168)) * 3600
    }

    static func isDebrid(host: String) -> Bool {
        debridHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasPrefix("127.") || host == "::1" || host == "[::1]" || host == "0.0.0.0"
    }

    /// Kotlin-bridged optional strings: blank counts as missing.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
