import AVFoundation
import XCTest
@testable import NuvioTV

/// Unit tests for the pure rules behind the player's view options (Aspect Ratio, playback speed
/// steps, the clock's end time and the parental guide's timing) — shared by both player engines.
@MainActor
final class PlayerViewOptionsTests: XCTestCase {

    // MARK: - Aspect Ratio

    func testEveryModeMapsToItsMpvAndAvKitSetting() {
        XCTAssertEqual(PlayerAspectMode.fit.mpvPanscan, 0)
        XCTAssertTrue(PlayerAspectMode.fit.mpvKeepsAspect)
        XCTAssertEqual(PlayerAspectMode.fill.mpvPanscan, 1)
        XCTAssertTrue(PlayerAspectMode.fill.mpvKeepsAspect)
        XCTAssertEqual(PlayerAspectMode.stretch.mpvPanscan, 0)
        XCTAssertFalse(PlayerAspectMode.stretch.mpvKeepsAspect)

        XCTAssertEqual(PlayerAspectMode.fit.videoGravity, AVLayerVideoGravity.resizeAspect)
        XCTAssertEqual(PlayerAspectMode.fill.videoGravity, AVLayerVideoGravity.resizeAspectFill)
        XCTAssertEqual(PlayerAspectMode.stretch.videoGravity, AVLayerVideoGravity.resize)
    }

    func testStretchIsNotRemembered() {
        XCTAssertNil(PlayerAspectMode.stretch.persistedResizeMode)
        XCTAssertNotNil(PlayerAspectMode.fit.persistedResizeMode)
        XCTAssertNotNil(PlayerAspectMode.fill.persistedResizeMode)
    }

    func testAspectMenuIsPartOfTheSharedTransportBar() {
        let items = PlayerTransportMenus.customItems(canChooseSource: false, supportsSubtitleDelay: false)
        XCTAssertTrue(items.contains(.aspect))
        let speed = items.firstIndex(of: .playbackSpeed)
        let aspect = items.firstIndex(of: .aspect)
        XCTAssertNotNil(speed)
        XCTAssertEqual(aspect, speed.map { $0 + 1 })
    }

    // MARK: - Playback speed

    func testSpeedStepsAreTheEightSharedSteps() {
        XCTAssertEqual(PlayerTransportMenus.rates, [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
    }

    // MARK: - Clock and end time

    func testEndTimeFollowsTheRemainingTimeAtThePlaybackSpeed() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(PlayerClockPill.endDate(from: now, remainingSec: 600, rate: 1),
                       now.addingTimeInterval(600))
        XCTAssertEqual(PlayerClockPill.endDate(from: now, remainingSec: 600, rate: 2),
                       now.addingTimeInterval(300))
        XCTAssertEqual(PlayerClockPill.endDate(from: now, remainingSec: 600, rate: 0.5),
                       now.addingTimeInterval(1_200))
    }

    func testNoEndTimeWithoutARemainingTime() {
        let now = Date()
        XCTAssertNil(PlayerClockPill.endDate(from: now, remainingSec: nil, rate: 1))
        XCTAssertNil(PlayerClockPill.endDate(from: now, remainingSec: 0, rate: 1))
        XCTAssertNil(PlayerClockPill.endDate(from: now, remainingSec: .infinity, rate: 1))
    }

    func testClockModelKeepsTheRemainingTimeInFiveSecondSteps() {
        let model = PlayerClockModel()
        model.update(position: 100, duration: 1_000)
        XCTAssertEqual(model.remainingSec, 900)
        model.update(position: 102, duration: 1_000)
        XCTAssertEqual(model.remainingSec, 900)
        model.update(position: 0, duration: 0)
        XCTAssertNil(model.remainingSec)
    }

    // MARK: - Parental guide timing

    func testGuideShowsOnceTheFirstFrameIsUpWithTheChromeAway() {
        XCTAssertTrue(ParentalGuideTiming.shouldShow(settingOn: true, hasWarnings: true, alreadyShown: false,
                                                     firstFrameAge: 2, chromeVisible: false))
    }

    func testGuideWaitsForTheFirstFrameAndTheChrome() {
        XCTAssertFalse(ParentalGuideTiming.shouldShow(settingOn: true, hasWarnings: true, alreadyShown: false,
                                                      firstFrameAge: nil, chromeVisible: false))
        XCTAssertFalse(ParentalGuideTiming.shouldShow(settingOn: true, hasWarnings: true, alreadyShown: false,
                                                      firstFrameAge: 2, chromeVisible: true))
    }

    func testGuideNeverShowsTwiceOrWithoutWarningsOrWhenOff() {
        XCTAssertFalse(ParentalGuideTiming.shouldShow(settingOn: true, hasWarnings: true, alreadyShown: true,
                                                      firstFrameAge: 2, chromeVisible: false))
        XCTAssertFalse(ParentalGuideTiming.shouldShow(settingOn: true, hasWarnings: false, alreadyShown: false,
                                                      firstFrameAge: 2, chromeVisible: false))
        XCTAssertFalse(ParentalGuideTiming.shouldShow(settingOn: false, hasWarnings: true, alreadyShown: false,
                                                      firstFrameAge: 2, chromeVisible: false))
    }

    func testGuideIsTooLateOnceTheOpeningSecondsHavePassed() {
        let late = ParentalGuideTiming.latestStartSeconds + 1
        XCTAssertFalse(ParentalGuideTiming.shouldShow(settingOn: true, hasWarnings: true, alreadyShown: false,
                                                      firstFrameAge: late, chromeVisible: false))
    }
}
