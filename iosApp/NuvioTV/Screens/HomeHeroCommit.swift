import Foundation
import SharedCore
import UIKit

// MARK: - Hero commit coordinator (Wave H, BUG-86 "doubled hero")
//
// `HomeRepository.HeroCommitGate` (Kotlin, see `HeroCommitGate.kt`) decides WHEN the hero payload
// is allowed to move: it holds `heroItems`/`sections` behind `HomeUiState.heroGateReleased` until
// every input that could still move the head (hero-source catalogs, the launch sync burst, TMDB
// enrichment) has settled, then commits once and freezes the payload for the session.
//
// This file is the Swift half. `HomeViewModel.homeWatcher` uses `HeroCommitCoordinator` to decide,
// per publish, whether to hold, update rows only, or commit a genuinely new head — and when it
// commits, `prepare(_:)` prewarms the head's own backdrop + logo BEFORE `heroItems`/`sections` are
// assigned, so the very first frame that shows the committed hero already has its artwork (or has
// waited `artTimeout` and is painting deliberately without it) instead of painting text over a
// blank/stale backdrop and catching up a beat later (BUG-86 phenomena B/C).

/// Testing seam for the artwork operations `HeroCommitCoordinator.prepare(_:)` depends on. Defaults
/// to the real `ArtworkStore` (`DesignSystem/CachedAsyncImage.swift`) via `ArtworkStoreHeroFetcher`;
/// `HeroCommitCoordinatorTests` injects a stub so `.timeout`/`.failed` outcomes are producible
/// deterministically, without a network.
protocol HeroCommitArtworkFetching {
    @MainActor func cachedImage(_ url: URL?) -> UIImage?
    @MainActor func fetchImage(_ url: URL) async throws -> UIImage
    @MainActor func prefetchImages(_ urls: [URL])
}

/// Default fetcher: routes straight to `ArtworkStore`.
struct ArtworkStoreHeroFetcher: HeroCommitArtworkFetching {
    // Explicit and `nonisolated`: the compiler otherwise infers a MainActor-isolated synthesized
    // init from the @MainActor protocol requirements below, which then warns when used as
    // `HeroCommitCoordinator.init(fetcher:)`'s default argument (evaluated in a nonisolated
    // position).
    nonisolated init() {}

    @MainActor func cachedImage(_ url: URL?) -> UIImage? { ArtworkStore.cached(url) }
    /// `.head` admission (Codex r3, P2): these are only ever the committed hero's own backdrop and
    /// logo, the two images the whole first Home paint waits on, so they jump the six-slot gate's
    /// waiter queue ahead of the row-poster and carousel prefetches this same `prepare(_:)` call
    /// issues right after them.
    @MainActor func fetchImage(_ url: URL) async throws -> UIImage {
        try await ArtworkStore.fetch(url, admission: .head)
    }
    @MainActor func prefetchImages(_ urls: [URL]) { ArtworkStore.prefetch(urls) }
}

/// One head-art prewarm outcome, reported on the `commit` probe line.
///
/// `.ready` — both needed pieces resolved inside `HeroCommitCoordinator.artTimeout` (or nothing was
/// needed at all — already cached, or the item has no backdrop/logo URL to fetch).
/// `.timeout` — the budget expired before everything needed had resolved.
/// `.failed` — everything settled INSIDE the budget, but at least one needed fetch came back empty
/// (404, decode failure, …) — distinct from `.timeout` on purpose: a slow network reads as
/// `art=timeout` in a device photo, a genuinely broken/missing image reads as `art=failed`.
enum HeroCommitArtOutcome: Equatable {
    case ready(waitedMs: Int)
    case timeout(waitedMs: Int)
    case failed(waitedMs: Int)

    /// The token this rides the `commit` probe line as (`art=<ready|timeout|failed>`).
    var status: String {
        switch self {
        case .ready: return "ready"
        case .timeout: return "timeout"
        case .failed: return "failed"
        }
    }

    var waitedMs: Int {
        switch self {
        case .ready(let ms), .timeout(let ms), .failed(let ms): return ms
        }
    }
}

/// The pure decision `HomeViewModel.homeWatcher` makes for every RELEASED, non-empty-or-heroOff
/// publish, given the incoming head's identity/hash against what this coordinator has already
/// committed. Kept separate from `prepare(_:)` (which does async I/O) so
/// `HeroCommitCoordinatorTests` can exercise the whole table synchronously, without a running
/// `HomeViewModel` pipeline.
enum HeroCommitHeadDecision: Equatable {
    /// Same head, same payload. The hero itself must not be re-assigned (the anti-repaint
    /// invariant); rows may still update under it.
    case sameHeadSameHash
    /// Same head, but the payload hash MOVED — an anomaly (committed payloads are frozen on the
    /// Kotlin side except a silent, hash-invisible gap-fill of empty description/genres). Treated
    /// like `.sameHeadSameHash` for painting purposes — the hero still does not repaint — but is a
    /// red flag `HomeViewModel` logs as `hashChanged=1`.
    case sameHeadHashChanged
    /// A genuinely new head: the first-ever commit, a legitimate head change (addon removed, Hero
    /// Sources reset, Show Hero toggled), or a transition to/from no head at all. Must go through
    /// `prepare(_:)` before painting.
    case newHead
}

/// Codex r1 (P2): what a `.newHead` publish does about a `prepare(_:)` that is ALREADY prewarming.
///
/// Until `commit` runs, the coordinator holds no committed key, so `evaluateHeadChange` answers
/// `.newHead` for every released publish, including the post-gate churn (a catalog batch landing,
/// TMDB enrichment completing, a settings sync) that arrives while the head's own artwork is still
/// being fetched. Treating each of those as a fresh head cancelled the in-flight prepare and reset
/// its 1.5 s art budget from zero, so a steady trickle of publishes could defer the first hero and
/// the rows under it indefinitely.
enum HeroPendingCommitRoute: Equatable {
    /// The head already in flight. Leave the running `prepare(_:)` alone (it keeps its clock); the
    /// publish is absorbed so the continuation can commit the LATEST state instead of the one it
    /// captured.
    case absorb
    /// Nothing in flight, or a different head or payload. Cancel whatever is pending, prepare anew.
    case restart

    static func decide(pendingHeadKey: String?, pendingHeadHash: String?, hasPendingTask: Bool,
                       headKey: String, headHash: String) -> HeroPendingCommitRoute {
        guard hasPendingTask, pendingHeadKey == headKey, pendingHeadHash == headHash else { return .restart }
        return .absorb
    }
}

// MARK: - Rows gate (Wave H, Codex r2)

/// The ROWS half of the commit gate.
///
/// `HeroPublishRoute.hold` holds `heroItems`/`sections` while `HomeUiState.heroGateReleased` is
/// false, but `HomeViewModel`'s collections and catalog-settings watchers used to call
/// `rebuildRows()` themselves, straight off the launch sync burst's freshly pulled ordering. So the
/// rows could repaint and reorder BEFORE the hero committed, which is exactly the transition the
/// gate exists to make atomic (the tester's video: "Top 10 des films" on top, then a rebuild that
/// puts "Nouveaux films" first, with skeletons under it).
///
/// While this gate is closed every rebuild request is dropped and counted; the routes that publish
/// the commit (`.noHero`, and the commit continuation) open it and perform exactly ONE rebuild,
/// from the latest sections + collections + settings the watchers have stored in the meantime.
/// Afterwards it stays open and watchers rebuild normally: post-commit reorders are allowed by
/// design. A cloud pull landing a second after first paint carries the Home Rows order the user set
/// on another device, and adopting it is the app doing its job; what the gate buys is that the
/// FIRST paint is one atomic turn, not that rows are frozen for the session. `RowsOrderRule`
/// (NuvioTVUITests.swift) is the oracle half of exactly that split - a post-commit reorder passes
/// only when the settings order behind it actually moved.
///
/// A value type with no `HomeViewModel` dependency, so `HeroCommitCoordinatorTests` can exercise
/// the whole decision synchronously without a live pipeline.
struct RowsGate: Equatable {
    /// What `request()` tells the caller to do.
    enum Decision: Equatable {
        /// The gate is open: rebuild now.
        case rebuild
        /// The gate is closed: drop this rebuild. It has been recorded as pending, and `open()`
        /// performs the single coalesced rebuild that stands in for all of them.
        case hold
    }

    /// False until the first `.noHero` or commit publish opens it; never closes again except
    /// through `reset()` (`HomeViewModel.stop()`, i.e. a profile switch or sign-out).
    private(set) var isOpen = false
    /// True while at least one rebuild was held and not yet performed. Coalesced on purpose: N
    /// held requests still produce exactly one rebuild, because the rebuild always reads the
    /// LATEST sections/collections/settings rather than replaying anything.
    private(set) var pendingRebuild = false
    /// How many rebuilds have been held since the gate last closed. Reported once, as
    /// `heldRebuilds=` on the first `rows` probe line after opening.
    private(set) var heldRebuilds = 0

    /// One rebuild request from any watcher.
    mutating func request() -> Decision {
        guard isOpen else {
            pendingRebuild = true
            heldRebuilds += 1
            return .hold
        }
        return .rebuild
    }

    /// Opens the gate. Returns the number of rebuilds held while it was closed, or nil when the
    /// gate was ALREADY open, so the `heldRebuilds=` field is stamped on exactly one probe line
    /// per open rather than on every later `.noHero` publish.
    ///
    /// The caller always performs one rebuild after this, whether or not anything was held: the
    /// commit publish itself is a row change (it is the publish that first assigns `sections`).
    mutating func open() -> Int? {
        guard !isOpen else { return nil }
        isOpen = true
        pendingRebuild = false
        let held = heldRebuilds
        heldRebuilds = 0
        return held
    }

    /// Profile-scoped reset, from `HomeViewModel.stop()`. The next profile's rows are gated afresh.
    mutating func reset() {
        isOpen = false
        pendingRebuild = false
        heldRebuilds = 0
    }
}

/// Wave H (BUG-86): Swift half of the hero commit protocol. One instance lives on
/// `HomeViewModel`; `reset()` is called from `HomeViewModel.stop()` (profile switch / sign-out) —
/// the next profile's hero is a new commit, never a continuation of this one.
@MainActor
final class HeroCommitCoordinator {
    /// The `"\(type):\(id)"` of the hero this coordinator has already committed. `nil` before the
    /// first commit (or after `reset()`).
    private(set) var committedHeadKey: String?
    /// FNV-1a 64-bit hex (16 chars, lowercase) of the committed head's `banner|logo|name` payload.
    private(set) var committedHash: String?

    /// How long `prepare(_:)` waits for the head's backdrop + logo before committing without
    /// whatever has not landed.
    static let artTimeout: UInt64 = 1_500_000_000

    private let fetcher: HeroCommitArtworkFetching

    init(fetcher: HeroCommitArtworkFetching = ArtworkStoreHeroFetcher()) {
        self.fetcher = fetcher
    }

    /// Resets committed identity. Called from `HomeViewModel.stop()` — profile-scoped state on a
    /// coordinator that (like `HomeViewModel` itself) can outlive a single profile.
    func reset() {
        committedHeadKey = nil
        committedHash = nil
    }

    /// Records a completed commit. Called once `prepare(_:)`'s outcome has been applied to the
    /// published `heroItems`/`sections` — see `HomeViewModel.homeWatcher`'s `.newHead` branch.
    func commit(headKey: String, headHash: String) {
        committedHeadKey = headKey
        committedHash = headHash
    }

    /// Codex r1 (P2): did the carousel TAIL move while the painted head survived?
    ///
    /// Kotlin republishes the hero list whenever a hero-source catalog finishes or a filter prunes
    /// one of its entries, with the surviving items' payloads frozen. The same-head branch in
    /// `HomeViewModel.homeWatcher` never assigned `heroItems` for those, so the pages and the
    /// page-dot count kept removed items and missed newcomers for the rest of the session. Both
    /// arguments are ordered `headKey(_:)` lists; an empty painted list is never a tail change,
    /// being the pre-commit state, which the `.newHead` path owns.
    ///
    /// `nonisolated`: pure, and the tests call it from plain synchronous methods.
    nonisolated static func heroTailChanged(painted: [String], incoming: [String]) -> Bool {
        guard let paintedHead = painted.first, paintedHead == incoming.first else { return false }
        return painted != incoming
    }

    /// The pure decision table (see `HeroCommitHeadDecision`).
    func evaluateHeadChange(headKey: String, headHash: String) -> HeroCommitHeadDecision {
        guard headKey == committedHeadKey else { return .newHead }
        return headHash == committedHash ? .sameHeadSameHash : .sameHeadHashChanged
    }

    /// `"\(type):\(id)"` — the stable identity the commit decision keys on. Matches
    /// `MetaPreview.stableKey()` on the Kotlin side (not called directly — this file stays
    /// dependency-free of the `Extensions` category for its own two-field composition).
    ///
    /// `nonisolated`: pure, touches no instance/actor state, and `HeroCommitCoordinatorTests`
    /// calls it from plain synchronous (non-`@MainActor`) test methods.
    nonisolated static func headKey(_ item: MetaPreview) -> String {
        "\(item.type):\(item.id)"
    }

    /// FNV-1a 64-bit hex of the three fields that must never change post-commit: banner, logo,
    /// name. Deliberately NOT `String.hashValue` — that is randomized per process, so two identical
    /// payloads captured in two different launches (a device photo taken today vs. a follow-up
    /// tomorrow) would show different hashes and make `hashChanged=`/the stored `committedHash`
    /// meaningless across runs. `nonisolated` for the same reason as `headKey(_:)`.
    nonisolated static func headHashHex(_ item: MetaPreview) -> String {
        fnv1a64Hex("\(item.banner ?? "")|\(item.logo ?? "")|\(item.name)")
    }

    /// Bare FNV-1a 64-bit hash, hex-encoded (16 lowercase chars). Exposed (not `private`) so
    /// `HeroCommitCoordinatorTests` can check it against the published FNV-1a test vectors
    /// independently of the `banner|logo|name` composition `headHashHex(_:)` builds on top of it.
    nonisolated static func fnv1a64Hex(_ string: String) -> String {
        String(format: "%016llx", fnv1a64(string))
    }

    nonisolated private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV offset basis (64-bit)
        let prime: UInt64 = 0x0000_0100_0000_01b3  // FNV prime (64-bit)
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Prewarms the head's artwork, prefetches the rest of the carousel plus the first screenful of
    /// row posters, and reports how the head's own prewarm went. `state.heroItems` is assumed
    /// non-empty — `HomeViewModel.homeWatcher` never routes a heroOff/empty publish through here.
    ///
    /// Codex r3 (P1), DEADLINE. The head wait is built from unstructured tasks plus a continuation
    /// that whichever finishes first (both fetches settling, `artTimeout` elapsing, or this task
    /// being cancelled) resumes. It deliberately is NOT a task group: a group awaits every child on
    /// the way out even after `cancelAll()`, and `ArtworkStore.fetch` parks on shared unstructured
    /// work that ignores waiter cancellation by design (a cancelled awaiter still lets the image
    /// land in the cache for the next viewer). So the group form could sit on the URLSession
    /// timeout, tens of seconds past the 1.5 s budget, holding the hero AND the rows blank behind
    /// it. `artTimeout` is now a real ceiling on how long a commit can be deferred.
    ///
    /// Late results are not lost: the fetch tasks are left running rather than cancelled, and
    /// `ArtworkStore` caches whatever lands, so a backdrop that misses the deadline is already
    /// warm for `HeroArtResolver`'s own presentation a moment later.
    ///
    /// Codex r3 (P1), ORDER. The head's two fetches are issued BEFORE the bulk prefetches, which
    /// now go out from a follow-up main-actor turn. Both travel through `ArtworkStore`'s six-slot
    /// admission gate, and a cold Home queues up to 28 row posters plus 14 carousel images; issued
    /// first, those filled every slot and the head, the one image the commit actually waits on,
    /// queued behind dozens of fire-and-forget requests. The main actor drains its tasks in order,
    /// so the head's two tasks reach `ArtworkStore.fetch` (and therefore the gate) before the
    /// prefetch task even runs; `ArtworkStore.FetchAdmission.head` (front of the waiter queue, see
    /// `ArtworkStoreHeroFetcher.fetchImage`) covers the remaining case, a gate already saturated by
    /// another screen's artwork.
    func prepare(_ state: HomeUiState) async -> HeroCommitArtOutcome {
        guard let head = state.heroItems.first else {
            return .ready(waitedMs: 0)
        }

        let backdropURL = heroBackdropURL(for: head).flatMap(URL.init(string:))
        let logoURL = heroLogoURL(for: head)
        let cachedBackdrop = fetcher.cachedImage(backdropURL)
        let cachedLogo = fetcher.cachedImage(logoURL)
        let needsBackdrop = backdropURL != nil && cachedBackdrop == nil
        let needsLogo = logoURL != nil && cachedLogo == nil

        let fetcher = self.fetcher   // local copy: no `self` capture inside the fetch tasks below
        let started = Date()
        let prewarm = HeadArtPrewarm(needsBackdrop: needsBackdrop, needsLogo: needsLogo)

        // Head first, before a single prefetch is queued (see the ORDER note above). Unstructured
        // and never cancelled: whatever lands after the deadline still lands in `ArtworkStore`.
        if needsBackdrop, let backdropURL {
            Task { @MainActor in
                let image = try? await fetcher.fetchImage(backdropURL)
                prewarm.resolveBackdrop(image != nil)
            }
        }
        if needsLogo, let logoURL {
            Task { @MainActor in
                let image = try? await fetcher.fetchImage(logoURL)
                prewarm.resolveLogo(image != nil)
            }
        }

        // Deliverable 4: first 4 catalog rows x first 7 items' posters. Fire-and-forget, same as
        // the carousel prefetch below — the commit itself must wait on nothing but the HEAD's own
        // backdrop + logo.
        let rowPosterURLs = rowPosterPrewarmURLs(sections: state.sections)

        // The other 7 hero items' backdrop + logo (fire-and-forget; whatever lands, lands in
        // ArtworkStore's cache for the carousel's own later `HeroArtResolver.present` calls, so
        // paging to them is cache-warm even though this coordinator never re-presents them itself).
        var carouselURLs: [URL] = []
        for item in state.heroItems.dropFirst().prefix(7) {
            if let backdrop = heroBackdropURL(for: item).flatMap(URL.init(string:)) {
                carouselURLs.append(backdrop)
            }
            if let logo = heroLogoURL(for: item) {
                carouselURLs.append(logo)
            }
        }

        // One turn behind the head's own fetches (see the ORDER note above), never ahead of them.
        if !rowPosterURLs.isEmpty || !carouselURLs.isEmpty {
            Task { @MainActor in
                if !rowPosterURLs.isEmpty { fetcher.prefetchImages(rowPosterURLs) }
                if !carouselURLs.isEmpty { fetcher.prefetchImages(carouselURLs) }
            }
        }

        guard needsBackdrop || needsLogo else {
            return .ready(waitedMs: 0)
        }

        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.artTimeout)
            guard !Task.isCancelled else { return }
            prewarm.deadlineElapsed()
        }

        // Resumed by the last needed fetch, by `deadline`, or by cancellation, whichever is first.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                prewarm.attach(continuation)
            }
        } onCancel: {
            // `HomeViewModel`'s `.noHero` route cancels a pending prepare. Stop waiting and return
            // a normal outcome; the caller gates the commit on `heroCommitGeneration`, not on the
            // cancellation propagating out of here (see the cancellation test).
            Task { @MainActor in prewarm.cancelWait() }
        }
        deadline.cancel()

        let waitedMs = Int(Date().timeIntervalSince(started) * 1000)
        let allOK = prewarm.backdropOK && prewarm.logoOK
        if prewarm.hitDeadline && !allOK {
            return .timeout(waitedMs: waitedMs)
        }
        return allOK ? .ready(waitedMs: waitedMs) : .failed(waitedMs: waitedMs)
    }

    /// Deliverable 4: first 4 catalog rows x first 7 items' posters. Returns the URLs rather than
    /// prefetching them itself so `prepare(_:)` controls WHEN they are issued (Codex r3, P2: after
    /// the head's own two fetches, never before them).
    private func rowPosterPrewarmURLs(sections: [HomeCatalogSection]) -> [URL] {
        var urls: [URL] = []
        for section in sections.prefix(4) {
            for item in section.items.prefix(7) {
                guard let poster = item.poster, !poster.isEmpty, let url = URL(string: poster) else { continue }
                urls.append(url)
            }
        }
        return urls
    }
}

/// Codex r3 (P1): the head prewarm's wait state, owned by one `HeroCommitCoordinator.prepare(_:)`
/// call. It exists so the 1.5 s art budget is enforced by a continuation that the FIRST terminal
/// event resumes, instead of by a task group whose implicit "await every child" defeats the
/// deadline (see `prepare(_:)`'s doc comment for the full reasoning).
///
/// `@MainActor`, like everything `prepare(_:)` touches, so the fetch tasks, the deadline task and
/// the cancellation handler all mutate this on one actor with no locking; being global-actor
/// isolated also makes it implicitly `Sendable` for the capture in `withTaskCancellationHandler`.
@MainActor
private final class HeadArtPrewarm {
    /// True once the piece has resolved successfully, or immediately when it was never needed
    /// (already cached, or the head has no such URL).
    private(set) var backdropOK: Bool
    private(set) var logoOK: Bool
    /// True only when the budget expired first. Distinguishes `art=timeout` (slow network) from
    /// `art=failed` (everything settled, something came back empty) on the commit probe line.
    private(set) var hitDeadline = false

    private var pendingBackdrop: Bool
    private var pendingLogo: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    /// Set by the first terminal event. Later arrivals are no-ops, and `attach` resumes at once so
    /// a wait that finished before the continuation existed cannot hang.
    private var finished = false

    init(needsBackdrop: Bool, needsLogo: Bool) {
        backdropOK = !needsBackdrop
        logoOK = !needsLogo
        pendingBackdrop = needsBackdrop
        pendingLogo = needsLogo
    }

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
        if finished {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    func resolveBackdrop(_ ok: Bool) {
        guard !finished else { return }
        backdropOK = ok
        pendingBackdrop = false
        finishIfSettled()
    }

    func resolveLogo(_ ok: Bool) {
        guard !finished else { return }
        logoOK = ok
        pendingLogo = false
        finishIfSettled()
    }

    /// The budget expired. Whatever has not landed is not part of this commit; it stays in flight
    /// inside `ArtworkStore` so it lands in the cache for this item's next presentation.
    func deadlineElapsed() {
        guard !finished else { return }
        hitDeadline = true
        finish()
    }

    /// The enclosing `prepare(_:)` task was cancelled. Stop waiting and report what has landed so
    /// far; not a deadline, so the outcome reads `failed`, never `timeout`.
    func cancelWait() {
        guard !finished else { return }
        finish()
    }

    private func finishIfSettled() {
        guard !pendingBackdrop, !pendingLogo else { return }
        finish()
    }

    private func finish() {
        finished = true
        pendingBackdrop = false
        pendingLogo = false
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }
}

// MARK: - Burst-sim launch arg (Wave H device diagnostics)

/// `-debug.homeLaunchBurstSim YES` arms `HomeLaunchBurstSim` (shared Kotlin, see
/// `HomeLaunchBurstSim.kt`) — a deterministic, offline replay of the launch sync burst that
/// produced BUG-86 on the tester's TV and never on ours (our sim fixture has no signed-in sync
/// burst, so the holes the gate closes never open there).
///
/// Same pairing rule as `TrailerProbe.forceNoTrailer` (`Screens/TrailerDebugProbes.swift:49-54`):
/// read once, logged once, honored only when `HomeHeroProbe.enabled` is ALSO true — a stray
/// persisted launch arg must never silently mutate a release sideload's local Home ordering (the
/// burst PERSISTS its row/collection reordering locally; see `HomeLaunchBurstSim.kt`'s warning).
enum HomeLaunchBurstSimArgs {
    nonisolated static let enabled: Bool = {
        let raw = UserDefaults.standard.bool(forKey: "debug.homeLaunchBurstSim")
        guard raw else { return false }
        let honored = HomeHeroProbe.enabled
        NSLog("[HomeHero] burstSim present=YES honored=%@", honored ? "YES" : "NO (debug.homeHeroProbe off)")
        return honored
    }()
}

/// `-debug.homeHeroOff YES` makes this process read as a "Show Hero" OFF profile, so the FEAT-15
/// focus panel is the top of Home and the BUG-86 hero-off rows hold (beta.18) is exercisable on a
/// fixture whose real profile has the hero on.
///
/// Applied through `HomeCatalogSettingsRepository.debugForceHeroOff`, which is consulted by
/// `snapshot()` and by the local UI state and by NEITHER the persisted payload nor the sync push —
/// deliberately not `setHeroEnabled(false)`, which would turn the hero off on the tester's real
/// account and on every device it syncs to.
///
/// Same pairing rule as `HomeLaunchBurstSimArgs` above and `TrailerProbe.forceNoTrailer`: read
/// once, logged once, honored only when `HomeHeroProbe.enabled` is ALSO true, so a stray persisted
/// launch arg can never silently blank the hero on a release sideload.
enum HomeHeroOffArgs {
    nonisolated static let enabled: Bool = {
        let raw = UserDefaults.standard.bool(forKey: "debug.homeHeroOff")
        guard raw else { return false }
        let honored = HomeHeroProbe.enabled
        NSLog("[HomeHero] heroOff present=YES honored=%@", honored ? "YES" : "NO (debug.homeHeroProbe off)")
        return honored
    }()
}
