import XCTest
@testable import NuvioTV

/// Ambient Mode: the idle clock, the press gate that keeps the wake-up press away from the focused
/// card, the settings store, and the rules that pick and move the slides. All pure, so they run
/// without a view or a remote.
@MainActor
final class AmbientModeTests: XCTestCase {

    // MARK: - Settings

    func testTimeoutIsClampedToOneThroughThirtyMinutes() {
        XCTAssertEqual(AmbientModeSettings.clampedMinutes(0), 1)
        XCTAssertEqual(AmbientModeSettings.clampedMinutes(-4), 1)
        XCTAssertEqual(AmbientModeSettings.clampedMinutes(7), 7)
        XCTAssertEqual(AmbientModeSettings.clampedMinutes(90), 30)
        XCTAssertEqual(AmbientModeSettings(enabled: true, timeoutMinutes: 2, catalogKeys: []).timeout, 120)
    }

    func testCatalogKeysAreDistinctOrderedAndCappedAtThree() {
        let keys = ["a", "b", "a", "", "c", "d", "e"]
        XCTAssertEqual(AmbientModeSettings.normalizedKeys(keys), ["a", "b", "c"])
    }

    func testStoreRoundTripsAndDefaultsToOff() throws {
        let suite = "AmbientModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = AmbientModeStore.load(defaults)
        XCTAssertFalse(fresh.enabled)
        XCTAssertEqual(fresh.timeoutMinutes, AmbientModeSettings.defaultTimeoutMinutes)
        XCTAssertEqual(fresh.catalogKeys, [])

        let saved = AmbientModeSettings(enabled: true, timeoutMinutes: 10, catalogKeys: ["x:movie:top", "y:series:new"])
        AmbientModeStore.save(saved, to: defaults)
        XCTAssertEqual(AmbientModeStore.load(defaults), saved)
    }

    func testMalformedCatalogKeysReadAsNone() {
        XCTAssertEqual(AmbientModeStore.decodeKeys("not json"), [])
        XCTAssertEqual(AmbientModeStore.decodeKeys(nil), [])
        XCTAssertEqual(AmbientModeStore.decodeKeys("[\"a\",\"b\"]"), ["a", "b"])
    }

    func testModelRefusesAFourthCatalog() throws {
        let suite = "AmbientModeTests.model.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AmbientModeSettingsModel(defaults: defaults)

        XCTAssertTrue(model.setCatalog("a", selected: true))
        XCTAssertTrue(model.setCatalog("b", selected: true))
        XCTAssertTrue(model.setCatalog("c", selected: true))
        XCTAssertFalse(model.setCatalog("d", selected: true))
        XCTAssertTrue(model.setCatalog("a", selected: true), "an already chosen catalog is not a fourth")
        XCTAssertEqual(model.settings.catalogKeys, ["a", "b", "c"])
        XCTAssertTrue(model.setCatalog("b", selected: false))
        XCTAssertTrue(model.setCatalog("d", selected: true))
        XCTAssertEqual(model.settings.catalogKeys, ["a", "c", "d"])
    }

    // MARK: - Conditions

    func testClockOnlyRunsWhenNothingElseOwnsTheScreen() {
        var ready = AmbientConditions(enabled: true, shellActive: true)
        XCTAssertTrue(ready.isEligible)

        ready.idleTimerHeldByOthers = true
        XCTAssertFalse(ready.isEligible, "a player or Remote Setup holds the screen awake")
        ready.idleTimerHeldByOthers = false

        ready.coverPresented = true
        XCTAssertFalse(ready.isEligible, "a sheet, the trailer or the stream picker is up")
        ready.coverPresented = false

        ready.trailerPlaying = true
        XCTAssertFalse(ready.isEligible)
        ready.trailerPlaying = false

        ready.voiceOverRunning = true
        XCTAssertFalse(ready.isEligible)
        ready.voiceOverRunning = false

        ready.appActive = false
        XCTAssertFalse(ready.isEligible)
        ready.appActive = true

        ready.shellActive = false
        XCTAssertFalse(ready.isEligible, "the profile picker is not Home")
        ready.shellActive = true

        ready.enabled = false
        XCTAssertFalse(ready.isEligible)
    }

    // MARK: - Press gate

    func testWakeUpPressIsSwallowedThroughItsRelease() {
        var gate = AmbientInputGate()
        let t0 = Date(timeIntervalSince1970: 1000)

        let down = gate.process(.init(endsInteraction: false), showing: true, now: t0)
        XCTAssertEqual(down, .init(swallow: true, dismiss: true))

        // The slideshow is gone by the time the release arrives; it must still not reach the card.
        let up = gate.process(.init(endsInteraction: true), showing: false, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(up, .init(swallow: true, dismiss: false))

        let next = gate.process(.init(endsInteraction: false), showing: false, now: t0.addingTimeInterval(1))
        XCTAssertEqual(next, .init(swallow: false, dismiss: false), "the next press is the user's again")
    }

    func testAnInstantTapLeavesNothingToSwallow() {
        var gate = AmbientInputGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.process(.init(endsInteraction: true), showing: true, now: t0)
        XCTAssertNil(gate.swallowDeadline)
        let after = gate.process(.init(endsInteraction: false), showing: false, now: t0.addingTimeInterval(0.2))
        XCTAssertFalse(after.swallow)
    }

    func testSwallowingExpiresIfTheReleaseNeverComes() {
        var gate = AmbientInputGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.process(.init(endsInteraction: false), showing: true, now: t0)
        let late = gate.process(.init(endsInteraction: false), showing: false,
                                now: t0.addingTimeInterval(AmbientInputGate.swallowWindow + 0.5))
        XCTAssertFalse(late.swallow, "a lost release must not leave the remote dead")
    }

    func testInputPassesWhileNothingIsShowing() {
        var gate = AmbientInputGate()
        let decision = gate.process(.init(endsInteraction: false), showing: false, now: Date())
        XCTAssertEqual(decision, .init(swallow: false, dismiss: false))
    }

    // MARK: - Idle controller

    private func makeController(_ clock: Clock) -> AmbientIdleController {
        let controller = AmbientIdleController(clock: { clock.now })
        controller.shellActive = true
        controller.slideProvider = { [Self.slide("a")] }
        return controller
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 10_000)
    }

    private static func slide(_ id: String) -> AmbientSlide {
        AmbientSlide(id: id, title: id, backdropURL: URL(string: "https://example.com/\(id).jpg")!,
                     logoURL: nil, genres: [])
    }

    private let oneMinute = AmbientModeSettings(enabled: true, timeoutMinutes: 1, catalogKeys: [])
    private let ready = AmbientConditions()

    func testSlideshowStartsOnceTheDelayHasPassed() {
        let clock = Clock()
        let controller = makeController(clock)

        clock.now.addTimeInterval(59)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertFalse(controller.isShowing)

        clock.now.addTimeInterval(2)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertTrue(controller.isShowing)
        XCTAssertEqual(controller.slides.map(\.id), ["a"])
    }

    func testRemoteActivityRestartsTheDelay() {
        let clock = Clock()
        let controller = makeController(clock)

        clock.now.addTimeInterval(50)
        XCTAssertFalse(controller.intercept(.init(endsInteraction: false)))
        clock.now.addTimeInterval(50)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertFalse(controller.isShowing, "100 s since start, but only 50 s since the last press")

        clock.now.addTimeInterval(11)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertTrue(controller.isShowing)
    }

    func testAPressWhileShowingDismissesAndRestartsTheClock() {
        let clock = Clock()
        let controller = makeController(clock)
        clock.now.addTimeInterval(61)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertTrue(controller.isShowing)

        XCTAssertTrue(controller.intercept(.init(endsInteraction: false)), "the wake-up press is swallowed")
        XCTAssertFalse(controller.isShowing)

        clock.now.addTimeInterval(30)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertFalse(controller.isShowing, "the delay counts from the press, not from before")
    }

    func testAPlayerOnScreenHoldsTheClockAtZero() {
        let clock = Clock()
        let controller = makeController(clock)
        var playing = ready
        playing.idleTimerHeldByOthers = true

        clock.now.addTimeInterval(3600)
        controller.tick(settings: oneMinute, conditions: playing)
        XCTAssertFalse(controller.isShowing)

        // The player closes: the delay starts now, not an hour ago.
        clock.now.addTimeInterval(5)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertFalse(controller.isShowing)
        clock.now.addTimeInterval(56)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertTrue(controller.isShowing)
    }

    func testSlideshowGoesAwayWhenSomethingElseTakesTheScreen() {
        let clock = Clock()
        let controller = makeController(clock)
        clock.now.addTimeInterval(61)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertTrue(controller.isShowing)

        var covered = ready
        covered.coverPresented = true
        controller.tick(settings: oneMinute, conditions: covered)
        XCTAssertFalse(controller.isShowing)
    }

    func testTurningTheFeatureOffStopsIt() {
        let clock = Clock()
        let controller = makeController(clock)
        clock.now.addTimeInterval(61)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertTrue(controller.isShowing)

        var off = oneMinute
        off.enabled = false
        controller.tick(settings: off, conditions: ready)
        XCTAssertFalse(controller.isShowing)
    }

    func testNothingStartsWithoutSlides() {
        let clock = Clock()
        let controller = makeController(clock)
        controller.slideProvider = { [] }
        clock.now.addTimeInterval(120)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertFalse(controller.isShowing, "an empty slideshow would be a black screen")
    }

    func testNextWakeIsBoundedSoSettingChangesAreNoticed() {
        let clock = Clock()
        let controller = makeController(clock)
        var thirtyMinutes = oneMinute
        thirtyMinutes.timeoutMinutes = 30
        let delay = controller.tick(settings: thirtyMinutes, conditions: ready)
        XCTAssertEqual(delay, AmbientIdleController.maxWake)
    }

    func testNoShellMeansNoSlideshow() {
        let clock = Clock()
        let controller = makeController(clock)
        controller.shellActive = false
        clock.now.addTimeInterval(600)
        controller.tick(settings: oneMinute, conditions: ready)
        XCTAssertFalse(controller.isShowing)
    }

    // MARK: - Slides

    private func candidate(_ id: String, backdrop: String? = "https://example.com/b.jpg",
                           genres: [String] = []) -> AmbientCandidate {
        AmbientCandidate(type: "movie", id: id, title: id, backdrop: backdrop, logo: nil, genres: genres)
    }

    func testRowsAreInterleavedSoEveryCatalogShowsUpEarly() {
        let rows = [
            [candidate("a1"), candidate("a2"), candidate("a3")],
            [candidate("b1")],
            [candidate("c1"), candidate("c2")],
        ]
        let slides = AmbientSlideBuilder.slides(rows: rows, shuffled: false)
        XCTAssertEqual(slides.map(\.title), ["a1", "b1", "c1", "a2", "c2", "a3"])
    }

    func testRepeatsAndItemsWithoutWideArtworkAreDropped() {
        let rows = [
            [candidate("a"), candidate("poster-only", backdrop: nil), candidate("blank", backdrop: "  ")],
            [candidate("a"), candidate("b")],
        ]
        let slides = AmbientSlideBuilder.slides(rows: rows, shuffled: false)
        XCTAssertEqual(slides.map(\.title), ["a", "b"])
    }

    func testSlideCountAndGenresAreCapped() {
        let many = (0..<80).map { candidate("t\($0)", genres: ["1", "2", "3", "4", "5"]) }
        let slides = AmbientSlideBuilder.slides(rows: [many], shuffled: false)
        XCTAssertEqual(slides.count, AmbientSlideBuilder.maxSlides)
        XCTAssertEqual(slides.first?.genres, ["1", "2", "3"])
    }

    // MARK: - Motion

    func testMotionNeverRepeatsTheLastMove() {
        var generator = SystemRandomNumberGenerator()
        var previous: AmbientMotion?
        for _ in 0..<200 {
            let next = AmbientMotion.next(after: previous, using: &generator)
            XCTAssertNotEqual(next, previous)
            XCTAssertTrue(AmbientMotion.all.contains(next))
            previous = next
        }
    }

    func testMotionInterpolatesScaleAndDrift() {
        let motion = AmbientMotion(startScale: 1, endScale: 1.1, startX: -0.02, endX: 0.02, startY: 0, endY: 0.04)
        XCTAssertEqual(motion.scale(at: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(motion.scale(at: 1), 1.1, accuracy: 0.0001)
        let middle = motion.offset(at: 0.5, in: CGSize(width: 1000, height: 500))
        XCTAssertEqual(middle.width, 0, accuracy: 0.0001)
        XCTAssertEqual(middle.height, 10, accuracy: 0.0001)
        XCTAssertEqual(AmbientMotion.still.scale(at: 0.7), 1, accuracy: 0.0001)
    }
}
