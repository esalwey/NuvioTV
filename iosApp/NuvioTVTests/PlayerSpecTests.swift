import XCTest
@testable import NuvioTV

/// The values of docs/player-spec.md that the mpv chrome is built from. A change to one of them is a
/// change to the spec, and the document has to change with it.
@MainActor
final class PlayerSpecTests: XCTestCase {

    func testTheSkipIsTenSecondsAndTheScanCyclesTwoThreeFour() {
        XCTAssertEqual(PlayerSpec.Remote.skipSeconds, 10)
        XCTAssertEqual(PlayerSpec.Remote.scanRates, [2, 3, 4])
    }

    func testAHoldIsLongerThanAClick() {
        XCTAssertGreaterThan(PlayerSpec.Remote.holdThresholdSec, 0.3)
        XCTAssertLessThan(PlayerSpec.Remote.holdThresholdSec, 1)
    }

    func testTheBarHidesAFewSecondsAfterTheLastInteraction() {
        XCTAssertGreaterThanOrEqual(PlayerSpec.Chrome.autoHideDelay, 3)
        XCTAssertLessThanOrEqual(PlayerSpec.Chrome.autoHideDelay, 5)
        XCTAssertEqual(PlayerChromeMetrics.autoHideDelay, PlayerSpec.Chrome.autoHideDelay)
    }

    func testTheSkipHintLivesAsLongAsTheBar() {
        XCTAssertEqual(PlayerSpec.Chrome.skipHintLifetime, PlayerSpec.Chrome.autoHideDelay)
    }

    func testTheDisplayedPlayheadRunsBetweenPollsOnlyWhilePlaying() {
        let state = MPVPlaybackState(title: "t")
        state.durationSec = 100
        state.isBuffering = false
        state.positionSec = 10
        let stamp = state.positionStampedAt
        XCTAssertEqual(state.displayPosition(at: stamp + 0.4), 10.4, accuracy: 0.001)
        // A poll that stalls cannot run the head away: one second past the last poll at most.
        XCTAssertEqual(state.displayPosition(at: stamp + 30), 11, accuracy: 0.001)
        state.isPaused = true
        XCTAssertEqual(state.displayPosition(at: stamp + 0.4), 10, accuracy: 0.001)
        state.isPaused = false
        state.fastForwardRate = 2
        XCTAssertEqual(state.displayPosition(at: stamp + 0.4), 10, accuracy: 0.001)
        state.fastForwardRate = nil
        state.positionSec = 99.9
        XCTAssertEqual(state.displayPosition(at: state.positionStampedAt + 0.9), 100, accuracy: 0.001)
    }

    func testTheSkipChipLosesTheFocusWhenItsSegmentEnds() {
        let state = MPVPlaybackState(title: "t")
        state.skipChipFocused = true
        state.skipPrompt = nil
        XCTAssertFalse(state.skipChipFocused)
    }

    func testTheBarFadesInAFractionOfASecond() {
        XCTAssertGreaterThanOrEqual(PlayerSpec.Chrome.fadeDuration, 0.25)
        XCTAssertLessThanOrEqual(PlayerSpec.Chrome.fadeDuration, 0.35)
    }
}
