import XCTest
@testable import NuvioTV

/// The values of docs/player-spec.md that the mpv chrome is built from. A change to one of them is a
/// change to the spec, and the document has to change with it.
@MainActor
final class PlayerSpecTests: XCTestCase {

    func testTheSkipIsTenSecondsAndAHoldRunsInThreeTiers() {
        XCTAssertEqual(PlayerSpec.Remote.skipSeconds, 10)
        // Owner's recording: 8, 24 and 48 media seconds per second, a bare digit from the second tier.
        XCTAssertEqual(PlayerSpec.Remote.scanRates, [8, 24, 48])
        XCTAssertEqual(PlayerSpec.Remote.scanDigits.count, PlayerSpec.Remote.scanRates.count)
        XCTAssertNil(PlayerSpec.Remote.scanDigits[0])
        XCTAssertEqual(PlayerSpec.Remote.scanDigits[1], 2)
        XCTAssertEqual(PlayerSpec.Remote.scanDigits[2], 3)
    }

    func testAHoldIsLongerThanAClick() {
        XCTAssertGreaterThan(PlayerSpec.Remote.holdThresholdSec, 0.3)
        XCTAssertLessThan(PlayerSpec.Remote.holdThresholdSec, 1)
    }

    func testTheChromeHidesFiveSecondsAfterTheLastInteraction() {
        XCTAssertEqual(PlayerSpec.Chrome.autoHideDelay, 5)
        XCTAssertEqual(PlayerChromeMetrics.autoHideDelay, PlayerSpec.Chrome.autoHideDelay)
        // The bar alone of a skip click was still up 1.98 s after the last click in the recording.
        XCTAssertGreaterThanOrEqual(PlayerSpec.Chrome.skimLifetime, 1.98)
    }

    func testTheChromeFadesOutInAFractionOfASecond() {
        XCTAssertGreaterThanOrEqual(PlayerSpec.Chrome.hideFadeSec, 0.1)
        XCTAssertLessThanOrEqual(PlayerSpec.Chrome.hideFadeSec, 0.2)
        XCTAssertGreaterThanOrEqual(PlayerSpec.Chrome.touchFadeSec, 0.1)
        XCTAssertLessThanOrEqual(PlayerSpec.Chrome.touchFadeSec, 0.13)
    }

    func testTheThirdBackSkipOfARunTurnsSubtitlesOnForElevenSeconds() {
        XCTAssertEqual(PlayerSpec.Skip.subtitlesFromClick, 3)
        XCTAssertEqual(PlayerSpec.Skip.subtitlesWindowSec, 11)
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
        // A hold has its own clock: still for the start delay, then the head runs.
        state.scan = MPVScan(direction: 1, startPosition: 10, startUptime: stamp, duration: 100)
        XCTAssertEqual(state.displayPosition(at: stamp + 0.2), 10, accuracy: 0.001)
        XCTAssertEqual(state.displayPosition(at: stamp + 0.4), 10.8, accuracy: 0.001)
        state.scan = nil
        state.positionSec = 99.9
        XCTAssertEqual(state.displayPosition(at: state.positionStampedAt + 0.9), 100, accuracy: 0.001)
    }

    func testAHoldRunsAtTheMeasuredSpeedsAndKeepsInsideTheFile() {
        // The rewind of the recording: 16:08 at the freeze, 8 s/s, then 24, then 48 s/s.
        let back = MPVScan(direction: -1, startPosition: 968, startUptime: 100, duration: 1355)
        XCTAssertEqual(back.position(at: 100), 968, accuracy: 0.001)
        XCTAssertEqual(back.position(at: 100.3), 968, accuracy: 0.001)
        XCTAssertEqual(back.position(at: 102.4), 951.2, accuracy: 0.01)
        XCTAssertEqual(back.position(at: 102.55), 948.8, accuracy: 0.01)
        XCTAssertEqual(back.position(at: 104.95), 889.4, accuracy: 0.01)
        XCTAssertEqual(back.position(at: 106.95), 793.4, accuracy: 0.01)
        XCTAssertEqual(MPVScan.rate(atElapsed: 1), 8, accuracy: 0.001)
        XCTAssertEqual(MPVScan.rate(atElapsed: 3), 24, accuracy: 0.001)
        XCTAssertEqual(MPVScan.rate(atElapsed: 6), 48, accuracy: 0.001)
        // Never past either end of the file.
        let forward = MPVScan(direction: 1, startPosition: 1350, startUptime: 0, duration: 1355)
        XCTAssertEqual(forward.position(at: 60), 1354, accuracy: 0.001)
        let toStart = MPVScan(direction: -1, startPosition: 3, startUptime: 0, duration: 1355)
        XCTAssertEqual(toStart.position(at: 60), 0, accuracy: 0.001)
    }

    func testTheBadgeComesAfterTheFreezeAndTheDigitFromTheSecondTier() {
        let scan = MPVScan(direction: -1, startPosition: 968, startUptime: 100, duration: 1355)
        XCTAssertFalse(scan.badgeVisible(at: 100.1))
        XCTAssertTrue(scan.badgeVisible(at: 100.25))
        XCTAssertEqual(scan.tier(at: 101), 1)
        XCTAssertNil(scan.digit(at: 101))
        XCTAssertEqual(scan.tier(at: 102.5), 2)
        XCTAssertEqual(scan.digit(at: 102.5), 2)
        XCTAssertEqual(scan.tier(at: 105), 3)
        XCTAssertEqual(scan.digit(at: 105), 3)
        // No tier above the third.
        XCTAssertEqual(scan.tier(at: 130), 3)
    }

    func testTheStateGlyphLeadsTheWayAndLeavesWhileAFingerRestsOrTheHeadIsScrubbed() {
        let state = MPVPlaybackState(title: "t")
        XCTAssertNil(state.slot(at: 0))
        state.isPaused = true
        XCTAssertEqual(state.slot(at: 0), .pause)
        XCTAssertEqual(MPVBarSlot.pause.side, 1)
        // The knob (a finger resting) and a scrub take the pause glyph away.
        state.knobShown = true
        XCTAssertNil(state.slot(at: 0))
        state.knobShown = false
        state.scrubTargetSec = 1000
        XCTAssertNil(state.slot(at: 0))
        state.scrubTargetSec = nil
        // A click's glyph is on the side the head is going.
        state.skipHint = SkipHint(id: 1, direction: -1, seconds: 10)
        XCTAssertEqual(state.slot(at: 0), .skip(direction: -1, id: 1))
        XCTAssertEqual(state.slot(at: 0)?.side, -1)
        state.skipHint = nil
        // A hold's badge, then the spinner its release leaves.
        state.isPaused = false
        state.scan = MPVScan(direction: 1, startPosition: 10, startUptime: 0, duration: 100)
        XCTAssertNil(state.slot(at: 0.1))
        XCTAssertEqual(state.slot(at: 0.5), .scan(direction: 1, digit: nil))
        XCTAssertEqual(state.slot(at: 3), .scan(direction: 1, digit: 2))
        state.scan = nil
        state.seekSettleDirection = -1
        XCTAssertEqual(state.slot(at: 0), .seeking(direction: -1))
    }

    func testThePauseChromeWaitsForItsDelay() {
        let state = MPVPlaybackState(title: "t")
        state.isPaused = true
        XCTAssertFalse(state.pauseChromeShown)
        state.pauseChromeRevealed = true
        XCTAssertTrue(state.pauseChromeShown)
        // Playing again: the next pause waits for its own delay again.
        state.isPaused = false
        XCTAssertFalse(state.pauseChromeRevealed)
    }

    func testTheLabelsUnderTheBarHaveTwoDigitMinutesFromTenMinutesUp() {
        XCTAssertEqual(PlayerChromeFormat.label(943, padded: true), "15:43")
        XCTAssertEqual(PlayerChromeFormat.label(412, padded: true), "06:52")
        XCTAssertEqual(PlayerChromeFormat.label(412, padded: false), "6:52")
        XCTAssertEqual(PlayerChromeFormat.label(3753, padded: true), "1:02:33")
        // The two labels add up to the length: 15:57 and -06:38 on 22:35, whatever the fraction.
        XCTAssertEqual(PlayerChromeFormat.remaining(duration: 1355.2, elapsed: 957.4, padded: true), "-06:38")
        XCTAssertEqual(PlayerChromeFormat.remaining(duration: 1355, elapsed: 1400, padded: true), "-00:00")
    }

    func testTheLayoutStacksTheRowsAtTheHeightsTheSystemPlayerHas() {
        // Heights of the rows' centres above the bottom edge, as stacked by `PlayerTransportBar`
        // (the recording: pills 79, labels 150, bar 178, title 249, buttons 258, episode line 314).
        typealias L = PlayerSpec.Layout
        let pillsTop = L.bottomInset + L.pillHeight
        let barRowTop = pillsTop + L.barToPills + L.scrubberRowHeight
        let barCentre = barRowTop - L.barThicknessActive / 2
        let labelsCentre = barCentre - L.labelOffset
        let buttonsBottom = barRowTop + L.titleRowToBar
        let buttonsCentre = buttonsBottom + L.buttonDiameter / 2
        XCTAssertEqual(L.bottomInset + L.pillHeight / 2, 79, accuracy: 1)
        XCTAssertEqual(barCentre, 178, accuracy: 1)
        XCTAssertEqual(labelsCentre, 150, accuracy: 2)
        XCTAssertEqual(buttonsCentre, 258, accuracy: 1)
        // The title's line box is 1.19 em tall, its capitals centred in it; the episode line stands
        // `episodeToTitle` above it. Both blocks are dropped by `titleDrop` under the buttons' bottom.
        let titleLine = L.titleFont * 1.193
        let episodeLine = L.episodeFont * 1.193
        let titleCentre = buttonsBottom - L.titleDrop + titleLine / 2
        let episodeCentre = buttonsBottom - L.titleDrop + titleLine + L.episodeToTitle + episodeLine / 2
        XCTAssertEqual(titleCentre, 249, accuracy: 2)
        XCTAssertEqual(episodeCentre, 314, accuracy: 2)
    }

    func testTheSkipChipLosesTheFocusWhenItsSegmentEnds() {
        let state = MPVPlaybackState(title: "t")
        state.skipChipFocused = true
        state.skipPrompt = nil
        XCTAssertFalse(state.skipChipFocused)
    }
}
