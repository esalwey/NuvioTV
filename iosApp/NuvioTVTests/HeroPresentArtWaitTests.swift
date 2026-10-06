import XCTest
@testable import NuvioTV
import UIKit

/// Unit tests for `HeroPresentArtWait` (`Screens/HomeView.swift`, round 3), the wait state behind
/// `HeroArtResolver.present(_:isFolder:)`. It replaced a `withTaskGroup` whose deadline child could
/// not actually bound the resolve: a group awaits every child on the way out even after
/// `cancelAll()`, and `ArtworkStore.fetch` parks on shared unstructured work that ignores waiter
/// cancellation by design, so a stalled backdrop deferred the hero PRESENTATION by the URLSession
/// timeout rather than by 400 ms.
///
/// The state machine is the only part of the resolve that is testable without a live view and a
/// network: `present` reaches `ArtworkStore.fetch` through a static, so there is no injection seam
/// for the fetch itself. The wiring around it (fetch tasks issued unstructured, deadline task
/// cancelled after the park, identity guard before the commit) stays covered by test20 and test31.
///
/// Every case drives the class the same way `present` does: attach a continuation, let a terminal
/// event resume it, then read what the commit would paint.
final class HeroPresentArtWaitTests: XCTestCase {

    /// Distinct 1x1 bitmaps. `HeroPresentation` compares images by REFERENCE (one decoded instance
    /// per URL out of `ArtworkStore`), so these assertions use `===` too.
    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @MainActor
    func testStalledBackdropResumesAtTheDeadlineWithTheCachedLogo() async {
        let cachedLogo = makeImage()
        // The shape of a cold hero swap: logo already resident, backdrop cold and then stalled.
        let wait = HeroPresentArtWait(backdrop: nil, logo: cachedLogo,
                                      needsBackdrop: true, needsLogo: false)

        // Same construction as `present`, with a short stand-in for `laterSwapDeadline`. No fetch
        // task at all here: that IS the stall, and the point is that it cannot hold the wait open.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            wait.deadlineElapsed()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }
        deadline.cancel()

        XCTAssertTrue(wait.hitDeadline, "the budget, not a fetch, ended this wait")
        XCTAssertNil(wait.backdrop, "nothing landed, so the commit paints no backdrop")
        XCTAssertTrue(wait.logo === cachedLogo, "the cached logo is committed, not a text wordmark")

        // The stalled fetch is never cancelled, so it still reports. By then its item has been
        // presented, and swapping art in behind the reader's eyes is the repaint BUG-90 removed.
        let lateBackdrop = makeImage()
        wait.resolveBackdrop(lateBackdrop)
        XCTAssertNil(wait.backdrop, "a backdrop that lands after the deadline is dropped")
        XCTAssertTrue(wait.logo === cachedLogo)
    }

    /// 2026-09-08 finding: the deadline hand-off race. `deadlineElapsed()` finishes the wait first,
    /// and only THEN does the stalled fetch resolve — the ordinary shape of the miss this class
    /// exists to survive. `resolveBackdrop` still drops the image from THIS wait's own `backdrop`
    /// (the assertion above already pins that), but it must no longer be lost outright: `present`'s
    /// resolve task reads it back one turn later via `lateBackdrop` to adopt it onto the live hero.
    @MainActor
    func testDeadlineThenLateBackdropIsRetainedForAdoption() {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false)
        wait.deadlineElapsed()
        XCTAssertTrue(wait.hitDeadline)
        XCTAssertNil(wait.backdrop, "the deadline already committed with nothing to show")

        let image = makeImage()
        wait.resolveBackdrop(image)
        XCTAssertNil(wait.backdrop, "still dropped from THIS wait's own commit — existing contract")
        XCTAssertTrue(wait.lateBackdrop === image, "but retained for the resolve task to adopt")
    }

    /// The other half of the same guard: a wait that ended via `cancelWait()` (a superseded
    /// `present`, not a timeout) must not retain anything. There is no resolve task left that would
    /// ever read `lateBackdrop` back, and retaining an image here would be silently pointless at
    /// best and a stale reference at worst.
    @MainActor
    func testCancelledWaitNeverRetainsALateBackdrop() {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: true)
        wait.cancelWait()
        XCTAssertFalse(wait.hitDeadline, "cancellation is not a timeout")

        wait.resolveBackdrop(makeImage())
        XCTAssertNil(wait.lateBackdrop, "a superseded resolve has nothing waiting to adopt it")
    }

    @MainActor
    func testBothFetchesLandingResumeBeforeTheDeadlineIsEverConsulted() async {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: true)
        let backdrop = makeImage()
        let logo = makeImage()

        // Both settle first, so the continuation is already spent when `attach` runs. `attach` must
        // resume it on the spot rather than parking forever.
        wait.resolveBackdrop(backdrop)
        wait.resolveLogo(logo)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline, "both pieces landed inside the budget")
        XCTAssertTrue(wait.backdrop === backdrop)
        XCTAssertTrue(wait.logo === logo)
    }

    @MainActor
    func testEmptyFetchResultLeavesTheCachedImageInPlace() async {
        let cachedBackdrop = makeImage()
        let wait = HeroPresentArtWait(backdrop: cachedBackdrop, logo: nil,
                                      needsBackdrop: true, needsLogo: false)

        // `try? await ArtworkStore.fetch(...)` hands back nil on a 404 or a decode failure. That
        // must not blank art the resolver already had.
        wait.resolveBackdrop(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline)
        XCTAssertTrue(wait.backdrop === cachedBackdrop)
        XCTAssertNil(wait.logo, "no logo means the hero draws its text wordmark")
    }

    @MainActor
    func testCancelWaitResumesWithoutClaimingTheDeadlineFired() async {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: true)

        // A superseded `present` cancels the resolve task; its cancellation handler calls this.
        Task { @MainActor in wait.cancelWait() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline, "cancellation is not a timeout")
        XCTAssertNil(wait.backdrop)
        XCTAssertNil(wait.logo)

        // The resolver's identity guard is what blocks the commit, but a cancelled wait must also
        // stop accepting arrivals so nothing can revive it.
        wait.resolveLogo(makeImage())
        XCTAssertNil(wait.logo)
    }

    // MARK: - FEAT-42: a late logo is dropped exactly like a late backdrop's OWN wait is dropped
    //
    // (the `adoptLateBackdrop` retention on the resolver side is a backdrop-only concern, argued
    // in that method's own doc comment; a logo gets no such retention on either side — see
    // `HeroLogoPlanTests` and the FEAT-42 task doc for why a late-arriving logo for an
    // already-presented item stays dropped, the same BUG-90 rule this class has always enforced
    // for the backdrop's raw miss.)

    @MainActor
    func testLogoThatLandsAfterTheDeadlineIsDropped() async {
        let cachedBackdrop = makeImage()
        // The shape of a `.pending` FEAT-42 resolve gone cold: backdrop already resident, logo
        // still waiting on `TitleLogoStore` when the budget expires.
        let wait = HeroPresentArtWait(backdrop: cachedBackdrop, logo: nil,
                                      needsBackdrop: false, needsLogo: true)

        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            wait.deadlineElapsed()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }
        deadline.cancel()

        XCTAssertTrue(wait.hitDeadline, "the budget, not the lookup/fetch, ended this wait")
        XCTAssertNil(wait.logo, "nothing landed in time, so the commit paints the text wordmark")
        XCTAssertTrue(wait.backdrop === cachedBackdrop, "the already-resident backdrop is untouched")

        // The `TitleLogoStore.awaitLogoURL` → `ArtworkStore.fetch` chain is never cancelled by the
        // deadline (same contract as the backdrop's own stalled fetch), so it still reports here.
        // By then the item has been presented with the text wordmark; swapping a logo in behind
        // the reader's eyes is exactly the Text→Image repaint BUG-90 removed.
        let lateLogo = makeImage()
        wait.resolveLogo(lateLogo)
        XCTAssertNil(wait.logo, "a logo that lands after the deadline is dropped, not adopted")
        XCTAssertTrue(wait.backdrop === cachedBackdrop)
    }

    // MARK: - Poster fallback (Codex branch review)
    //
    // `heroBackdropURL(for:)` synthesizes a metahub background URL for any IMDb-backed item with no
    // `banner`, and that URL 404s for plenty of real titles. Before this, the resolver committed a
    // nil backdrop for those items and the hero went out blank even though the poster was on the
    // card below. The poster now stands in, but only for a primary that did NOT land, and only for
    // TITLE heroes. A folder's cover as a fallback is a separate, filmed bug, and the resolver
    // never hands one to this class.

    @MainActor
    func testPrimaryMissCommitsTheCachedPosterImmediately() async {
        let cachedPoster = makeImage()
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false,
                                      posterFallback: cachedPoster, needsPosterFallback: false)

        // The 404. Nothing else is outstanding, so this settles the wait on the spot: no deadline
        // task is ever consulted.
        wait.resolveBackdrop(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline, "a warm poster costs the commit no wait at all")
        XCTAssertTrue(wait.backdrop === cachedPoster, "the poster stands in for the missing primary")
        XCTAssertTrue(wait.usedPosterFallback, "the probe line must read backdrop=poster")
    }

    @MainActor
    func testPrimaryMissWaitsForAPosterFetchInsideTheSameBudget() async {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false,
                                      posterFallback: nil, needsPosterFallback: true)
        let fetchedPoster = makeImage()

        // The primary misses first and the poster is still in flight, so the wait must stay open
        // for it rather than settling on a nil backdrop.
        wait.resolveBackdrop(nil)
        XCTAssertNil(wait.backdrop, "still waiting on the poster, nothing to paint yet")

        wait.resolvePosterFallback(fetchedPoster)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline, "the poster landed inside the budget")
        XCTAssertTrue(wait.backdrop === fetchedPoster)
        XCTAssertTrue(wait.usedPosterFallback)
    }

    @MainActor
    func testPrimaryMissWithNoPosterAtAllStillCommits() async {
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false,
                                      posterFallback: nil, needsPosterFallback: true)

        // Both candidates 404: the hero commits with no backdrop, exactly as it did before the
        // fallback existed. The point is that the poster's failure cannot hold the wait open.
        wait.resolveBackdrop(nil)
        wait.resolvePosterFallback(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertFalse(wait.hitDeadline)
        XCTAssertNil(wait.backdrop)
        XCTAssertFalse(wait.usedPosterFallback, "backdrop=none, not backdrop=poster")
    }

    @MainActor
    func testLandedPrimaryIsNeverReplacedByThePoster() async {
        let primary = makeImage()
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false,
                                      posterFallback: nil, needsPosterFallback: true)

        // The primary wins, so the concurrent poster fetch is irrelevant the moment it lands, and
        // must not hold the wait open either.
        wait.resolveBackdrop(primary)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertTrue(wait.backdrop === primary)
        XCTAssertFalse(wait.usedPosterFallback)

        wait.resolvePosterFallback(makeImage())
        XCTAssertTrue(wait.backdrop === primary, "a fallback never displaces a primary that landed")
        XCTAssertFalse(wait.usedPosterFallback)
    }

    @MainActor
    func testStalledPrimaryCommitsTheCachedPosterAtTheDeadlineAndDropsTheLatePrimary() async {
        let cachedPoster = makeImage()
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false,
                                      posterFallback: cachedPoster, needsPosterFallback: false)

        // No `resolveBackdrop` at all: the primary is hung on a slow host. A warm poster does NOT
        // shortcut the budget: the primary is still preferred right up to the deadline.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            wait.deadlineElapsed()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }
        deadline.cancel()

        XCTAssertTrue(wait.hitDeadline, "the budget ended this wait, not a fetch")
        XCTAssertTrue(wait.backdrop === cachedPoster, "the poster stands in rather than a blank hero")
        XCTAssertTrue(wait.usedPosterFallback)

        // Same rule as the late logo: the item has been presented, and swapping the primary in
        // behind the reader's eyes is the repaint the commit protocol exists to remove.
        wait.resolveBackdrop(makeImage())
        XCTAssertTrue(wait.backdrop === cachedPoster, "a primary that lands after the deadline is dropped")
    }

    @MainActor
    func testFolderTargetNeverConsultsAPoster() async {
        // The resolver gates the poster on `!isFolder && !isCollectionHero(target)`, so a folder's
        // wait is constructed with no fallback and no pending fetch. Painting a folder's square
        // cover into the 16:9 hero and then replacing it is the "background pops in larger then
        // shrinks" regression (Wave H hole H2); `folderHeroPreview` passes `poster: nil` for the
        // same reason. This pins the state machine's half of that contract: with no fallback
        // supplied there is no path, on either the miss or the deadline, that produces one.
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: true, needsLogo: false)

        wait.resolveBackdrop(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.attach(continuation)
        }

        XCTAssertNil(wait.backdrop, "a folder hero holds a blank primary rather than showing its cover")
        XCTAssertFalse(wait.usedPosterFallback)

        // And a late `resolvePosterFallback`, which the resolver never issues for a folder, cannot
        // sneak one in after the fact either.
        wait.resolvePosterFallback(makeImage())
        XCTAssertNil(wait.backdrop)
        XCTAssertFalse(wait.usedPosterFallback)
    }

    // MARK: - resolveDeadline (rc12, Codex Finding A)
    //
    // The budget belongs to the TARGET, not to a resolve. `present` is driven from two `.onChange`s
    // and a same-identity payload update (a synopsis landing from TMDB) cancels the resolve in
    // flight and starts another; the same-identity short-circuit further up only protects a title
    // that is already PRESENTED, so before this each such update handed the new resolve a whole
    // fresh `laterSwapDeadline`. Codex measured an update at 300 ms holding the PREVIOUS title on
    // screen to 496 ms, where the pre-rc12 warm-backdrop case committed at once. `resolveDeadline`
    // is the pure remainder: nonisolated and store-free, so the rule can be pinned with no view,
    // no network and no clock of its own.

    // `laterSwapDeadline` is a static on a `@MainActor` type, so the case reads it from the
    // main actor the way every other case in this file runs; `resolveDeadline` itself is
    // `nonisolated static` and pure.
    @MainActor
    func testAFirstPresentForATargetGetsTheWholeBudget() {
        let deadline = HeroArtResolver.resolveDeadline(previousStart: nil, now: Date(),
                                                      budget: HeroArtResolver.laterSwapDeadline)
        XCTAssertEqual(deadline, HeroArtResolver.laterSwapDeadline,
                       "a genuinely new target has no clock to inherit — it must get the full 400 ms")
    }

    // `laterSwapDeadline` is a static on a `@MainActor` type, so the case reads it from the
    // main actor the way every other case in this file runs; `resolveDeadline` itself is
    // `nonisolated static` and pure.
    @MainActor
    func testASameTargetUpdateInheritsTheRemainderOfTheOriginalBudget() {
        let start = Date()
        // The measured case: a metadata update 300 ms into a 400 ms budget.
        let deadline = HeroArtResolver.resolveDeadline(previousStart: start,
                                                      now: start.addingTimeInterval(0.3),
                                                      budget: HeroArtResolver.laterSwapDeadline)
        // 100 ms left, ±1 ms for the Double round trip through TimeInterval.
        XCTAssertEqual(Double(deadline), 100_000_000, accuracy: 1_000_000,
                       "the restarted resolve must finish the ORIGINAL window, not open a second one")
        XCTAssertLessThan(deadline, HeroArtResolver.laterSwapDeadline,
                          "two stacked budgets is exactly the 496 ms hold this rule removes")
    }

    // `laterSwapDeadline` is a static on a `@MainActor` type, so the case reads it from the
    // main actor the way every other case in this file runs; `resolveDeadline` itself is
    // `nonisolated static` and pure.
    @MainActor
    func testAnUpdateAfterTheBudgetIsSpentCommitsImmediately() {
        let start = Date()
        let deadline = HeroArtResolver.resolveDeadline(previousStart: start,
                                                      now: start.addingTimeInterval(0.6),
                                                      budget: HeroArtResolver.laterSwapDeadline)
        XCTAssertEqual(deadline, 0,
                       "past the absolute deadline the wait must fire on the next turn and commit whatever is ready")
    }

    // `laterSwapDeadline` is a static on a `@MainActor` type, so the case reads it from the
    // main actor the way every other case in this file runs; `resolveDeadline` itself is
    // `nonisolated static` and pure.
    @MainActor
    func testTheFolderBudgetIsInheritedTheSameWay() {
        let start = Date()
        let budget: UInt64 = 1_500_000_000
        let deadline = HeroArtResolver.resolveDeadline(previousStart: start,
                                                      now: start.addingTimeInterval(0.5),
                                                      budget: budget)
        XCTAssertEqual(Double(deadline), 1_000_000_000, accuracy: 1_000_000,
                       "a collection folder's longer budget is absolute in the same way — the rule is the caller's constant, not a second constant of its own")
    }

    // `laterSwapDeadline` is a static on a `@MainActor` type, so the case reads it from the
    // main actor the way every other case in this file runs; `resolveDeadline` itself is
    // `nonisolated static` and pure.
    @MainActor
    func testAClockThatMovedBackwardsFallsBackToTheWholeBudget() {
        let start = Date()
        let deadline = HeroArtResolver.resolveDeadline(previousStart: start,
                                                      now: start.addingTimeInterval(-5),
                                                      budget: HeroArtResolver.laterSwapDeadline)
        XCTAssertEqual(deadline, HeroArtResolver.laterSwapDeadline,
                       "a negative elapsed must never become a longer-than-budget wait (or an overflowing UInt64)")
    }

    // `laterSwapDeadline` is a static on a `@MainActor` type, so the case reads it from the
    // main actor the way every other case in this file runs; `resolveDeadline` itself is
    // `nonisolated static` and pure.
    @MainActor
    func testTheInheritedDeadlineIsMonotonicInElapsedTime() {
        let start = Date()
        var previous = HeroArtResolver.laterSwapDeadline + 1
        for ms in [0, 50, 100, 200, 399, 400, 401, 10_000] {
            let deadline = HeroArtResolver.resolveDeadline(
                previousStart: start, now: start.addingTimeInterval(Double(ms) / 1000),
                budget: HeroArtResolver.laterSwapDeadline
            )
            XCTAssertLessThanOrEqual(deadline, previous, "the remainder must never grow as time passes (at \(ms) ms)")
            XCTAssertLessThanOrEqual(deadline, HeroArtResolver.laterSwapDeadline, "and never exceed the budget (at \(ms) ms)")
            previous = deadline
        }
        XCTAssertEqual(previous, 0, "well past the window the remainder is spent")
    }
}
