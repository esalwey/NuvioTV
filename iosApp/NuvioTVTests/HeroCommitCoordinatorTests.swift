import XCTest
@testable import NuvioTV
import SharedCore
import UIKit

/// Unit tests for `HeroCommitCoordinator` (`Screens/HomeHeroCommit.swift`, Wave H / BUG-86) — the
/// Swift half of the hero commit protocol. Covers the pure head-change decision table
/// (`evaluateHeadChange`), the FNV-1a hash (stable across runs, unlike `String.hashValue`), and
/// `prepare(_:)`'s art-timeout path via an injected `HeroCommitArtworkFetching` stub so no real
/// network is involved.
final class HeroCommitCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeItem(id: String = "1", type: String = "movie", name: String = "Movie",
                          banner: String? = "https://example.com/banner.jpg",
                          logo: String? = "https://example.com/logo.png") -> MetaPreview {
        MetaPreview(
            id: id, type: type, name: name,
            poster: nil, banner: banner, logo: logo,
            posterShape: .poster,
            description: nil, releaseInfo: nil, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: []
        )
    }

    /// BUG-86 hero-off rows (beta.18): `rowsGateReleased`/`rowsGateReason` are appended here
    /// because Kotlin/Native does not carry default arguments into the exported ObjC initializer —
    /// every Swift construction site has to spell out the whole shape. Defaulted to the released
    /// pair so existing callers keep meaning what they meant.
    private func makeState(heroItems: [MetaPreview], sections: [HomeCatalogSection] = [],
                           heroGateReleased: Bool = true, heroGateReason: String? = "all",
                           rowsGateReleased: Bool = true, rowsGateReason: String? = nil) -> HomeUiState {
        HomeUiState(
            isLoading: false,
            heroItems: heroItems,
            sections: sections,
            errorMessage: nil,
            heroGateReleased: heroGateReleased,
            heroGateReason: heroGateReason,
            rowsGateReleased: rowsGateReleased,
            rowsGateReason: rowsGateReason
        )
    }

    // MARK: - FNV-1a stability (never `String.hashValue`, which is randomized per process)

    func testFnv1aKnownVectors() {
        // Published FNV-1a 64-bit test vectors (offset basis / prime per the FNV spec).
        XCTAssertEqual(HeroCommitCoordinator.fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(HeroCommitCoordinator.fnv1a64Hex("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(HeroCommitCoordinator.fnv1a64Hex("foobar"), "85944171f73967e8")
    }

    func testFnv1aStableAcrossRepeatedCalls() {
        // Same payload, two independent calls (simulating "two launches") must agree — the whole
        // point of not using `String.hashValue`, which is reseeded per process.
        let a = HeroCommitCoordinator.headHashHex(makeItem())
        let b = HeroCommitCoordinator.headHashHex(makeItem())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16, "expected 16 lowercase hex chars (64-bit)")
    }

    func testHeadHashChangesWithBannerLogoOrName() {
        let base = HeroCommitCoordinator.headHashHex(makeItem())
        XCTAssertNotEqual(base, HeroCommitCoordinator.headHashHex(makeItem(name: "Different Movie")))
        XCTAssertNotEqual(base, HeroCommitCoordinator.headHashHex(makeItem(banner: "https://example.com/other.jpg")))
        XCTAssertNotEqual(base, HeroCommitCoordinator.headHashHex(makeItem(logo: nil)))
    }

    // MARK: - Head-change decision table

    @MainActor
    func testNewHeadBeforeAnyCommit() {
        let coordinator = HeroCommitCoordinator()
        let item = makeItem(id: "1")
        let decision = coordinator.evaluateHeadChange(
            headKey: HeroCommitCoordinator.headKey(item),
            headHash: HeroCommitCoordinator.headHashHex(item)
        )
        XCTAssertEqual(decision, .newHead)
        // Evaluating is non-mutating — nothing commits just by asking.
        XCTAssertNil(coordinator.committedHeadKey)
        XCTAssertNil(coordinator.committedHash)
    }

    @MainActor
    func testSameHeadSameHashDoesNotCommit() {
        let coordinator = HeroCommitCoordinator()
        let item = makeItem(id: "1")
        let key = HeroCommitCoordinator.headKey(item)
        let hash = HeroCommitCoordinator.headHashHex(item)
        coordinator.commit(headKey: key, headHash: hash)

        let decision = coordinator.evaluateHeadChange(headKey: key, headHash: hash)
        XCTAssertEqual(decision, .sameHeadSameHash)
        // Still the original commit — evaluating again must not itself commit anything new.
        XCTAssertEqual(coordinator.committedHeadKey, key)
        XCTAssertEqual(coordinator.committedHash, hash)
    }

    @MainActor
    func testSameHeadDifferentHashFlagsWithoutCommitting() {
        let coordinator = HeroCommitCoordinator()
        let item = makeItem(id: "1", banner: "https://example.com/banner.jpg")
        let key = HeroCommitCoordinator.headKey(item)
        let originalHash = HeroCommitCoordinator.headHashHex(item)
        coordinator.commit(headKey: key, headHash: originalHash)

        // Same identity, payload drifted (should-never-happen anomaly — committed payloads are
        // frozen on the Kotlin side except a hash-invisible gap-fill).
        let driftedItem = makeItem(id: "1", banner: "https://example.com/different-banner.jpg")
        let driftedHash = HeroCommitCoordinator.headHashHex(driftedItem)
        XCTAssertNotEqual(originalHash, driftedHash)

        let decision = coordinator.evaluateHeadChange(headKey: key, headHash: driftedHash)
        XCTAssertEqual(decision, .sameHeadHashChanged)
        // The anomaly is flagged (`.sameHeadHashChanged` vs. `.sameHeadSameHash`), but the
        // coordinator's own committed record is untouched — the caller never calls `commit(_:_:)`
        // for this decision, exactly like `.sameHeadSameHash`.
        XCTAssertEqual(coordinator.committedHeadKey, key)
        XCTAssertEqual(coordinator.committedHash, originalHash)
    }

    @MainActor
    func testNewHeadAfterADifferentCommittedHead() {
        let coordinator = HeroCommitCoordinator()
        let first = makeItem(id: "1")
        coordinator.commit(headKey: HeroCommitCoordinator.headKey(first), headHash: HeroCommitCoordinator.headHashHex(first))

        let second = makeItem(id: "2", name: "Other Movie")
        let decision = coordinator.evaluateHeadChange(
            headKey: HeroCommitCoordinator.headKey(second),
            headHash: HeroCommitCoordinator.headHashHex(second)
        )
        XCTAssertEqual(decision, .newHead)
    }

    @MainActor
    func testResetClearsCommittedIdentity() {
        let coordinator = HeroCommitCoordinator()
        let item = makeItem(id: "1")
        coordinator.commit(headKey: HeroCommitCoordinator.headKey(item), headHash: HeroCommitCoordinator.headHashHex(item))
        XCTAssertNotNil(coordinator.committedHeadKey)

        coordinator.reset()
        XCTAssertNil(coordinator.committedHeadKey)
        XCTAssertNil(coordinator.committedHash)
        // Post-reset, the same item reads as a new head again (profile switch semantics).
        let decision = coordinator.evaluateHeadChange(
            headKey: HeroCommitCoordinator.headKey(item),
            headHash: HeroCommitCoordinator.headHashHex(item)
        )
        XCTAssertEqual(decision, .newHead)
    }

    // MARK: - HeroPublishRoute (the watcher's hold / no-hero / evaluate routing)

    func testRouteHoldsWhileGateArmed() {
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: false, gateReason: nil, heroIsEmpty: true), .hold)
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: false, gateReason: nil, heroIsEmpty: false), .hold)
    }

    func testRouteEvaluatesHeadOnAHealthyRelease() {
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: "all", heroIsEmpty: false), .evaluateHead)
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: "timeout", heroIsEmpty: false), .evaluateHead)
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: "reset", heroIsEmpty: false), .evaluateHead)
    }

    func testRouteTreatsHeroOffAsNoHero() {
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: "heroOff", heroIsEmpty: true), .noHero)
        // Hero off but the repository still handed over a candidate list: still no hero region.
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: "heroOff", heroIsEmpty: false), .noHero)
    }

    /// The P1 regression this routing exists to prevent: `decideHeroGate` (`HeroCommitGate.kt`)
    /// evaluates `reset`, `timeout` and `noSources` BEFORE the candidate-empty term, so all three
    /// can release with `heroItems = []` and a fully populated `sections`. Held (as an earlier
    /// revision did for every reason but `heroOff`), Home never assigned `sections` again and sat
    /// on the empty state with `isLoading = false` for the rest of the session.
    func testRouteReleasedWithAnEmptyHeroPublishesRowsInsteadOfHolding() {
        for reason in ["all", "timeout", "reset", "noSources"] {
            XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: reason, heroIsEmpty: true),
                           .noHero,
                           "a released publish with an empty hero (reason=\(reason)) must publish rows, never hold")
        }
        // Also true when the repository releases without naming a reason at all.
        XCTAssertEqual(HeroPublishRoute.decide(gateReleased: true, gateReason: nil, heroIsEmpty: true), .noHero)
    }

    // MARK: - HeroPublishRoute × rowsReleased (BUG-86 hero-off rows, beta.18)

    /// The tester's build-117 shape. `heroOff` releases on the gate's FIRST evaluation, so every
    /// publish the launch sync burst drives afterwards is a released one; adopting their `sections`
    /// reordered the rows under a FEAT-15 focus panel that had already painted, and the panel
    /// repainted with a different title. `HomeUiState.rowsGateReleased` is false on exactly those.
    func testRouteHoldsAReleasedPublishWhoseRowsAreStillHeld() {
        XCTAssertEqual(
            HeroPublishRoute.decide(gateReleased: true, gateReason: "heroOff", heroIsEmpty: true,
                                    rowsReleased: false),
            .hold,
            "a heroOff release that still owes the launch sync burst must not publish rows"
        )
        XCTAssertEqual(
            HeroPublishRoute.decide(gateReleased: true, gateReason: "noSources", heroIsEmpty: true,
                                    rowsReleased: false),
            .hold,
            "the collection-only profile has the same exposure: its folder order is what the burst rewrites"
        )
    }

    /// Once the burst has landed (or the rows budget expired) the same publish shape routes exactly
    /// as it did before this flag existed — one `.noHero`, one rows build, one paint.
    func testRouteOpensRowsOnceTheRowsGateReleases() {
        XCTAssertEqual(
            HeroPublishRoute.decide(gateReleased: true, gateReason: "heroOff", heroIsEmpty: true,
                                    rowsReleased: true),
            .noHero
        )
        XCTAssertEqual(
            HeroPublishRoute.decide(gateReleased: true, gateReason: "noSources", heroIsEmpty: true,
                                    rowsReleased: true),
            .noHero
        )
    }

    /// The flag never rescues a publish the hero gate is already holding, and it never gates a
    /// reason that commits a hero: `all`, `reset` and `timeout` carry rows the burst is folded into
    /// (Kotlin sets `rowsReleased = released` for all three — see `decideHeroGate`).
    func testRowsFlagDoesNotChangeTheRestOfTheTable() {
        XCTAssertEqual(
            HeroPublishRoute.decide(gateReleased: false, gateReason: nil, heroIsEmpty: true,
                                    rowsReleased: true),
            .hold,
            "an armed gate holds whatever the rows flag says"
        )
        for reason in ["all", "timeout", "reset"] {
            XCTAssertEqual(
                HeroPublishRoute.decide(gateReleased: true, gateReason: reason, heroIsEmpty: false,
                                        rowsReleased: true),
                .evaluateHead,
                "a hero commit (reason=\(reason)) still routes to the coordinator"
            )
        }
    }

    /// The default is the compatibility contract: every existing call site and every publish that
    /// commits a hero reads as "rows follow the hero", which is what the table meant before.
    func testRowsFlagDefaultsToReleased() {
        XCTAssertEqual(
            HeroPublishRoute.decide(gateReleased: true, gateReason: "heroOff", heroIsEmpty: true),
            HeroPublishRoute.decide(gateReleased: true, gateReason: "heroOff", heroIsEmpty: true,
                                    rowsReleased: true)
        )
    }

    // MARK: - AddonChangeRoute (Codex branch review round 8: renames must reach the metadata path)

    func testAddonChangeRouteNoneWhenNothingMoved() {
        XCTAssertEqual(
            AddonChangeRoute.decide(previousManifestSignature: "a|b", manifestSignature: "a|b",
                                    previousTitleSignature: "a#One|b#Two", titleSignature: "a#One|b#Two"),
            .none)
    }

    /// The bug this fix closes: a cloud-synced `displayTitle` rename moves the title signature but
    /// not the manifest-URL signature. That must route to a non-forced (`.metadataOnly`) refresh,
    /// not fall through the old manifest-only guard and get silently dropped.
    func testAddonChangeRouteMetadataOnlyWhenOnlyATitleMoved() {
        XCTAssertEqual(
            AddonChangeRoute.decide(previousManifestSignature: "a|b", manifestSignature: "a|b",
                                    previousTitleSignature: "a#One|b#Two", titleSignature: "a#Renamed|b#Two"),
            .metadataOnly)
    }

    func testAddonChangeRouteRefreshWhenTheManifestSetChanged() {
        // An addon installed: the manifest signature gained a member, so the title signature moved
        // too (every manifest-URL change moves both signatures at once).
        XCTAssertEqual(
            AddonChangeRoute.decide(previousManifestSignature: "a|b", manifestSignature: "a|b|c",
                                    previousTitleSignature: "a#One|b#Two", titleSignature: "a#One|b#Two|c#Three"),
            .refresh)
    }

    func testAddonChangeRouteRefreshWhenAnAddonWasRemoved() {
        XCTAssertEqual(
            AddonChangeRoute.decide(previousManifestSignature: "a|b", manifestSignature: "a",
                                    previousTitleSignature: "a#One|b#Two", titleSignature: "a#One"),
            .refresh)
    }

    /// A re-sort with no rename and no manifest-set change (SET semantics, not list order) must
    /// stay `.none` — both signatures are built from a `.sorted()` array, so re-ordering the
    /// underlying `ready` list produces byte-identical signatures.
    func testAddonChangeRouteNoneOnReorderWithNoRename() {
        let previousManifest = ["a", "b"].sorted().joined(separator: "|")
        let previousTitle = ["a#One", "b#Two"].sorted().joined(separator: "|")
        let reorderedManifest = ["b", "a"].sorted().joined(separator: "|")
        let reorderedTitle = ["b#Two", "a#One"].sorted().joined(separator: "|")
        XCTAssertEqual(
            AddonChangeRoute.decide(previousManifestSignature: previousManifest, manifestSignature: reorderedManifest,
                                    previousTitleSignature: previousTitle, titleSignature: reorderedTitle),
            .none)
    }

    // MARK: - AddonBootstrapRoute (Codex round 9: the rows gate stays shut until add-ons settle)

    /// THE REGRESSION. `HomeViewModel` attaches its add-on watcher before calling
    /// `AddonRepository.initialize()`, so the first emission of every cold launch is the
    /// repository's initial state: nothing ready, nothing pending, no refresh signature. That is
    /// byte-for-byte the shape of a settled add-on-less profile, and the old escape opened the rows
    /// gate on it, letting the collections/settings watchers paint and reorder rows before the hero
    /// committed. `isInitialized` is the only term that separates the two.
    func testBootstrapRouteHoldsTheInitialPreInitializeState() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: false, readyIsEmpty: true,
                                       manifestsPending: false, seedPending: false, hasRefreshed: false),
            .holdRows)
    }

    /// Bootstrap settled and this profile genuinely has no add-on that can ever produce a catalog:
    /// nothing will release the Kotlin hero gate, so the rows must open here or a collections-only
    /// Home stays blank for the session.
    func testBootstrapRouteOpensOnceBootstrapSettledWithNoSources() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: true, readyIsEmpty: true,
                                       manifestsPending: false, seedPending: false, hasRefreshed: false),
            .openRowsNoSources)
    }

    /// An enabled add-on has a loaded manifest: the refresh path owns this emission and the rows
    /// gate is left to the hero commit.
    func testBootstrapRouteStaysOutOfTheWayWhenSomethingIsReady() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: true, readyIsEmpty: false,
                                       manifestsPending: false, seedPending: false, hasRefreshed: false),
            .none)
        // Ready wins even before bootstrap has flagged itself settled — a ready manifest IS a
        // settled add-on, and the refresh path must not be diverted into a rows-gate decision.
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: false, readyIsEmpty: false,
                                       manifestsPending: true, seedPending: false, hasRefreshed: false),
            .none)
    }

    /// A manifest fetch is still in flight, so "no sources" is not a fact yet: keep the
    /// "Setting up your catalogs…" placeholder and the rows held.
    func testBootstrapRouteHoldsWhileAManifestIsStillFetching() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: true, readyIsEmpty: true,
                                       manifestsPending: true, seedPending: false, hasRefreshed: false),
            .holdRows)
    }

    /// Internal review r1 (P2), preserved: once a catalog-bearing refresh HAS run, disabling the
    /// last add-on mid-launch must not open the rows on held sections — the Kotlin gate's own
    /// timeout is the backstop from then on.
    func testBootstrapRouteHoldsAfterARefreshHasAlreadyRun() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: true, readyIsEmpty: true,
                                       manifestsPending: false, seedPending: false, hasRefreshed: true),
            .holdRows)
    }

    /// Codex round 10 (P2): bootstrap settled on an EMPTY list, but the default seed has not had
    /// its say (a signed-in account waits for the first server pull; a guest's `addAddon` is in
    /// flight). Cinemeta may still land, so "no sources" is not a fact yet.
    func testBootstrapRouteHoldsAnEmptyListWhileTheSeedIsPending() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: true, readyIsEmpty: true,
                                       manifestsPending: false, seedPending: true, hasRefreshed: false),
            .holdRows)
    }

    /// Codex round 10 (P2), THE REGRESSION: the seed failed (offline fresh install) and
    /// `addAddon` adds nothing on failure, so no add-on emission ever follows. The settled empty
    /// list is then this profile's final word, and the rows must open on it or a collections-only
    /// Home stays blank for the session.
    func testBootstrapRouteOpensAnEmptyListOnceTheSeedHasFailed() {
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: true, readyIsEmpty: true,
                                       manifestsPending: false, seedPending: false, hasRefreshed: false),
            .openRowsNoSources)
        // Still not before bootstrap settles, whatever the seed did.
        XCTAssertEqual(
            AddonBootstrapRoute.decide(isInitialized: false, readyIsEmpty: true,
                                       manifestsPending: false, seedPending: false, hasRefreshed: false),
            .holdRows)
    }

    // MARK: - HeroPendingCommitRoute (Codex r1 P2: the in-flight head is preserved, not restarted)

    func testPendingRouteAbsorbsAPublishForTheHeadAlreadyPreparing() {
        // The exact post-gate churn shape: a catalog batch / enrichment / settings sync republishes
        // the SAME head while its art is still prewarming. Restarting would reset the 1.5s budget.
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: "movie:1", pendingHeadHash: "abc",
                                          hasPendingTask: true, headKey: "movie:1", headHash: "abc"),
            .absorb
        )
    }

    func testPendingRouteRestartsForADifferentHead() {
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: "movie:1", pendingHeadHash: "abc",
                                          hasPendingTask: true, headKey: "movie:2", headHash: "abc"),
            .restart
        )
        // Same identity, payload drifted: the artwork URLs may have moved with it, so the prewarm
        // genuinely has to run again.
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: "movie:1", pendingHeadHash: "abc",
                                          hasPendingTask: true, headKey: "movie:1", headHash: "def"),
            .restart
        )
    }

    func testPendingRouteRestartsWhenNothingIsInFlight() {
        // Nothing pending at all (the session's first commit) and, critically, the bookkeeping
        // going stale (a key left behind by a completed or cancelled prepare) must never be read as
        // "already in flight" and swallow the publish.
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: nil, pendingHeadHash: nil,
                                          hasPendingTask: false, headKey: "movie:1", headHash: "abc"),
            .restart
        )
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: "movie:1", pendingHeadHash: "abc",
                                          hasPendingTask: false, headKey: "movie:1", headHash: "abc"),
            .restart
        )
    }

    // MARK: - Carousel tail changes (Codex r1 P2)

    func testTailChangeDetectedWhenTheHeadSurvives() {
        // A non-head entry removed, and a newcomer appended: both are tail changes the same-head
        // branch must adopt, or the pages and the dot count drift from the repository forever.
        XCTAssertTrue(HeroCommitCoordinator.heroTailChanged(painted: ["movie:1", "movie:2", "movie:3"],
                                                            incoming: ["movie:1", "movie:3"]))
        XCTAssertTrue(HeroCommitCoordinator.heroTailChanged(painted: ["movie:1", "movie:2"],
                                                            incoming: ["movie:1", "movie:2", "movie:4"]))
        // A pure REORDER of the tail counts too: the page order is what the user swipes through.
        XCTAssertTrue(HeroCommitCoordinator.heroTailChanged(painted: ["movie:1", "movie:2", "movie:3"],
                                                            incoming: ["movie:1", "movie:3", "movie:2"]))
    }

    func testTailUnchangedForAnIdenticalList() {
        XCTAssertFalse(HeroCommitCoordinator.heroTailChanged(painted: ["movie:1", "movie:2"],
                                                             incoming: ["movie:1", "movie:2"]))
    }

    func testTailChangeIgnoredWhenTheHeadItselfMoved() {
        // A moved head is the `.newHead` path's business: it goes through prepare(), never through
        // the tail assignment, which would otherwise paint a new head with no prewarmed artwork.
        XCTAssertFalse(HeroCommitCoordinator.heroTailChanged(painted: ["movie:1", "movie:2"],
                                                             incoming: ["movie:9", "movie:2"]))
        XCTAssertFalse(HeroCommitCoordinator.heroTailChanged(painted: ["movie:1"], incoming: []))
    }

    func testTailChangeIgnoredBeforeAnythingIsPainted() {
        // Pre-commit, `heroItems` is empty. That is the first commit, not a tail edit.
        XCTAssertFalse(HeroCommitCoordinator.heroTailChanged(painted: [], incoming: ["movie:1", "movie:2"]))
        XCTAssertFalse(HeroCommitCoordinator.heroTailChanged(painted: [], incoming: []))
    }

    // MARK: - prepare(_:) art outcomes, via an injected stub fetcher

    /// Deterministic `HeroCommitArtworkFetching` stub: `neverResolvingURLs` sleep past
    /// `HeroCommitCoordinator.artTimeout` (Task.sleep responds to cancellation immediately, so this
    /// never hangs the test even though the coordinator's own budget is a real 1.5 s wait);
    /// `throwingURLs` fail fast; everything else resolves immediately from `images`.
    /// Codex r3 (P1/P2): one fetcher call, recorded in the order it was made, so
    /// "head art before any prefetch" is assertable.
    private enum FetcherCall: Equatable {
        case fetch(URL)
        case prefetch([URL])
    }

    @MainActor
    private final class StubFetcher: HeroCommitArtworkFetching {
        var images: [URL: UIImage] = [:]
        var throwingURLs: Set<URL> = []
        var neverResolvingURLs: Set<URL> = []
        /// Codex r3 (P1): URLs whose fetch parks indefinitely and IGNORES cancellation, the way
        /// `ArtworkStore.fetch` does (its shared work is unstructured on purpose, so a cancelled
        /// awaiter never shortens it). `releaseStalled()` resumes them at the end of the test, so
        /// nothing is leaked.
        var stallingURLs: Set<URL> = []
        private var stalled: [CheckedContinuation<UIImage, Error>] = []
        private(set) var prefetchedURLs: [URL] = []
        private(set) var calls: [FetcherCall] = []
        /// URLs whose fetch ran all the way to a decoded image. With the real fetcher this is the
        /// moment `ArtworkStore` caches it, so a URL that completes AFTER the deadline is the
        /// "late results are still stored" guarantee.
        private(set) var completedURLs: [URL] = []

        func cachedImage(_ url: URL?) -> UIImage? { nil }   // nothing pre-cached — always exercises fetchImage

        func fetchImage(_ url: URL) async throws -> UIImage {
            calls.append(.fetch(url))
            if stallingURLs.contains(url) {
                let image: UIImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
                    stalled.append(continuation)
                }
                completedURLs.append(url)
                return image
            }
            if neverResolvingURLs.contains(url) {
                // Deliberately longer than artTimeout, and cancellable, so a test that abandons
                // this fetch does not leave it running for the rest of the suite.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CancellationError()
            }
            if throwingURLs.contains(url) {
                throw URLError(.badServerResponse)
            }
            guard let image = images[url] else { throw URLError(.fileDoesNotExist) }
            completedURLs.append(url)
            return image
        }

        func prefetchImages(_ urls: [URL]) {
            prefetchedURLs.append(contentsOf: urls)
            calls.append(.prefetch(urls))
        }

        /// Lets every stalled fetch finish, as a late network response would.
        func releaseStalled(with image: UIImage = UIImage()) {
            let waiters = stalled
            stalled = []
            for waiter in waiters { waiter.resume(returning: image) }
        }
    }

    @MainActor
    func testPrepareReadyWhenArtworkResolvesInTime() async {
        let backdrop = URL(string: "https://example.com/banner.jpg")!
        let logo = URL(string: "https://example.com/logo.png")!
        let stub = StubFetcher()
        stub.images[backdrop] = UIImage()
        stub.images[logo] = UIImage()

        let coordinator = HeroCommitCoordinator(fetcher: stub)
        let state = makeState(heroItems: [makeItem(banner: backdrop.absoluteString, logo: logo.absoluteString)])

        let outcome = await coordinator.prepare(state)
        XCTAssertEqual(outcome, .ready(waitedMs: outcome.waitedMs))
        XCTAssertLessThan(outcome.waitedMs, 1_000, "should resolve almost immediately, well under the 1.5s budget")
    }

    @MainActor
    func testPrepareFailedWhenArtworkFetchThrowsWithinBudget() async {
        let backdrop = URL(string: "https://example.com/banner.jpg")!
        let logo = URL(string: "https://example.com/logo.png")!
        let stub = StubFetcher()
        stub.throwingURLs = [backdrop, logo]

        let coordinator = HeroCommitCoordinator(fetcher: stub)
        let state = makeState(heroItems: [makeItem(banner: backdrop.absoluteString, logo: logo.absoluteString)])

        let outcome = await coordinator.prepare(state)
        XCTAssertEqual(outcome, .failed(waitedMs: outcome.waitedMs))
        XCTAssertLessThan(outcome.waitedMs, 1_000, "both fetches fail fast — must not wait out the budget")
    }

    /// The one test explicitly asked for in the S1 brief: art timeout → `.timeout` after ~1.5 s.
    /// This genuinely waits out `HeroCommitCoordinator.artTimeout` (a real ~1.5 s), matching "with
    /// an injected stub fetcher" — no mock clock exists to fast-forward it.
    @MainActor
    func testPrepareTimesOutAfterArtTimeout() async {
        let backdrop = URL(string: "https://example.com/banner.jpg")!
        let logo = URL(string: "https://example.com/logo.png")!
        let stub = StubFetcher()
        stub.neverResolvingURLs = [backdrop, logo]

        let coordinator = HeroCommitCoordinator(fetcher: stub)
        let state = makeState(heroItems: [makeItem(banner: backdrop.absoluteString, logo: logo.absoluteString)])

        let started = Date()
        let outcome = await coordinator.prepare(state)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        XCTAssertEqual(outcome, .timeout(waitedMs: outcome.waitedMs))
        // "~1.5 s": allow generous scheduling slack either side rather than pinning to the exact ms.
        XCTAssertGreaterThanOrEqual(elapsedMs, 1_400)
        XCTAssertLessThan(elapsedMs, 3_000)
    }

    /// Codex r3 (P1), the deadline itself. The old task-group form could not enforce `artTimeout`:
    /// `group.cancelAll()` does not detach the group, which still awaits every child on the way
    /// out, and the children park inside `ArtworkStore.fetch` on shared work that ignores waiter
    /// cancellation. A fetch that never comes back therefore held the hero AND the rows blank for
    /// as long as the URLSession timeout, not 1.5 s. `stallingURLs` models exactly that fetch:
    /// without the fix this test does not fail, it hangs.
    @MainActor
    func testPrepareTimesOutEvenWhenAFetchNeverReturnsAndIgnoresCancellation() async {
        let backdrop = URL(string: "https://example.com/banner.jpg")!
        let logo = URL(string: "https://example.com/logo.png")!
        let stub = StubFetcher()
        stub.stallingURLs = [backdrop, logo]

        let coordinator = HeroCommitCoordinator(fetcher: stub)
        let state = makeState(heroItems: [makeItem(banner: backdrop.absoluteString, logo: logo.absoluteString)])

        let started = Date()
        let outcome = await coordinator.prepare(state)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        XCTAssertEqual(outcome, .timeout(waitedMs: outcome.waitedMs))
        XCTAssertGreaterThanOrEqual(elapsedMs, 1_400)
        // The budget plus scheduling slack. Deliberately not tighter: these unit tests share the
        // machine with a full Xcode build, and the bug this pins is unbounded (tens of seconds, or
        // forever), so any finite bound near the budget proves the deadline is real.
        XCTAssertLessThan(elapsedMs, 2_000)

        // And the abandoned fetches were left running rather than cancelled, so a late response
        // still lands in the cache (with the real fetcher, in `ArtworkStore`) for the resolver.
        stub.releaseStalled()
        // beta.18 gate run: a single `Task.yield()` is not enough for both released continuations to
        // land on a loaded machine (seen 1 of 2 runs during the Phase 1 gate), and the assertion is
        // about WHETHER they land, not how fast. Poll briefly instead of racing the scheduler.
        for _ in 0..<50 where Set(stub.completedURLs) != [backdrop, logo] {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Set(stub.completedURLs), [backdrop, logo])
    }

    /// Codex r3 (P2), admission order. Both the head's own artwork and the bulk prefetches go
    /// through `ArtworkStore`'s six-slot gate; a cold Home queues up to 28 row posters plus 14
    /// carousel images, so issuing those first parked the one image the commit actually waits on
    /// behind dozens of fire-and-forget requests.
    @MainActor
    func testPrepareRequestsHeadArtBeforeAnyPrefetch() async {
        let headBackdrop = URL(string: "https://example.com/head-banner.jpg")!
        let headLogo = URL(string: "https://example.com/head-logo.png")!
        let nextBackdrop = URL(string: "https://example.com/next-banner.jpg")!
        let nextLogo = URL(string: "https://example.com/next-logo.png")!
        let stub = StubFetcher()
        stub.images[headBackdrop] = UIImage()
        stub.images[headLogo] = UIImage()

        let coordinator = HeroCommitCoordinator(fetcher: stub)
        let state = makeState(heroItems: [
            makeItem(id: "1", banner: headBackdrop.absoluteString, logo: headLogo.absoluteString),
            makeItem(id: "2", banner: nextBackdrop.absoluteString, logo: nextLogo.absoluteString)
        ])

        let outcome = await coordinator.prepare(state)
        XCTAssertEqual(outcome, .ready(waitedMs: outcome.waitedMs))
        // The prefetch rides a follow-up main-actor turn; give it one in case it has not run yet.
        await Task.yield()

        let firstPrefetch = stub.calls.firstIndex { call in
            if case .prefetch = call { return true }
            return false
        }
        XCTAssertNotNil(firstPrefetch, "the carousel's remaining artwork is still prefetched")
        XCTAssertEqual(Array(stub.calls.prefix(2)), [.fetch(headBackdrop), .fetch(headLogo)],
                       "the head's backdrop and logo are the first two requests")
        if let firstPrefetch {
            XCTAssertGreaterThan(firstPrefetch, 1, "no prefetch is issued before the head's own art")
        }
        XCTAssertEqual(stub.prefetchedURLs, [nextBackdrop, nextLogo])
    }

    @MainActor
    func testPrepareReadyImmediatelyWithEmptyHeroItems() async {
        let coordinator = HeroCommitCoordinator(fetcher: StubFetcher())
        let outcome = await coordinator.prepare(makeState(heroItems: []))
        XCTAssertEqual(outcome, .ready(waitedMs: 0))
    }

    /// Codex r1 (P1), the root of "the cancelled hero commit repaints the empty state".
    ///
    /// `prepare(_:)` treats cancellation as a reason to stop WAITING, not as a failure: its task
    /// group breaks out of the arrival loop and it returns a perfectly ordinary outcome. So a
    /// continuation that guards only on `heroCommitGeneration` still runs after
    /// `pendingHeroCommitTask.cancel()`, and `HomeViewModel.homeWatcher`'s `.noHero` route, which
    /// cancels a pending prepare when Show Hero goes off or the head's source disappears, has to
    /// BUMP the generation (and the continuation has to check `Task.isCancelled`) rather than rely
    /// on the cancel alone. This test pins the behaviour that makes both necessary.
    @MainActor
    func testPrepareReturnsNormallyAfterCancellationSoCancelAloneCannotGateTheCommit() async {
        let backdrop = URL(string: "https://example.com/banner.jpg")!
        let logo = URL(string: "https://example.com/logo.png")!
        let stub = StubFetcher()
        stub.neverResolvingURLs = [backdrop, logo]

        let coordinator = HeroCommitCoordinator(fetcher: stub)
        let state = makeState(heroItems: [makeItem(banner: backdrop.absoluteString, logo: logo.absoluteString)])

        // A `Task<HeroCommitArtOutcome?, Never>` standing in for `pendingHeroCommitTask`: it reports
        // both what prepare returned AND whether the task was cancelled by the time it landed.
        let started = Date()
        let task = Task { @MainActor () async -> (HeroCommitArtOutcome, Bool) in
            let outcome = await coordinator.prepare(state)
            return (outcome, Task.isCancelled)
        }
        // Let prepare get into its wait, then cancel exactly as the `.noHero` route does.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let (outcome, cancelled) = await task.value
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        XCTAssertTrue(cancelled, "the stand-in for pendingHeroCommitTask really was cancelled")
        // It came back EARLY (nothing resolved, and it did not sit out the full 1.5s budget) and,
        // crucially, came back with a normal outcome rather than propagating the cancellation.
        XCTAssertLessThan(elapsedMs, 1_400, "cancellation must cut the art wait short")
        XCTAssertEqual(outcome, .failed(waitedMs: outcome.waitedMs))
    }

    // MARK: - Rows gate (Codex r2, P1)
    //
    // The hero gate held `heroItems`/`sections`, but `HomeViewModel`'s collections and
    // catalog-settings watchers rebuilt the rows on their own, so the launch sync burst's freshly
    // pulled ordering could repaint and reorder the rows before the hero committed. `RowsGate`
    // (`Screens/HomeHeroCommit.swift`) is the pure decision that funnel now goes through.

    func testRowsGateHoldsEveryRequestWhileClosed() {
        var gate = RowsGate()
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.request(), .hold)
        XCTAssertEqual(gate.request(), .hold)
        XCTAssertTrue(gate.pendingRebuild, "a held request must record that a rebuild is owed")
        XCTAssertEqual(gate.heldRebuilds, 2)
        XCTAssertFalse(gate.isOpen, "requesting must never open the gate")
    }

    func testRowsGateOpenCoalescesHeldRequestsIntoOneRebuild() {
        var gate = RowsGate()
        for _ in 0..<5 { _ = gate.request() }
        // `open()` reports the held count once, for the `heldRebuilds=` probe field; the caller
        // performs exactly ONE rebuild afterwards, reading the latest sections/collections/settings.
        XCTAssertEqual(gate.open(), 5)
        XCTAssertTrue(gate.isOpen)
        XCTAssertFalse(gate.pendingRebuild, "the single rebuild on open discharges every held one")
        XCTAssertEqual(gate.heldRebuilds, 0)
    }

    func testRowsGateOpenReportsZeroWhenNothingWasHeld() {
        // The commit publish is itself a row change (it is the publish that first assigns
        // `sections`), so the caller rebuilds on open whether or not anything was held.
        var gate = RowsGate()
        XCTAssertEqual(gate.open(), 0)
        XCTAssertTrue(gate.isOpen)
    }

    func testRowsGateSecondOpenIsIdempotentAndReportsNothing() {
        // `.noHero` can fire on every released empty publish. Only the first one stamps
        // `heldRebuilds=` on a probe line; the rest must not re-report or re-arm anything.
        var gate = RowsGate()
        _ = gate.request()
        XCTAssertEqual(gate.open(), 1)
        XCTAssertNil(gate.open(), "an already-open gate reports no held count")
        XCTAssertNil(gate.open())
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.heldRebuilds, 0)
    }

    func testRowsGateRebuildsNormallyAfterOpening() {
        // Post-commit reorders are allowed by design: the burst simulator asserts relative order is
        // preserved, not that rows never move.
        var gate = RowsGate()
        _ = gate.open()
        XCTAssertEqual(gate.request(), .rebuild)
        XCTAssertEqual(gate.request(), .rebuild)
        XCTAssertFalse(gate.pendingRebuild, "an open gate never accrues pending work")
        XCTAssertEqual(gate.heldRebuilds, 0)
    }

    func testRowsGateResetClosesItAgainForTheNextProfile() {
        // `HomeViewModel.stop()` (profile switch / sign-out) resets it alongside the coordinator:
        // the next profile's rows are gated afresh rather than inheriting an open gate.
        var gate = RowsGate()
        _ = gate.request()
        _ = gate.open()
        _ = gate.request()
        gate.reset()
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.pendingRebuild)
        XCTAssertEqual(gate.heldRebuilds, 0)
        XCTAssertEqual(gate.request(), .hold, "a reset gate holds again")
    }

    // MARK: - Teardown resets the hero-commit state (internal review r1, P2)

    /// The bug, at the only seam a unit test can reach. `HomeViewModel.teardownPipeline()` used to
    /// bump `pipelineGeneration` and nothing else, so an in-flight `prepare()` continuation failed
    /// its generation guard and returned WITHOUT clearing the pending bookkeeping. The next
    /// `acquire()`'s first released publish for the same head then found a non-nil task plus a
    /// matching key and hash and routed `.absorb` - forever, because no task was really in flight
    /// to commit and clear it. `resetHeroCommitState()` (now run by `teardownPipeline()` as well as
    /// by `stop()`) clears exactly the three inputs this route reads.
    func testPendingRouteRestartsOnceATeardownClearedTheStaleBookkeeping() {
        // Before the fix: teardown left all three inputs standing, so the first publish of the
        // NEXT pipeline run for the same head was swallowed.
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: "movie:1", pendingHeadHash: "abc",
                                          hasPendingTask: true, headKey: "movie:1", headHash: "abc"),
            .absorb,
            "the stale-bookkeeping shape a teardown used to leave behind"
        )
        // After the fix: the task is cancelled and nil'd and both key fields are cleared, so the
        // same publish starts a fresh prepare.
        XCTAssertEqual(
            HeroPendingCommitRoute.decide(pendingHeadKey: nil, pendingHeadHash: nil,
                                          hasPendingTask: false, headKey: "movie:1", headHash: "abc"),
            .restart
        )
    }

    @MainActor
    func testTeardownResetsTheCoordinatorAndRegatesTheRowsForTheNextRun() {
        // The rest of `resetHeroCommitState()`, on the two collaborators it touches.
        let coordinator = HeroCommitCoordinator()
        var gate = RowsGate()
        _ = coordinator.evaluateHeadChange(headKey: "movie:1", headHash: "abc")
        coordinator.commit(headKey: "movie:1", headHash: "abc")
        _ = gate.open()
        XCTAssertEqual(coordinator.evaluateHeadChange(headKey: "movie:1", headHash: "abc"), .sameHeadSameHash)
        XCTAssertTrue(gate.isOpen)

        // The teardown.
        coordinator.reset()
        gate.reset()

        // The next run re-decides the head from scratch (so it prepares, commits, and opens the
        // rows) instead of inheriting a committed identity plus an already-open gate, which is the
        // combination that let rows rebuild under a hero that had not committed.
        XCTAssertEqual(coordinator.evaluateHeadChange(headKey: "movie:1", headHash: "abc"), .newHead)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.request(), .hold)
    }

    // MARK: - `same=1` contract: a VISIBLE repaint at a stable identity (internal review r1, P2)

    private func makePreview(name: String = "Movie", description: String? = nil,
                             releaseInfo: String? = nil, genres: [String] = []) -> MetaPreview {
        MetaPreview(
            id: "1", type: "movie", name: name,
            poster: nil, banner: nil, logo: nil,
            posterShape: .poster,
            description: description, releaseInfo: releaseInfo, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: genres
        )
    }

    @MainActor
    func testVisibleRepaintFlagsTextThatWasREPLACEDAtAStableIdentity() {
        // The tester's filmed shape: an already-readable synopsis swapped for another language's.
        XCTAssertTrue(HeroArtResolver.isVisibleRepaint(
            current: makePreview(description: "An English synopsis."),
            target: makePreview(description: "Un synopsis en francais.")))
        // The wordmark slot renders `item.name` whenever no logo bitmap resolved.
        XCTAssertTrue(HeroArtResolver.isVisibleRepaint(
            current: makePreview(name: "The Movie"),
            target: makePreview(name: "Le Film")))
        // Both halves of the meta line.
        XCTAssertTrue(HeroArtResolver.isVisibleRepaint(
            current: makePreview(releaseInfo: "2019"),
            target: makePreview(releaseInfo: "2020")))
        XCTAssertTrue(HeroArtResolver.isVisibleRepaint(
            current: makePreview(genres: ["Action"]),
            target: makePreview(genres: ["Comedy"])))
    }

    @MainActor
    func testVisibleRepaintStaysSilentForTheAllowedGapFill() {
        // The ONE change the commit protocol allows after a hero is on screen: a field the item was
        // committed WITHOUT being filled in. It adds text, it replaces nothing, and it must not
        // read as a repaint - logging it as `same=1` is what made a healthy launch look broken.
        XCTAssertFalse(HeroArtResolver.isVisibleRepaint(
            current: makePreview(description: nil),
            target: makePreview(description: "A synopsis landing from TMDB.")))
        XCTAssertFalse(HeroArtResolver.isVisibleRepaint(
            current: makePreview(description: ""),
            target: makePreview(description: "A synopsis landing from TMDB.")))
        XCTAssertFalse(HeroArtResolver.isVisibleRepaint(
            current: makePreview(releaseInfo: nil),
            target: makePreview(releaseInfo: "2020")))
        XCTAssertFalse(HeroArtResolver.isVisibleRepaint(
            current: makePreview(genres: []),
            target: makePreview(genres: ["Action", "Comedy"])))
    }

    @MainActor
    func testVisibleRepaintIgnoresChangesThatNeverReachTheScreen() {
        // Byte-identical payload.
        XCTAssertFalse(HeroArtResolver.isVisibleRepaint(
            current: makePreview(description: "Same", releaseInfo: "2020", genres: ["Action"]),
            target: makePreview(description: "Same", releaseInfo: "2020", genres: ["Action"])))
        // Only the first three genres ever reach the meta line, so a fourth arriving paints nothing.
        XCTAssertFalse(HeroArtResolver.isVisibleRepaint(
            current: makePreview(genres: ["Action", "Comedy", "Drama"]),
            target: makePreview(genres: ["Action", "Comedy", "Drama", "Thriller"])))
        // A field going from set to EMPTY is not a gap-fill - the meta line visibly loses a
        // component - so it stays a repaint.
        XCTAssertTrue(HeroArtResolver.isVisibleRepaint(
            current: makePreview(releaseInfo: "2020"),
            target: makePreview(releaseInfo: nil)))
    }
}
