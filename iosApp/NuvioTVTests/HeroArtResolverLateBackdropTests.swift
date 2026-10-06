import XCTest
@testable import NuvioTV
import UIKit

/// Unit tests for `HeroArtResolver.shouldAdoptLateBackdrop` (`Screens/HomeView.swift`), the pure
/// predicate behind `adoptLateBackdrop`.
///
/// 2026-09-08 finding (simulator rig, the tester's real collections): when Home focus lands on a
/// collection folder, `HeroArtResolver.present(_:isFolder:)` waits up to `folderDeadline` (1.5 s)
/// for the folder's backdrop; on a cold cache the fetch routinely misses that deadline, so the
/// probe logs `present item=nuvio.folder:… backdrop=none logo=text waited=1509` and the hero
/// commits with NO backdrop — `folderHeroPreview` passes `poster: nil`, so unlike a title hero
/// there is no stand-in, and the screen just stays blank. The backdrop fetch is never cancelled
/// (round 3's design) and lands in `ArtworkStore` regardless; `adoptLateBackdrop` is where that
/// late image gets painted onto the CURRENT hero instead of being wasted.
///
/// `adoptLateBackdrop` itself cannot be driven from here: it is `private`, and the resolver's own
/// test file documents why `present` has no injection seam for `ArtworkStore.fetch` — there is no
/// way to make a fetch land deterministically AFTER a real 400 ms/1.5 s deadline in a unit test
/// without either touching `ArtworkStore` (outside this task's ownership) or a live view. So, per
/// the fallback this task specifies, only the pure guard logic is exercised here — the same
/// treatment `isVisibleRepaint` got in `HeroCommitCoordinatorTests` for the same reason. The
/// non-pure half (the fetch-task wiring that calls `adoptLateBackdrop` with a genuinely late
/// image) stays covered the way the rest of `present`'s wiring already is: by test20/test31/Leg C
/// on device/simulator, plus `HeroPresentArtWaitTests.testStalledBackdropResumesAtTheDeadlineWithTheCachedLogo`,
/// which already pins that a backdrop landing after `deadlineElapsed()` is dropped BY THE WAIT
/// OBJECT for `wait.backdrop` itself — i.e. that the fetch closure's own `adoptLateBackdrop` call
/// reads the late image off its own local, not off `wait.backdrop` (which stays nil). A second
/// finding the same day (the deadline hand-off race, where the image arrives between
/// `deadlineElapsed()` and the resolve task's own commit) added `wait.lateBackdrop`, retaining
/// that same dropped image for one more read from the resolve task itself; see
/// `testDeadlineThenLateBackdropIsRetainedForAdoption` and
/// `testCancelledWaitNeverRetainsALateBackdrop` in that same test file.
final class HeroArtResolverLateBackdropTests: XCTestCase {

    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// The shape the finding describes: a folder committed with no backdrop (deadline miss), the
    /// late fetch is for the SAME identity that is still on screen, and no newer resolve has
    /// started. This is the one case the whole method exists to handle.
    func testAdoptsWhenTheLivePresentationHasNoBackdropAtAll() {
        XCTAssertTrue(HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: "nuvio.folder:abc",
            presentedIdentity: "nuvio.folder:abc",
            presentedBackdrop: nil,
            resolveTaskIsNil: true,
            identity: "nuvio.folder:abc"))
    }

    /// The whole safety argument (BUG-42/BUG-90's no-double-commit rule): a hero that already has
    /// ANY bitmap on screen — a title's primary, a title's poster stand-in, or a folder's own
    /// earlier-landed backdrop — must never have it swapped out from under the viewer by a late
    /// arrival. This is the guard that must never be relaxed.
    func testNeverReplacesANonNilPresentedBackdrop() {
        XCTAssertFalse(HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: "nuvio.folder:abc",
            presentedIdentity: "nuvio.folder:abc",
            presentedBackdrop: makeImage(),
            resolveTaskIsNil: true,
            identity: "nuvio.folder:abc"))
    }

    /// A poster stand-in counts as "art already on screen" too, even though it is not the item's
    /// own primary backdrop — the late fetch must not paint over it either.
    func testNeverReplacesAPosterStandIn() {
        XCTAssertFalse(HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: "movie:1",
            presentedIdentity: "movie:1",
            presentedBackdrop: makeImage(), // stands in for a poster fallback bitmap
            resolveTaskIsNil: true,
            identity: "movie:1"))
    }

    /// The viewer has navigated to a different hero since this fetch started: `present` moved
    /// `targetIdentity` on. The late image belongs to nothing on screen any more.
    func testDoesNotAdoptWhenANewerPresentHasSupersededTheTarget() {
        XCTAssertFalse(HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: "nuvio.folder:xyz",
            presentedIdentity: "nuvio.folder:abc",
            presentedBackdrop: nil,
            resolveTaskIsNil: true,
            identity: "nuvio.folder:abc"))
    }

    /// `presented` has already moved past this identity (e.g. the same-identity refresh path
    /// replaced it, or focus round-tripped back to a different item) even though `targetIdentity`
    /// has not yet been reassigned. Belt-and-braces alongside the `targetIdentity` check.
    func testDoesNotAdoptWhenThePresentedIdentityHasMovedOn() {
        XCTAssertFalse(HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: "nuvio.folder:abc",
            presentedIdentity: "nuvio.folder:xyz",
            presentedBackdrop: nil,
            resolveTaskIsNil: true,
            identity: "nuvio.folder:abc"))
    }

    /// A resolve for this exact identity is still in flight (e.g. `present` was re-invoked for a
    /// byte-identical target and a fresh `resolveTask` is running). The deadline-driven commit
    /// this method exists to patch up has not happened yet, so there is nothing to adopt onto.
    func testDoesNotAdoptWhileAResolveIsStillInFlight() {
        XCTAssertFalse(HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: "nuvio.folder:abc",
            presentedIdentity: "nuvio.folder:abc",
            presentedBackdrop: nil,
            resolveTaskIsNil: false,
            identity: "nuvio.folder:abc"))
    }
}
