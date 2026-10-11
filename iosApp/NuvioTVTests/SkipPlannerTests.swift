import XCTest
@testable import NuvioTV

/// Unit tests for `SkipPlanner` and `AutoSkipTracker` (`Screens/Player/SkipPlanner.swift`) — the
/// pure rules shared by both player engines: where a skip lands (a scene after the credits is
/// kept), what the chip says, and when Automatic Skipping fires (once per segment, never over a
/// viewer's own seek, never over a post-credits scene).
@MainActor
final class SkipPlannerTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double, _ type: String) -> SkipSegment {
        SkipSegment(start: start, end: end, type: type)
    }

    // MARK: - Where a skip lands

    func testIntroSkipsToItsEnd() {
        let intro = segment(60, 150, "intro")
        let action = SkipPlanner.action(for: intro, in: [intro], durationSec: 1440)
        XCTAssertEqual(action, SkipAction(targetSec: 150, skipsToPostCredits: false))
    }

    func testCreditsRunningToTheEndOfTheFileHaveNoScene() {
        let credits = segment(1350, 1438, "ed")
        let action = SkipPlanner.action(for: credits, in: [credits], durationSec: 1440)
        XCTAssertEqual(action, SkipAction(targetSec: 1438, skipsToPostCredits: false))
    }

    func testTailLongerThanTheGapIsAPostCreditsScene() {
        let credits = segment(1290, 1380, "outro")
        let action = SkipPlanner.action(for: credits, in: [credits], durationSec: 1440)
        // No explicit scene: the credits are skipped, the tail plays.
        XCTAssertEqual(action, SkipAction(targetSec: 1380, skipsToPostCredits: true))
    }

    func testTailWithinTheGapIsNotAScene() {
        let credits = segment(1350, 1436, "outro")
        let action = SkipPlanner.action(for: credits, in: [credits], durationSec: 1440)
        XCTAssertEqual(action?.skipsToPostCredits, false)
    }

    func testExplicitPostCreditsSegmentIsTheTarget() {
        let credits = segment(1290, 1380, "outro")
        let scene = segment(1395, 1440, "post-credits")
        let action = SkipPlanner.action(for: credits, in: [credits, scene], durationSec: 1440)
        XCTAssertEqual(action, SkipAction(targetSec: 1395, skipsToPostCredits: true))
    }

    func testTheEarliestSceneAfterTheCreditsWins() {
        let credits = segment(1290, 1380, "outro")
        let late = segment(1420, 1440, "post-credits")
        let early = segment(1390, 1400, "post-credits")
        let before = segment(100, 110, "post-credits")   // before the credits end: not a scene after them
        let action = SkipPlanner.action(for: credits, in: [credits, late, before, early], durationSec: 1440)
        XCTAssertEqual(action?.targetSec, 1390)
    }

    func testPostCreditsOffersNoSkipOfItsOwn() {
        let scene = segment(1395, 1440, "post-credits")
        XCTAssertNil(SkipPlanner.action(for: scene, in: [scene], durationSec: 1440))
        XCTAssertNil(SkipPlanner.prompt(position: 1400, durationSec: 1440, segments: [scene]))
    }

    func testOpenEndedCreditsRunToTheEndOfTheFile() {
        // Anime-Skip's last timestamp has no end (a huge sentinel).
        let credits = segment(1350, .greatestFiniteMagnitude, "ed")
        let action = SkipPlanner.action(for: credits, in: [credits], durationSec: 1440)
        XCTAssertEqual(action, SkipAction(targetSec: 1440, skipsToPostCredits: false))
    }

    func testMovieCreditsNeedRealSeekTimes() {
        let open = segment(6000, .greatestFiniteMagnitude, "movie-credits")
        XCTAssertNil(SkipPlanner.action(for: open, in: [open], durationSec: 7200))
        let credits = segment(6900, 7100, "movie-credits")
        let scene = segment(7150, 7200, "post-credits")
        XCTAssertEqual(SkipPlanner.action(for: credits, in: [credits, scene], durationSec: 7200),
                       SkipAction(targetSec: 7150, skipsToPostCredits: true))
    }

    // MARK: - Chip

    func testPromptLabels() {
        let segments = [segment(60, 150, "op"), segment(200, 240, "recap"), segment(1290, 1380, "mixed-ed")]
        XCTAssertEqual(SkipPlanner.prompt(position: 100, durationSec: 1440, segments: segments)?.label,
                       SkipPlanner.label(forType: "intro", skipsToPostCredits: false))
        XCTAssertEqual(SkipPlanner.prompt(position: 210, durationSec: 1440, segments: segments)?.label,
                       String(localized: "Skip Recap"))
        // Credits followed by a tail read "Skip to Post-Credits" and flag it.
        let credits = SkipPlanner.prompt(position: 1300, durationSec: 1440, segments: segments)
        XCTAssertEqual(credits?.label, String(localized: "Skip to Post-Credits"))
        XCTAssertEqual(credits?.skipsToPostCredits, true)
        XCTAssertEqual(credits?.isCredits, true)
    }

    func testPromptIsGoneForTheLastSecondAndOutsideSegments() {
        let intro = segment(60, 150, "intro")
        XCTAssertNotNil(SkipPlanner.prompt(position: 60, durationSec: 1440, segments: [intro]))
        XCTAssertNil(SkipPlanner.prompt(position: 149.5, durationSec: 1440, segments: [intro]))
        XCTAssertNil(SkipPlanner.prompt(position: 30, durationSec: 1440, segments: [intro]))
    }

    func testAutoSkipKinds() {
        XCTAssertEqual(SkipPlanner.autoSkipKind(forType: "op"), "intro")
        XCTAssertEqual(SkipPlanner.autoSkipKind(forType: " Mixed-OP "), "intro")
        XCTAssertEqual(SkipPlanner.autoSkipKind(forType: "recap"), "recap")
        XCTAssertEqual(SkipPlanner.autoSkipKind(forType: "ending"), "outro")
        XCTAssertEqual(SkipPlanner.autoSkipKind(forType: "movie-credits"), "movie-credits")
        XCTAssertNil(SkipPlanner.autoSkipKind(forType: "post-credits"))
        XCTAssertNil(SkipPlanner.autoSkipKind(forType: "preview"))
    }

    // MARK: - Automatic Skipping

    private let all: Set<String> = ["intro", "recap", "outro"]

    private func tick(_ tracker: inout AutoSkipTracker, _ position: Double, at now: TimeInterval,
                      segments: [SkipSegment], kinds: Set<String>? = nil, playing: Bool = true,
                      duration: Double = 1440) -> AutoSkipTracker.Skip? {
        tracker.evaluate(position: position, durationSec: duration, now: now, isPlaying: playing,
                         segments: segments, enabledKinds: kinds ?? all)
    }

    func testSkipsAnEnabledSegmentOnceWhenPlaybackEntersIt() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        XCTAssertNil(tick(&tracker, 58.5, at: 0, segments: [intro]))
        XCTAssertNil(tick(&tracker, 59.0, at: 0.5, segments: [intro]))
        let skip = tick(&tracker, 60.0, at: 1, segments: [intro])
        XCTAssertEqual(skip?.action.targetSec, 150)
        XCTAssertEqual(skip?.kind, "intro")
        // The seek lands.
        XCTAssertNil(tick(&tracker, 150.2, at: 1.5, segments: [intro]))
    }

    func testNothingIsSkippedWhenTheKindIsNotSelected() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        XCTAssertNil(tick(&tracker, 59.5, at: 0, segments: [intro], kinds: ["recap"]))
        XCTAssertNil(tick(&tracker, 60.0, at: 0.5, segments: [intro], kinds: ["recap"]))
        XCTAssertNil(tick(&tracker, 60.5, at: 1, segments: [intro], kinds: []))
    }

    func testPausedPlaybackIsNeverSkipped() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        XCTAssertNil(tick(&tracker, 59.5, at: 0, segments: [intro]))
        XCTAssertNil(tick(&tracker, 60.5, at: 0.5, segments: [intro], playing: false))
        XCTAssertNotNil(tick(&tracker, 61.0, at: 1, segments: [intro], playing: true))
    }

    func testASegmentIsNotSkippedTwiceAfterABackwardSeek() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        XCTAssertNil(tick(&tracker, 59.5, at: 0, segments: [intro]))
        XCTAssertNotNil(tick(&tracker, 60.2, at: 0.5, segments: [intro]))
        XCTAssertNil(tick(&tracker, 150.4, at: 1, segments: [intro]))
        // The viewer seeks back to the start of the intro and plays through it.
        XCTAssertNil(tick(&tracker, 40, at: 10, segments: [intro]))
        XCTAssertNil(tick(&tracker, 40.5, at: 10.5, segments: [intro]))
        XCTAssertNil(tick(&tracker, 60.0, at: 30, segments: [intro]))
        XCTAssertNil(tick(&tracker, 61.0, at: 31, segments: [intro]))
    }

    func testSeekingIntoASegmentLeavesItToTheViewer() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        XCTAssertNil(tick(&tracker, 10, at: 0, segments: [intro]))
        // A click-seek / scrub commit lands mid-intro: the viewer chose to be there.
        XCTAssertNil(tick(&tracker, 100, at: 0.5, segments: [intro]))
        XCTAssertNil(tick(&tracker, 100.5, at: 1, segments: [intro]))
    }

    func testResumingInsideASegmentSkipsTheRestOfIt() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        // First tick of the session already inside the intro (segments loaded late).
        XCTAssertEqual(tick(&tracker, 75, at: 0, segments: [intro])?.action.targetSec, 150)
    }

    func testChainedSegmentsAreBothSkipped() {
        var tracker = AutoSkipTracker()
        let recap = segment(0, 40, "recap")
        let intro = segment(40, 120, "intro")
        let segments = [recap, intro]
        XCTAssertEqual(tick(&tracker, 1, at: 0, segments: segments)?.kind, "recap")
        // Still travelling to the recap's end: nothing else happens.
        XCTAssertNil(tick(&tracker, 1.5, at: 0.5, segments: segments))
        // Landed on the intro's first frames: it is skipped too, not mistaken for a viewer's seek.
        XCTAssertNil(tick(&tracker, 40.0, at: 1, segments: segments))
        XCTAssertEqual(tick(&tracker, 40.5, at: 1.5, segments: segments)?.kind, "intro")
    }

    func testASeekThatNeverLandsDoesNotWedgeTheTracker() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        let credits = segment(1290, 1380, "outro")
        XCTAssertNil(tick(&tracker, 59.5, at: 0, segments: [intro, credits]))
        XCTAssertNotNil(tick(&tracker, 60.2, at: 0.5, segments: [intro, credits]))
        // Stuck in place for longer than the timeout: the tracker resumes normal evaluation.
        XCTAssertNil(tick(&tracker, 60.6, at: 1, segments: [intro, credits]))
        XCTAssertNil(tick(&tracker, 61.0, at: 6, segments: [intro, credits]))
        XCTAssertNil(tick(&tracker, 61.5, at: 6.5, segments: [intro, credits]))
    }

    func testPostCreditsIsNeverSkippedOnItsOwn() {
        var tracker = AutoSkipTracker()
        let credits = segment(1290, 1380, "outro")
        let scene = segment(1395, 1440, "post-credits")
        let segments = [credits, scene]
        XCTAssertNil(tick(&tracker, 1389.5, at: 0, segments: segments, kinds: all.union(["post-credits"])))
        XCTAssertNil(tick(&tracker, 1396, at: 0.5, segments: segments, kinds: all.union(["post-credits"])))
        XCTAssertNil(tick(&tracker, 1397, at: 1, segments: segments, kinds: all.union(["post-credits"])))
    }

    func testCreditsFollowedBySceneSkipToTheScene() {
        var tracker = AutoSkipTracker()
        let credits = segment(1290, 1380, "outro")
        let scene = segment(1395, 1440, "post-credits")
        XCTAssertNil(tick(&tracker, 1289.5, at: 0, segments: [credits, scene]))
        let skip = tick(&tracker, 1290.5, at: 0.5, segments: [credits, scene])
        XCTAssertEqual(skip?.action, SkipAction(targetSec: 1395, skipsToPostCredits: true))
    }

    func testResetForgetsWhatWasSkipped() {
        var tracker = AutoSkipTracker()
        let intro = segment(60, 150, "intro")
        XCTAssertNil(tick(&tracker, 59.5, at: 0, segments: [intro]))
        XCTAssertNotNil(tick(&tracker, 60.2, at: 0.5, segments: [intro]))
        tracker.reset()
        XCTAssertNotNil(tick(&tracker, 61, at: 1, segments: [intro]))
    }
}
