import XCTest
import CoreGraphics
@testable import NuvioTV

/// BUG-112 (Item B) — the direction-scoped pull-back brake (`PinnedRowSettle.PullBackLedger`) and
/// the bound arithmetic a re-armed corrector runs into (`PinnedRowSettle.plannedCorrection`).
///
/// Pure-value tests on purpose: `settlePlan`'s own state is `nonisolated(unsafe) private static`
/// and needs a live scroll host to drive, which is why the ledger is a value type in the first
/// place. What these CANNOT prove is which way the device's focus engine anchors a rest — that is
/// the device pass, read off the Row Settle pane's `dir=`/`rearm=`/`pull=` fields.
final class PinnedRowSettleDirectionTests: XCTestCase {

    private func walkDown(_ ledger: inout PinnedRowSettle.PullBackLedger,
                          rows: [String], from y: CGFloat = 0, step: CGFloat = 320)
    -> [PinnedRowSettle.PullBackLedger.SettleResult] {
        rows.enumerated().map { ledger.noteSettle(rowKey: $0.element, offsetY: y + CGFloat($0.offset) * step) }
    }

    func testTwoPullBacksWalkingDownDisarmThatDirection() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        XCTAssertEqual(ledger.direction, 1)
        ledger.notePullBack()
        XCTAssertFalse(ledger.disarmed, "one pull-back must not disarm — the budget is \(PinnedRowSettle.maxPullBacksPerSession)")
        ledger.notePullBack()
        XCTAssertTrue(ledger.disarmed)
        XCTAssertEqual(ledger.total, 2)
    }

    func testFirstSettleInTheOppositeDirectionReArms() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        ledger.notePullBack(); ledger.notePullBack()
        XCTAssertTrue(ledger.disarmed)
        let result = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertTrue(result.changed, "a reversal after a disarm must release the brake")
        XCTAssertTrue(result.released, "the disarmed ledger itself was released by this flip")
        XCTAssertEqual(ledger.direction, -1)
        XCTAssertFalse(ledger.disarmed, "the up ledger is empty — corrections are back on")
        XCTAssertEqual(ledger.rearms, 1)
        XCTAssertEqual(ledger.total, 2, "evidence is switched, never erased")
    }

    /// Codex P2: a pull-back recorded while direction was still `unknown` plus one recorded
    /// walking DOWN never crosses `maxPullBacksPerSession` in EITHER bucket, so the ledger itself
    /// is never `disarmed` and a plain reversal cannot "release" anything from it (`released` is
    /// false). But the reversal is still real, evidence-backed walk-direction evidence — `changed`
    /// must be true regardless — because `settlePlan` uses `changed` (not `released`) to decide
    /// whether to release the SEPARATE, static verify-miss latch: on hardware the two MISSes that
    /// latch counted were produced by these same two pull-backs seen a second time, so `changed`
    /// alone is the evidence needed, independent of what the ledger's own per-direction counters
    /// happen to read. That latch-release itself lives in `settlePlan` and needs a live host to
    /// exercise — not provable here, only at the ledger level this test covers.
    func testAReversalWithSplitPullBacksReleasesTheVerifyMissLatchSignal() {
        var ledger = PinnedRowSettle.PullBackLedger()
        ledger.notePullBack() // direction still 0 here — counts as `unknown`
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertEqual(ledger.direction, 1)
        ledger.notePullBack() // now walking down — counts as `down`
        XCTAssertEqual(ledger.unknown, 1)
        XCTAssertEqual(ledger.down, 1)
        XCTAssertEqual(ledger.up, 0)
        XCTAssertEqual(ledger.total, 2)
        XCTAssertFalse(ledger.disarmed,
            "neither per-direction count reached the budget of \(PinnedRowSettle.maxPullBacksPerSession) — the ledger itself was never disarmed")

        let result = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        XCTAssertTrue(result.changed, "the walk reversed — this is real evidence a reversal happened")
        XCTAssertFalse(result.released, "there was nothing disarmed on the ledger for this flip to release")
        XCTAssertEqual(ledger.total, 2, "evidence is switched, never erased")
        XCTAssertEqual(ledger.direction, -1)
    }

    func testNoReArmWithoutADirectionChange() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = walkDown(&ledger, rows: ["r1", "r2", "r3"])
        ledger.notePullBack(); ledger.notePullBack()
        let result = ledger.noteSettle(rowKey: "r4", offsetY: 960)
        XCTAssertFalse(result.changed, "still walking down")
        XCTAssertFalse(result.released)
        XCTAssertTrue(ledger.disarmed)
        XCTAssertEqual(ledger.rearms, 0)
    }

    func testReSettlingTheSameRowIsNotAHop() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertEqual(ledger.direction, 1)
        XCTAssertFalse(ledger.noteSettle(rowKey: "r2", offsetY: 320 - 93).changed)
        XCTAssertEqual(ledger.direction, 1)
    }

    func testSubThresholdHopDoesNotSetADirection() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        XCTAssertFalse(ledger.noteSettle(rowKey: "r2", offsetY: PinnedRowSettle.PullBackLedger.minHopDelta - 1).changed)
        XCTAssertEqual(ledger.direction, 0)
    }

    func testAWobbleStillDisarmsTheSessionForGood() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        ledger.notePullBack(); ledger.notePullBack()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        ledger.notePullBack(); ledger.notePullBack()
        XCTAssertTrue(ledger.hardDisarmed)
        // The direction still flips (the walk really did reverse — `changed` reports geometry),
        // but the flip must never RELEASE the brake past the hard stop.
        let reversal = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        XCTAssertTrue(reversal.changed, "the reversal itself is still observed")
        XCTAssertFalse(reversal.released, "no further re-arm past the hard stop")
        XCTAssertEqual(ledger.rearms, 1, "only the pre-hard-stop reversal counted as a re-arm")
        XCTAssertTrue(ledger.disarmed)
    }

    func testARegimeChangeClearsTheLedgerCompletely() {
        var ledger = PinnedRowSettle.PullBackLedger()
        _ = ledger.noteSettle(rowKey: "r1", offsetY: 0)
        _ = ledger.noteSettle(rowKey: "r2", offsetY: 320)
        ledger.notePullBack()
        ledger.resetAll()
        XCTAssertEqual(ledger.total, 0)
        XCTAssertEqual(ledger.direction, 0)
        XCTAssertEqual(ledger.rearms, 0)
    }

    func testADownwardCorrectionShortenedByTheBoundStillFires() {
        let planned = PinnedRowSettle.plannedCorrection(error: -103, deficit: 103,
                                                        bottomRoom: 93, scrollRoomUp: 400)
        XCTAssertEqual(planned.magnitude, 93, accuracy: 0.001)
        XCTAssertEqual(planned.correction, 93, accuracy: 0.001, "positive = move the content DOWN")
        XCTAssertTrue(planned.bounded)
        XCTAssertGreaterThanOrEqual(planned.magnitude, 2,
            "≥2 is `settlePlan`'s fire threshold — a bounded correction is still a correction")
    }

    func testAnUnboundedCorrectionLandsOnTheTarget() {
        let planned = PinnedRowSettle.plannedCorrection(error: -30, deficit: 30,
                                                        bottomRoom: 93, scrollRoomUp: 400)
        XCTAssertEqual(planned.magnitude, 30, accuracy: 0.001)
        XCTAssertFalse(planned.bounded)
    }

    func testAnUpwardCorrectionIsBoundedByScrollRangeNotByTheRowBottom() {
        let planned = PinnedRowSettle.plannedCorrection(error: 40, deficit: 40,
                                                        bottomRoom: 93, scrollRoomUp: 12)
        XCTAssertEqual(planned.magnitude, 12, accuracy: 0.001)
        XCTAssertEqual(planned.correction, -12, accuracy: 0.001, "negative = move the content UP")
    }
}
