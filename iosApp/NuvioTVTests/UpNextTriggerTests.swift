import XCTest
@testable import NuvioTV

/// Unit tests for `UpNextTrigger` (`Screens/NextEpisodeAutoPlay.swift`) — the pure rule deciding
/// when the Up Next card appears: at the credits start when the credits run to the end of the file,
/// after a post-credits scene (upstream 77ce8a733) otherwise, and N seconds (or a synced
/// percentage, no longer clamped to 97 %) before the end when the credits timing is unknown.
@MainActor
final class UpNextTriggerTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double, _ type: String) -> SkipSegment {
        SkipSegment(start: start, end: end, type: type)
    }

    // MARK: - No credits timing

    func testNoCreditsUsesSecondsBeforeEnd() {
        let timing = UpNextTrigger.timing(durationSec: 1320, segments: [], useCredits: true,
                                          threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1290, anchor: .beforeEnd))
    }

    func testPercentThresholdIsNoLongerClampedTo97() {
        let timing = UpNextTrigger.timing(durationSec: 1000, segments: [], useCredits: true,
                                          threshold: .percent(90), countdownSec: 10)
        XCTAssertEqual(timing?.anchor, .beforeEnd)
        XCTAssertEqual(timing?.cardAtSec ?? 0, 900, accuracy: 0.001)
    }

    func testLeadNeverShorterThanMinimum() {
        let timing = UpNextTrigger.timing(durationSec: 1320, segments: [], useCredits: true,
                                          threshold: .secondsBeforeEnd(1), countdownSec: 10)
        XCTAssertEqual(timing?.cardAtSec, 1320 - UpNextTrigger.minimumLeadSec)
    }

    func testShortPlaceholderClipHasNoCard() {
        XCTAssertNil(UpNextTrigger.timing(durationSec: 60, segments: [], useCredits: true,
                                          threshold: .secondsBeforeEnd(30), countdownSec: 10))
        // A 45-minute episode's metadata makes a one-minute file all the more a placeholder.
        XCTAssertNil(UpNextTrigger.timing(durationSec: 60, segments: [], useCredits: true,
                                          threshold: .secondsBeforeEnd(30), countdownSec: 10,
                                          expectedRuntimeSec: 2700))
    }

    func testGenuinelyShortEpisodeStillGetsTheCard() {
        // Metadata says the episode itself runs 2 minutes: a 100 s file is real content.
        let timing = UpNextTrigger.timing(durationSec: 100, segments: [], useCredits: true,
                                          threshold: .secondsBeforeEnd(30), countdownSec: 10,
                                          expectedRuntimeSec: 120)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 70, anchor: .beforeEnd))
        XCTAssertFalse(UpNextTrigger.isPlaceholder(durationSec: 100, expectedRuntimeSec: 120))
        XCTAssertTrue(UpNextTrigger.isPlaceholder(durationSec: 100, expectedRuntimeSec: nil))
        XCTAssertFalse(UpNextTrigger.isPlaceholder(durationSec: 1320, expectedRuntimeSec: nil))
    }

    // MARK: - End of file

    func testEndAtTheDurationIsNatural() {
        XCTAssertTrue(UpNextTrigger.isNaturalEnd(positionSec: 1320, durationSec: 1320))
        // Container durations can run a little past the last frame.
        XCTAssertTrue(UpNextTrigger.isNaturalEnd(positionSec: 1310, durationSec: 1320))
    }

    func testStreamThatStoppedEarlyIsNotANaturalEnd() {
        XCTAssertFalse(UpNextTrigger.isNaturalEnd(positionSec: 264, durationSec: 1320))
        XCTAssertFalse(UpNextTrigger.isNaturalEnd(positionSec: 10, durationSec: 0))
    }

    func testCatalogRuntimeStrings() {
        XCTAssertEqual(NextEpisodeEngine.runtimeSec(parsing: "45 min"), 2700)
        XCTAssertEqual(NextEpisodeEngine.runtimeSec(parsing: "1h 30min"), 5400)
        XCTAssertEqual(NextEpisodeEngine.runtimeSec(parsing: "24"), 1440)
        XCTAssertNil(NextEpisodeEngine.runtimeSec(parsing: ""))
        XCTAssertNil(NextEpisodeEngine.runtimeSec(parsing: nil))
    }

    // MARK: - Credits known

    func testCreditsRunningToTheEndShowTheCardAtCreditsStart() {
        let timing = UpNextTrigger.timing(durationSec: 1440, segments: [segment(1350, 1438, "ed")],
                                          useCredits: true, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1350, anchor: .credits))
    }

    func testCreditsEndingPastTheFileCountAsRunningToTheEnd() {
        // Anime-Skip's last timestamp has no end (Double.greatestFiniteMagnitude).
        let timing = UpNextTrigger.timing(durationSec: 1440,
                                          segments: [segment(1350, .greatestFiniteMagnitude, "ed")],
                                          useCredits: true, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1350, anchor: .credits))
    }

    func testSceneAfterTheCreditsPlaysBeforeTheCard() {
        let timing = UpNextTrigger.timing(durationSec: 1440, segments: [segment(1290, 1380, "outro")],
                                          useCredits: true, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1430, anchor: .afterCredits))
    }

    func testShortTailAfterTheCreditsStartsTheCardWhenTheCreditsEnd() {
        let timing = UpNextTrigger.timing(durationSec: 1440, segments: [segment(1350, 1432, "outro")],
                                          useCredits: true, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1432, anchor: .afterCredits))
    }

    func testCreditsIgnoredWhenTheSettingIsOff() {
        let timing = UpNextTrigger.timing(durationSec: 1440, segments: [segment(1350, 1438, "ed")],
                                          useCredits: false, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1410, anchor: .beforeEnd))
    }

    func testIntroSegmentsDoNotTriggerTheCard() {
        let timing = UpNextTrigger.timing(durationSec: 1440, segments: [segment(60, 150, "op")],
                                          useCredits: true, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing?.anchor, .beforeEnd)
    }

    func testCreditsTaggedInTheFirstHalfAreIgnored() {
        let timing = UpNextTrigger.timing(durationSec: 1440, segments: [segment(100, 190, "ed")],
                                          useCredits: true, threshold: .secondsBeforeEnd(30), countdownSec: 10)
        XCTAssertEqual(timing, UpNextTrigger.Timing(cardAtSec: 1410, anchor: .beforeEnd))
    }
}
