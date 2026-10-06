import XCTest

/// Phase 0 soak harness for the BUG-46 trailer-pipeline leak investigation (and a UX-9 zoom
/// measurement prerequisite — see the plan's 0.7 decision gate). This test doesn't assert
/// anything about the leak itself; it exists to drive rapid dwell/expand/teardown churn across
/// Home's rows while the Phase 0 instrumentation (`TrailerDebugProbes.swift`,
/// `TrailerHeroPlayerView.swift`, `InlineTrailerCard.swift`, `TrailerLocalHLS.swift`) captures
/// `[TrailerPipeline]`/`[TrailerRepack]` log lines. A human/agent harvests and reads that stream
/// afterwards — same philosophy as the rest of this UI-test harness (see `NuvioTVUITests`'
/// type doc: "tests are deliberately tolerant... a human (or agent) reviews the exported
/// attachments afterwards").
///
/// Harvest after the run:
///
///     xcrun simctl spawn booted log show --last 15m \
///       --predicate 'eventMessage CONTAINS "[TrailerPipeline]"'
///
/// (swap the predicate for `"[TrailerRepack]"` to read the token mint/evict/404 stream instead —
/// same trick the UX-4c probes rely on: NSLog lands in unified logging even with no console pty
/// attached, see `TrailerHeroPlayerView.swift`'s `[TrailerQuality]` lines.)
///
/// Helper methods here are a trimmed COPY of `NuvioTVUITests`' (`launchToHome`, `press`, `pause`,
/// `shot`) rather than a shared import — they're `private` to that file, and this harness already
/// accepts duplication over factoring out cross-file test helpers (see
/// `NuvioTVUITests.test18FocusedSettingsRowLegibility`'s doc comment). This copy of
/// `launchToHome` is deliberately simpler: always a fresh `launch()`, no suite-order recovery
/// dance, because every test in this file needs the trailer debug launch arguments to actually be
/// in effect and a `forceFreshLaunch`-style full relaunch is the only way to guarantee that.
final class TrailerSoakTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers (see type doc for why these are duplicated, not shared)

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    @discardableResult
    private func launchToHome(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        app.launch()
        // Session restore + profile fetch can take well past 15s on a cold sim launch (same
        // wait NuvioTVUITests.launchToHome uses).
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    /// The UX-4c smoke id (`DetailViewModel.swift`'s own doc comment) — a known bar-free 16:9
    /// trailer already used elsewhere in this codebase for deterministic sim verification, so
    /// reusing it here needs no new fixture.
    private static let smokeVideoId = "rNZ0xKaCdus"

    /// `-inline_trailers_enabled` (opt-in, default OFF — same argument-domain trick
    /// `NuvioTVUITests.test01InlineTrailerDwell` uses) plus the two Phase 0 knobs, passed as
    /// launch arguments rather than a separate `xcrun simctl spawn booted defaults write` step
    /// (the plan's 0.6 documents that shell form for a manual/device run) so the whole soak is a
    /// normal, self-contained `xcodebuild test` invocation.
    private func trailerSoakLaunchArguments() -> [String] {
        [
            "-inline_trailers_enabled", "YES",
            "-debug.trailerProbe", "YES",
            "-debug.trailerSmokeVideoId", Self.smokeVideoId,
            // Deterministic row geometry (Codex, Wave 13 follow-up): the Home Upcoming row is
            // OPTIONAL — present only when the toggle is on AND the followed-shows feed is
            // non-empty — so any fixed Down-press count that assumes it (or assumes its absence)
            // can silently walk a non-trailer row and turn every profile vacuously green
            // (2026-08-19: down×4 rested on the Streaming logo row with the row present; zero
            // `[TrailerPipeline] focus` lines, gates open). Forcing the row OFF via the argument
            // domain (same trick as `-inline_trailers_enabled`; plain `@AppStorage` key, always
            // wins reads) pins the pre-Upcoming layout the down×4 walks were written against.
            "-home_upcoming_row_enabled", "NO",
        ]
    }

    // MARK: - Profile 1: fast scrub (negative control — nothing should ever attach)

    /// Scrubs across a row faster than the 1s dwell gate on every hop, so every card's dwell timer
    /// should get cancelled before `InlineTrailerCardModel.expand()` ever fires. A HEALTHY run
    /// produces zero `[TrailerPipeline] attach` lines for this profile — that read is manual (see
    /// the type doc); this test only proves the walk itself survives.
    func testFastScrubProfile() throws {
        let app = launchToHome(extraArguments: trailerSoakLaunchArguments())
        // The Upcoming row is forced OFF by the launch arguments (see
        // `trailerSoakLaunchArguments`), so this is the pre-Upcoming row geometry these walks
        // were written against — a wrong count here walks a non-trailer row and the profile
        // goes vacuously green (2026-08-19: zero `[TrailerPipeline] focus` lines, gates open).
        press(.down, times: 4)
        shot(app, "soak_scrub_00_row_focused")

        for i in 1...40 {
            press(.right, times: 1, gap: 0.3)
            if i % 10 == 0 { shot(app, "soak_scrub_\(i)_checkpoint") }
        }
        pause(2)
        shot(app, "soak_scrub_done")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the fast-scrub walk")
    }

    // MARK: - Profile 2: dwell-play-leave (the leak-forcing loop)

    /// The plan's leak-forcing loop: dwell long enough to expand + attach a live player, let
    /// playback actually start (attach happens at `.playing`, not at dwell-expand — the plan's
    /// own framing), then leave immediately — teardown mid-play, repeated across many distinct
    /// titles. A HEALTHY build (post a later phase's teardown-parity fix) has
    /// `liveViews`/`livePlayers` oscillate 0↔1 at rest; the CURRENT (pre-fix) build is expected to
    /// show it climb instead — that comparison is the whole point of running this pre- and
    /// post-fix, not something this test asserts directly.
    ///
    /// Row hops (down every 8th iteration, up every 4th-of-8) keep the walk from hammering a
    /// single row's now-cache-warm titles for the whole soak. With the smoke video id forced,
    /// every dwell is still a FRESH extraction/repack per distinct title (the substitution in
    /// `InlineTrailerCardModel.resolve()` happens after the cache key is derived), so 40
    /// iterations across multiple rows drives many distinct `TrailerLocalHLS` tokens — approaching
    /// the pre-fix 64-token cap the plan's decision gate (0.7) reads `[TrailerRepack]` eviction
    /// lines against.
    func testDwellPlayLeaveSoak() throws {
        let app = launchToHome(extraArguments: trailerSoakLaunchArguments())
        // The Upcoming row is forced OFF by the launch arguments (see
        // `trailerSoakLaunchArguments`), so this is the pre-Upcoming row geometry these walks
        // were written against — a wrong count here walks a non-trailer row and the profile
        // goes vacuously green (2026-08-19: zero `[TrailerPipeline] focus` lines, gates open).
        press(.down, times: 4)
        shot(app, "soak_dwell_00_row_focused")

        let totalIterations = 40
        for i in 1...totalIterations {
            if i % 8 == 0 {
                press(.down, times: 1, gap: 0.6)
            } else if i % 8 == 4 {
                press(.up, times: 1, gap: 0.6)
            }

            press(.right, times: 1, gap: 1.4) // clears the 1.0s dwell + ~0.35s morph settle
            pause(3.0)                        // let playback actually start (attach at .playing)
            press(.right, times: 1, gap: 0.2) // leave immediately: teardown mid-play

            if i % 10 == 0 {
                shot(app, "soak_dwell_\(i)_checkpoint")
            }
        }

        // End-state check — the plan's BUG-46 symptom check: sit on one more card long enough for
        // a trailer to resolve and start, and confirm the app is still alive and responsive.
        // Tolerant per harness style: there's no public probe for `InlineTrailerCardModel.phase`,
        // so this can't hard-assert `.playing` — the `[TrailerPipeline]` log stream (harvested
        // separately, see the type doc) is the actual oracle for whether playback reached it.
        press(.right, times: 1, gap: 1.4)
        pause(5)
        shot(app, "soak_dwell_final_settle")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the dwell-play-leave soak and still be responsive on the final card")
    }

    // MARK: - Profile 3: short dwell × 2 launches (BUG-59 zoom learn + persisted-hit)

    /// BUG-59 (beta.13): the reporter's browsing shape — sit on a card for ~1.5 s after playback
    /// starts, move on — then relaunch and revisit the same cards. Read from the harvested log:
    ///
    ///   * launch 1: a `[TrailerZoom] interim` line within ~0.75 s of each `[TrailerPipeline] play`
    ///     and NO `insufficient` lines with `interimApplied=0` (the pre-fix "floor kept" signature);
    ///     `final … persisted=1` where the dwell was long enough (span ≥ 1 s).
    ///   * launch 2: `[TrailerZoom] persisted-hit key=… token=match` BEFORE any sample line for the
    ///     revisited cards, and `store loaded n=` > 0 at launch.
    ///
    ///     xcrun simctl spawn booted log show --last 10m \
    ///       --predicate 'eventMessage CONTAINS "[TrailerZoom]"'
    ///
    /// The forced smoke videoId is on (paired with `-debug.trailerProbe`, which is now REQUIRED
    /// for it to be honored), so every card shares one stream and the numbers are comparable.
    func testShortDwellZoomProfile() throws {
        for launch in 1...2 {
            let app = launchToHome(extraArguments: trailerSoakLaunchArguments())
            // The Upcoming row is forced OFF by the launch arguments (see
        // `trailerSoakLaunchArguments`), so this is the pre-Upcoming row geometry these walks
        // were written against — a wrong count here walks a non-trailer row and the profile
        // goes vacuously green (2026-08-19: zero `[TrailerPipeline] focus` lines, gates open).
        press(.down, times: 4)
            shot(app, "soak_zoom_launch\(launch)_row_focused")
            // Outbound: learn. The sim's local-HLS startup after extraction is ~2–3 s, so the dwell
            // has to outlast that AND leave ≥1 s of playing time for the span-guarded final.
            for i in 1...5 {
                press(.right, times: 1, gap: 1.4) // clears the 1.0 s dwell + morph settle
                pause(6.0)
                if i == 3 { shot(app, "soak_zoom_launch\(launch)_card\(i)") }
            }
            // Inbound: revisit the SAME cards — each re-dwell should log `persisted-hit … token=match`
            // before any sample line (same store, same title, same forced stream). Four moves, not
            // five: the fifth would land on the row's first card, which the outbound pass never
            // dwelt on.
            for _ in 1...4 {
                press(.left, times: 1, gap: 1.4)
                pause(3.0)
            }
            XCTAssertTrue(app.state == .runningForeground, "app must survive the short-dwell zoom profile (launch \(launch))")
            app.terminate()
            pause(1.0)
        }
    }

    // MARK: - Profile 4: cold-store first dwell (BUG-59 reveal gate — "no barred frame ever")

    /// The reveal-gate invariant, driven from its worst case: a store with NO memory of any title
    /// (launch 1 passes `-debug.resetTrailerZoomStore`, honored only alongside the probe knob),
    /// so every dwell is a first-ever play — exactly the window where pre-gate builds showed a
    /// letterboxed source's bars for ~1 s before zooming. The dense screenshot burst over each
    /// dwell's first ~4.5 s is the visual oracle: an agent reads the attachments and asserts that
    /// NO frame shows black bars inside the focus tile — the tile shows static art until the
    /// video appears already-cropped. Launch 2 revisits with the store intact: reveals must be
    /// instant (`persisted-hit … token=match`, no conceal at all).
    ///
    /// Log oracle (harvest as in the type doc, predicate `"[TrailerZoom]"`):
    ///
    ///   * launch 1: `store reset (debug.resetTrailerZoomStore)` at launch; per play, a
    ///     `reveal reason=interim|cap` line and NEVER `reveal` before that play's `interim` /
    ///     `persisted-hit` / 12th frame-bearing tick (`reason=cap frameTicks=12` is the ~3 s-of-
    ///     delivered-frames ceiling — wall-clock ticks may read higher on a slow startup);
    ///   * launch 2: `persisted-hit … token=match` per revisit and ZERO `reveal` lines for those
    ///     plays (a persisted-hit surface is never concealed, so there is nothing to reveal).
    func testColdStoreFirstDwellRevealProfile() throws {
        for launch in 1...2 {
            var arguments = trailerSoakLaunchArguments()
            if launch == 1 {
                arguments += ["-debug.resetTrailerZoomStore", "YES"]
            }
            let app = launchToHome(extraArguments: arguments)
            // The Upcoming row is forced OFF by the launch arguments (see
            // `trailerSoakLaunchArguments`), pinning the row geometry this count assumes.
            press(.down, times: 4)
            shot(app, "soak_reveal_launch\(launch)_row_focused")

            for card in 1...3 {
                press(.right, times: 1, gap: 1.4) // clears the 1.0 s dwell + morph settle
                // Burst across the resolve → conceal → reveal window: extraction + local-HLS
                // startup is ~2–3 s on the sim, the interim ~0.5–1.5 s after play, the cap at 3 s
                // — 12 shots at ~0.4 s cover all of it.
                for frame in 1...12 {
                    pause(0.4)
                    shot(app, String(format: "soak_reveal_launch%d_card%d_t%02d", launch, card, frame))
                }
                pause(2.0) // let the span-guarded final land + persist before moving on
            }
            XCTAssertTrue(app.state == .runningForeground, "app must survive the cold-store reveal profile (launch \(launch))")
            app.terminate()
            pause(1.0)
        }
    }
}
