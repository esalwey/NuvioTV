import XCTest
import SwiftUI
@testable import NuvioTV

/// BUG-96 (beta.18): the unit-point math that lands a focused detail row's top at
/// `DetailRowAnchor.topInset`. `scrollTo(_:anchor:)` aligns the row's anchor point with the scroll
/// view's same anchor point, so the point is solved, not guessed.
final class DetailRowAnchorTests: XCTestCase {

    /// Given the solved point, the row's top lands at the inset: `row.minY = k·vh − k·rh`.
    private func landedTop(rowHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let k = DetailRowAnchor.anchor(rowHeight: rowHeight, viewportHeight: viewportHeight).y
        return k * viewportHeight - k * rowHeight
    }

    func testTypicalRowsLandAtTheInset() {
        for rowHeight: CGFloat in [180, 320, 420, 560] {
            XCTAssertEqual(landedTop(rowHeight: rowHeight, viewportHeight: 1080),
                           DetailRowAnchor.topInset, accuracy: 0.001,
                           "row \(rowHeight)pt must rest with its top at the inset")
        }
    }

    func testAnchorXIsLeading() {
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 300, viewportHeight: 1080).x, 0)
    }

    func testARowTallerThanTheViewportTopAligns() {
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 1200, viewportHeight: 1080), .top)
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 1080, viewportHeight: 1080), .top)
    }

    func testAnchorNeverLeavesTheUnitRange() {
        // A row nearly as tall as the viewport would need k > 1 to reach the inset; it is clamped.
        let point = DetailRowAnchor.anchor(rowHeight: 1060, viewportHeight: 1080)
        XCTAssertEqual(point.y, 1, accuracy: 0.001)
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 0, viewportHeight: 1080, topInset: 0).y, 0)
    }

    func testCustomInsetIsHonoured() {
        XCTAssertEqual(landedTopWithInset(48), 48, accuracy: 0.001)
    }

    private func landedTopWithInset(_ inset: CGFloat) -> CGFloat {
        let k = DetailRowAnchor.anchor(rowHeight: 300, viewportHeight: 1080, topInset: inset).y
        return k * 1080 - k * 300
    }
}

/// BUG-99 (rc6, u/mrStevenx3): `DetailRowAnchor.decision` is the pure rule behind the direction
/// split — Up always anchors (unchanged behaviour); Down anchors only when the row's current
/// on-screen top straddles (is at or under) the `topScrimHeight` scrim near the top edge, i.e. is
/// below `screenRest`'s threshold, and otherwise stays `.free` so the engine's own minimal reveal
/// is left alone. See `DetailRowAnchor`'s doc comment for the tester report this decouples.
final class DetailRowAnchorDecisionTests: XCTestCase {
    func testUpAlwaysAnchorsRegardlessOfScreenTop() {
        XCTAssertEqual(DetailRowAnchor.decision(direction: .up, screenTop: 600), .anchor)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .up, screenTop: 60), .anchor)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .up, screenTop: 0), .anchor)
    }

    func testDownStaysFreeWhenClearOfTheRest() {
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 600), .free)
    }

    func testDownAnchorsWhenStraddlingTheTopScrim() {
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 60), .anchor)
    }

    func testDownBoundaryAtScreenRestIsFree() {
        // Closed lower bound on the FREE side: a row already resting exactly at `screenRest` does
        // not need rescuing, so the boundary itself must not anchor (only strictly *above* the
        // rest — a smaller screenTop — does).
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: DetailRowAnchor.screenRest), .free)
    }
}

/// Codex P2 review finding (BUG-99 follow-up, round 2): `DetailRowAnchor.direction` is the pure
/// rule behind which way a focus change moved, factored out of `DetailView.onChange(of:
/// focusedRow)` so every case is covered without a live view. Round 1 needed a `lastKnownTop`/
/// `contentOffset` heuristic because `focusedRow` reported nil both in the unanchored top block AND
/// in the (then-untracked) Comments section, and that heuristic broke whenever Comments was
/// reachable without scrolling past the last row's own rest. Round 2 makes Comments a TRACKED row
/// instead (`commentsSection` now carries `.detailRowAnchored(.comments, …)`), which retires the
/// heuristic entirely: `old == nil` now means only one thing — the top block.
final class DetailRowAnchorDirectionTests: XCTestCase {
    func testOldNilIsDown() {
        // The only row that ever reports `focusedRow == nil` now is the unanchored top block.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: nil, oldTop: nil, newTop: 300),
            .down
        )
    }

    func testOldAboveIsDown() {
        // The row that just lost focus sits higher in the content (a smaller top) than the
        // newly-focused one.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .cast, oldTop: 300, newTop: 900),
            .down
        )
    }

    func testOldBelowIsUp() {
        // The row that just lost focus sits lower in the content than the newly-focused one —
        // covers an ordinary anchored-row-to-anchored-row Up, and leaving Comments (now a real,
        // measured row sitting below everything else) for any row above it.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .comments, oldTop: 900, newTop: 300),
            .up
        )
    }

    func testOldCommentsWithMissingTopIsUp() {
        // Comments' very first `onGeometryChange` callback has not landed yet, so its top is
        // missing from the map even though `old` itself is `.comments` — Comments sits below every
        // anchored row, so leaving it can only be Up.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .comments, oldTop: nil, newTop: 300),
            .up
        )
    }

    func testOldOtherRowWithMissingTopIsDown() {
        // Any other row's top dropping out of the map falls back to the original default: Down.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .cast, oldTop: nil, newTop: 300),
            .down
        )
    }
}

/// BUG-96 (Codex P2 follow-up): `DetailScrollMotion.segments` is the `moves=` oracle — one motion
/// (engine reveal blended with the anchor pass) must read as `1`, and the old land-then-nudge
/// design (a settle wait long enough for the engine to fully rest before the anchor slid it again)
/// would read as `2`. The split is TIME-based (see `DetailScrollMotion`'s doc comment for why:
/// `onScrollGeometryChange` delivers changes only, so a genuine pause can produce zero samples),
/// so every fixture here is a timestamped `MotionSample` array, not a bare offset array — these
/// shapes are ones the real callback can actually produce, unlike the old plateau-of-N-samples
/// fixtures it replaces.
final class DetailScrollMotionTests: XCTestCase {

    /// Builds a run of samples moving at a fixed cadence, starting at `t0`/`offset0`, each
    /// `interval` seconds after the last and `step` points further (step magnitude always at or
    /// above `stationaryThreshold` so every sample in the ramp counts as moving).
    private func ramp(t0: TimeInterval, offset0: CGFloat, count: Int, interval: TimeInterval, step: CGFloat) -> [MotionSample] {
        (0..<count).map { i in
            MotionSample(time: t0 + TimeInterval(i) * interval, offset: offset0 + CGFloat(i) * step)
        }
    }

    func testSingleRampIsOneSegment() {
        // 10 samples, 16ms apart (one 30fps-ish cadence), steadily moving.
        let samples = ramp(t0: 0, offset0: 0, count: 10, interval: 0.016, step: 20)
        XCTAssertEqual(DetailScrollMotion.segments(samples), 1)
    }

    func testRampPauseRampIsTwoSegments() {
        // A ramp, a 350ms gap (comfortably above `pauseToSplit` — the engine's reveal finishing
        // and the anchor pass starting, the old land-then-nudge shape), then a second ramp.
        let ramp1 = ramp(t0: 0, offset0: 0, count: 5, interval: 0.016, step: 20)
        let ramp2 = ramp(t0: (ramp1.last?.time ?? 0) + 0.350, offset0: 90, count: 5, interval: 0.016, step: 20)
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + ramp2), 2)
    }

    func testRampWithOneHiccupInsideIsOneSegment() {
        // A ramp where one inter-sample gap is 40ms instead of the usual 16ms — a dropped frame,
        // not a pause — must still read as one continuous motion (well under `pauseToSplit`, 0.10s).
        let samples: [MotionSample] = [
            MotionSample(time: 0.000, offset: 0),
            MotionSample(time: 0.016, offset: 20),
            MotionSample(time: 0.032, offset: 40),
            MotionSample(time: 0.072, offset: 60), // 40ms hiccup here
            MotionSample(time: 0.088, offset: 80),
            MotionSample(time: 0.104, offset: 100),
            MotionSample(time: 0.120, offset: 120)
        ]
        XCTAssertEqual(DetailScrollMotion.segments(samples), 1)
    }

    func testLoneJitterSampleAfterALongGapDoesNotStartASegment() {
        // A ramp (one segment), then a 400ms gap, then a single sub-threshold jitter sample —
        // sub-pixel `ScrollView` noise, not real motion — must not itself start a second segment.
        let ramp1 = ramp(t0: 0, offset0: 0, count: 5, interval: 0.016, step: 20)
        let jitter = MotionSample(time: (ramp1.last?.time ?? 0) + 0.400, offset: (ramp1.last?.offset ?? 0) + 0.3)
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + [jitter]), 1)
    }

    func testEmptyAndSingleSampleAreZeroSegments() {
        XCTAssertEqual(DetailScrollMotion.segments([]), 0)
        XCTAssertEqual(DetailScrollMotion.segments([MotionSample(time: 0, offset: 42)]), 0)
    }

    func testTwoRampsExactlyPauseToSplitApartIsTwoSegments() {
        // Boundary inclusive: a gap of exactly `pauseToSplit` (0.10s) since the last moving sample
        // must split, not join — `segments` treats the split as `gap >= pauseToSplit`.
        let ramp1 = ramp(t0: 0, offset0: 0, count: 3, interval: 0.016, step: 20)
        let ramp2 = ramp(t0: (ramp1.last?.time ?? 0) + DetailScrollMotion.pauseToSplit, offset0: 60, count: 3, interval: 0.016, step: 20)
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + ramp2), 2)
    }
}
