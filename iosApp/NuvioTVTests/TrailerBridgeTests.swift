import XCTest
@testable import NuvioTV

/// FEAT-32: the description-to-trailer bridge is a small state machine plus per-phase values, both
/// pure so they can be pinned here without a view. The sequence they encode is the one read off
/// the official Nuvio app frame by frame (tracker row FEAT-32): chrome out, caption in, dim to
/// black, cover; on return a hard cut to an enlarged still that settles before the chrome returns.
final class TrailerBridgeTests: XCTestCase {

    // MARK: - State machine

    func testHappyPathRunsIdleLeavingPlayingReturningIdle() {
        var phase = TrailerBridgePhase.idle
        phase = TrailerBridgeChoreography.next(phase, .trailerRequested)
        XCTAssertEqual(phase, .leaving)
        phase = TrailerBridgeChoreography.next(phase, .leaveFinished)
        XCTAssertEqual(phase, .playing)
        phase = TrailerBridgeChoreography.next(phase, .trailerEnded)
        XCTAssertEqual(phase, .returning)
        phase = TrailerBridgeChoreography.next(phase, .settle)
        XCTAssertEqual(phase, .idle)
    }

    /// The request can be withdrawn before the cover presents (the trailer failed to resolve, or
    /// the page was left): the bridge returns without ever having played.
    func testRequestWithdrawnWhileLeavingReturns() {
        XCTAssertEqual(TrailerBridgeChoreography.next(.leaving, .trailerEnded), .returning)
    }

    /// A stale leave timer must not present a cover over a page that already returned.
    func testStaleLeaveFinishedIsIgnoredOutsideLeaving() {
        XCTAssertEqual(TrailerBridgeChoreography.next(.idle, .leaveFinished), .idle)
        XCTAssertEqual(TrailerBridgeChoreography.next(.returning, .leaveFinished), .returning)
        XCTAssertEqual(TrailerBridgeChoreography.next(.playing, .leaveFinished), .playing)
    }

    func testSettleOnlyLandsFromReturning() {
        XCTAssertEqual(TrailerBridgeChoreography.next(.idle, .settle), .idle)
        XCTAssertEqual(TrailerBridgeChoreography.next(.leaving, .settle), .leaving)
        XCTAssertEqual(TrailerBridgeChoreography.next(.playing, .settle), .playing)
    }

    /// Watch Trailer pressed again during the return restarts the choreography from wherever the
    /// view is rather than being swallowed.
    func testRequestDuringReturnRestartsLeaving() {
        XCTAssertEqual(TrailerBridgeChoreography.next(.returning, .trailerRequested), .leaving)
    }

    // MARK: - Per-phase values

    func testChromeIsVisibleOnlyWhenIdle() {
        XCTAssertEqual(TrailerBridgeChoreography.chromeOpacity(.idle), 1)
        for phase in [TrailerBridgePhase.leaving, .playing, .returning] {
            XCTAssertEqual(TrailerBridgeChoreography.chromeOpacity(phase), 0, "\(phase)")
        }
    }

    /// The dim is up while leaving and playing, and cleared, not faded, on return: the cover's
    /// dismissal must reveal the still, not black.
    func testBlackoutCoversLeavingAndPlayingAndCutsOnReturn() {
        XCTAssertEqual(TrailerBridgeChoreography.blackout(.leaving), 1)
        XCTAssertEqual(TrailerBridgeChoreography.blackout(.playing), 1)
        XCTAssertEqual(TrailerBridgeChoreography.blackout(.returning), 0)
        XCTAssertEqual(TrailerBridgeChoreography.blackout(.idle), 0)
        XCTAssertNil(TrailerBridgeChoreography.blackoutAnimation(to: .returning))
        XCTAssertNotNil(TrailerBridgeChoreography.blackoutAnimation(to: .leaving))
    }

    /// The still lands enlarged with no animation and settles to 1 with one.
    func testBackdropLandsEnlargedThenSettles() {
        XCTAssertEqual(TrailerBridgeChoreography.backdropScale(.returning), TrailerBridgeChoreography.returnScale)
        XCTAssertGreaterThan(TrailerBridgeChoreography.returnScale, 1)
        XCTAssertEqual(TrailerBridgeChoreography.backdropScale(.idle), 1)
        XCTAssertEqual(TrailerBridgeChoreography.backdropScale(.leaving), 1)
        XCTAssertNil(TrailerBridgeChoreography.backdropAnimation(to: .returning))
        XCTAssertNotNil(TrailerBridgeChoreography.backdropAnimation(to: .idle))
    }

    /// The chrome comes back only after the settle has had its time.
    func testChromeReturnWaitsForTheSettle() {
        XCTAssertGreaterThanOrEqual(TrailerBridgeChoreography.chromeReturnDelay,
                                    TrailerBridgeChoreography.settleDuration)
        XCTAssertNotNil(TrailerBridgeChoreography.chromeAnimation(to: .idle))
        XCTAssertNil(TrailerBridgeChoreography.chromeAnimation(to: .returning))
    }

    /// rc2 (u/mrStevenx3, 2026-09-06): "the title resizes with the still (odd)" removed the scale-in,
    /// leaving opacity as the caption's only per-phase term. Restored 2026-09-08 on his 09-07 ask for
    /// "the logo growing while the page fades to dark" — scale is again a per-phase caption term,
    /// pinned here alongside opacity.
    func testCaptionShowsWhileLeavingAndIsGoneOnReturn() {
        XCTAssertEqual(TrailerBridgeChoreography.captionOpacity(.leaving), 1)
        XCTAssertEqual(TrailerBridgeChoreography.captionOpacity(.playing), 1)
        XCTAssertEqual(TrailerBridgeChoreography.captionOpacity(.returning), 0)
        XCTAssertEqual(TrailerBridgeChoreography.captionOpacity(.idle), 0)
        XCTAssertNotNil(TrailerBridgeChoreography.captionAnimation(to: .leaving))
        XCTAssertEqual(TrailerBridgeChoreography.captionScale(.leaving), 1)
        XCTAssertEqual(TrailerBridgeChoreography.captionScale(.playing), 1)
        XCTAssertGreaterThan(TrailerBridgeChoreography.captionScale(.idle), 1)
        XCTAssertEqual(TrailerBridgeChoreography.captionScale(.returning), TrailerBridgeChoreography.captionScale(.idle))
    }

    /// The whole entry should read as Nuvio's ~0.6 s, and the caption should outlast the cover's
    /// own presentation so it is actually seen over the first trailer frames.
    func testTimingsMatchTheReference() {
        XCTAssertEqual(TrailerBridgeChoreography.leaveDuration, 0.6, accuracy: 0.001)
        XCTAssertGreaterThan(TrailerBridgeChoreography.captionDwell, 1)
    }
}
