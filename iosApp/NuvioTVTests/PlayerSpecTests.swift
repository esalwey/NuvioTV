import XCTest
@testable import NuvioTV

/// The values of docs/player-spec.md that the mpv chrome is built from. A change to one of them is a
/// change to the spec, and the document has to change with it.
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

    func testTheBarFadesInAFractionOfASecond() {
        XCTAssertGreaterThanOrEqual(PlayerSpec.Chrome.fadeDuration, 0.25)
        XCTAssertLessThanOrEqual(PlayerSpec.Chrome.fadeDuration, 0.35)
    }
}
