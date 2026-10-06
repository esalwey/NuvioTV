import XCTest

/// BUG-41 (Wave F, item D) automated coverage for `DetailView`'s scroll-choppiness attribution
/// signals — `debug_ux6`'s `trailer=`/`glass=`/`ab=` tokens (appended alongside the pre-existing
/// `dark=` token) and the live-read contract on `debug.detailScrollAB`/`debug.detailScrollProbe`
/// that the About > Trailer Diagnostics pane's pickers (F-C) depend on to work without a relaunch.
///
/// Same philosophy as `TrailerSoakTests`/`GuestTrailerRevealScratchTests` (see their type docs):
/// helpers are a trimmed, file-private COPY rather than a shared import, tests stay tolerant of
/// catalog/fixture drift (the hero title opened here may or may not carry a trailer on any given
/// run — see `smokeVideoId`'s doc comment), and anything that needs the app process's OWN console
/// output is a documented HARVEST step run separately from a host shell, not an in-test assertion —
/// the UI test bundle runs inside the simulator sandbox (no `xcrun`/`log` binary to shell out to),
/// and `xcodebuild test` does not capture the app's own stdout/NSLog stream (the exact limitation
/// `TrailerSoakTests`' `[TrailerPipeline]`/`[TrailerZoom]` harvesting instructions work around).
///
/// Harvest the `[BUG41] detailBodyEval=…` counter after a `-debug.detailScrollProbe YES` run
/// (`testDetailScrollProbeBodyEvalGrowthLogHarvest` below drives the scroll; it does not, and
/// cannot, assert on the counter itself):
///
///     xcrun simctl spawn <udid> log show --last 2m \
///       --predicate 'eventMessage CONTAINS "BUG41"'
///
/// A healthy build's `detailBodyEval` should grow by at most ~1 per D-pad press once the initial
/// page settle has passed — `DetailView.logBodyEval()` only logs every 10th eval, so read the
/// printed sequence's deltas across the 10-press windows that test drives, not single presses.
final class DetailScrollProbeTests: XCTestCase {

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
        // Session restore + profile fetch can take well past 15 s on a cold sim launch (same wait
        // `TrailerSoakTests.launchToHome`/`NuvioTVUITests.launchToHome` use).
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    /// The UX-4c smoke id (also used by `TrailerSoakTests`/`GuestTrailerRevealScratchTests`) — a
    /// known bar-free 16:9 trailer, so any title that has SOME trailer metadata resolves a
    /// deterministic stream instead of whatever YouTube video its own addon/TMDB data carries.
    /// `DetailViewModel.resolveTrailerIfNeeded` only substitutes it once `meta.trailers` is
    /// non-empty for the opened title — it cannot manufacture a trailer for a title with none, so
    /// these tests stay tolerant of `trailer=0` at baseline rather than hard-depending on it (see
    /// each test's own note on which assertions that affects).
    private static let smokeVideoId = "rNZ0xKaCdus"

    private func detailScrollProbeLaunchArguments(scrollProbe: Bool = false, ab leg: Int? = nil) -> [String] {
        var args = [
            "-debug.trailerProbe", "YES",
            "-debug.trailerSmokeVideoId", Self.smokeVideoId,
        ]
        if scrollProbe {
            args += ["-debug.detailScrollProbe", "YES"]
        }
        if let leg {
            args += ["-debug.detailScrollAB", String(leg)]
        }
        return args
    }

    /// Reads `debug_ux6`'s live label — `"debug_ux6 dark=<n> trailer=<0|1> glass=<0|1> ab=<leg>"`
    /// (`ScrollDimOverlay`, `DetailView.swift`) — attaching it for the run log the way
    /// `NuvioTVUITests.ux6Probe` does, plus parsing the four tokens into a dictionary for
    /// assertions.
    @discardableResult
    private func ux6Probe(_ app: XCUIApplication, _ name: String) -> [String: Int] {
        let probe = app.staticTexts["debug_ux6"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_ux6 MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[BUG41] \(name): \(text)")

        var tokens: [String: Int] = [:]
        for part in text.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let value = Int(kv[1]) else { continue }
            tokens[String(kv[0])] = value
        }
        return tokens
    }

    /// Opens a detail page from the Home hero CTA — the exact navigation
    /// `NuvioTVUITests.test17DetailScrollDarkening` uses (up×6, down×1, select) — so this reaches a
    /// reliably-focusable entry point rather than depending on a specific catalog row/title. The
    /// extra settle beyond `test17`'s own `pause(8)` gives the hero trailer's resolve chain (TMDB/
    /// addon trailer list → YouTube extraction → local HLS repack) more room to land before the
    /// first `ux6Probe` baseline read — a slow resolve otherwise reads as a false `trailer=0`.
    ///
    /// Also waits (bounded) for the "Cast" row — a signal that `model.meta` has fully arrived —
    /// before returning: `castRow`/`companyLogosRow`/`parentalGuideSection`/etc. are all gated on
    /// `model.meta` being non-nil, so a scroll-depth assertion taken before that lands only has the
    /// short `topBlock` to scroll through, which can't reach the 400pt dim ceiling no matter how
    /// many D-pad downs follow — a 2026-09-04 run hit exactly this (`dark` stuck at 0 after 8
    /// downs) with the previous fixed `pause(12)`.
    private func openDetailFromHomeHero(_ app: XCUIApplication) {
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        remote.press(.select)
        pause(6)
        var waited: TimeInterval = 0
        while !app.staticTexts["Cast"].exists, waited < 14 {
            pause(1)
            waited += 1
        }
        pause(2)
    }

    /// Deterministic alternative to `openDetailFromHomeHero`: searches for a specific, known-in-
    /// this-fixture title (`"Les Condés"`) and opens it, instead of trusting whatever the Home
    /// hero carousel happens to have pinned right now. A 2026-09-04 investigation found the Home
    /// hero item on this fixture has almost no scrollable content — `dark` (the UX-6 scroll-dim
    /// value) stayed at 0 across THREE full batches of 8 down-presses (24 total) opened via
    /// `openDetailFromHomeHero`, in every test that relied on it — while "Les Condés", opened via
    /// Search the same session, reached the FULL 0.85 ceiling (`dark=850`) after just 4 down-
    /// presses. That is a property of the currently-pinned hero item's metadata (few/no genres, no
    /// cast/company/parental-guide rows), not a `DetailView` regression — but it makes the hero path
    /// unusable for any assertion that depends on the page actually being scrollable. Tests that
    /// need `dark` to move use this helper instead; `testDetailScrollABLegFourIsReadCorrectly` keeps
    /// the hero path since leg 4 pins `dark` to 0 regardless of content, so hero sparsity is moot
    /// there.
    private func openDeterministicContentRichDetail(_ app: XCUIApplication) {
        openTabByName(app, "Search")
        pause(1.5)
        _ = typeIntoSearchField(app, "Les Condés")
        openFirstSearchResult(app)
        var waited: TimeInterval = 0
        while !app.staticTexts["debug_ux6"].exists, waited < 15 {
            pause(1)
            waited += 1
        }
        pause(2)
    }

    // MARK: - Dim/trailer/glass hysteresis across a scroll pass (items 1, 2, 4)

    /// BUG-41 items 1/2/4: the dim ramp (`dark=`) is trailer-independent and always checked. Once
    /// it crosses 0.80 (`dark>=800`, `trailerDimmedOut` latches), the hero trailer LAYER should
    /// dismantle (`trailer=0`), and once it unwinds back below 0.55 the layer remounts
    /// (`trailer=1`) — checked only when a trailer is confirmed active for the opened
    /// title (`trailerEverActive`, below — a title with none makes this vacuous rather than
    /// meaningful; see `smokeVideoId`'s doc comment). The hero trailer's resolve is ASYNC and can
    /// land anytime during the visit, not necessarily by the very first `ux6Probe` — an early draft
    /// of this test gated only on the BASELINE read and saw a run where the trailer resolved
    /// between the baseline and the down-scroll probe, so `trailerEverActive` instead checks EITHER
    /// probe's `glass=` token (the coarse `isTrailerActive` signal — see below), which is reliable
    /// regardless of exactly when the async resolve lands.
    ///
    /// IMPORTANT — `glass=` polarity (a first draft of this test/investigation got this backwards
    /// and chased a phantom bug for a while, see git history if curious): `glass=\(glassFlat ? 1 :
    /// 0)` in `ScrollDimOverlay` — **`glass=1` means the chips ARE flat** (`chipGlassFlat == true`,
    /// glass effect OFF), **`glass=0` means normal `.glassEffect` is showing** (`chipGlassFlat ==
    /// false`, the default). `chipGlassFlat` is proven by design to follow `isTrailerActive` — the
    /// COARSE "is a background trailer active this visit" flag `DetailView.swift` already used for
    /// the mute button/poster-backdrop gating, per the plan's literal wording ("flat material while
    /// a trailer is playing (`isTrailerActive`)") — NOT the finer `trailerLayerVisible` the mount
    /// condition uses. `isTrailerActive` does not itself reset when the AVPlayerLayer dismantles
    /// (only when the background trailer is stopped/disabled/superseded by a full-screen player), so
    /// once a trailer has been active this visit, `glass=1` (flat) is expected to PERSIST even after
    /// scrolling back up past the 0.55 hand-back threshold. The dim ramp itself (`dark<550` after
    /// scrolling back up) is unaffected and still asserted unconditionally.
    ///
    /// Round 3 retune: the latch moved from 0.5/0.3 to 0.80/0.55 (`DetailView.trailerDimmedOut`),
    /// so this test's scroll target moved with it. The ramp saturates at 0.85 and is quantized to
    /// 0.05 steps, which makes `dark=850` the ceiling and `dark>=800` reachable, but it needs
    /// roughly 376pt of scroll offset rather than 235pt: expect more down-presses than the old
    /// `dark>=500` target took. The hand-back assertion is `dark<550` for the same reason.
    ///
    /// The down-scroll itself is driven in batches of 8 (the plan's literal count), up to 3
    /// batches, stopping as soon as `dark>=800` — a straight, unconditional 8 turned out to be too
    /// fragile in practice: the Home hero rotates, and a sparser title (fewer genres, no cast/
    /// company/parental-guide rows, shorter overview) needs more D-pad downs to accumulate 376pt+ of
    /// actual scroll offset than a richer one does. The batch count actually used is mirrored on
    /// the way back up so the hand-back assertions start from a comparable rest position.
    func testDimTrailerGlassHysteresisOnScroll() throws {
        let app = launchToHome(extraArguments: detailScrollProbeLaunchArguments())
        openDeterministicContentRichDetail(app)
        shot(app, "bug41_00_detail_opened")
        let baseline = ux6Probe(app, "bug41_00_baseline")

        var afterDown: [String: Int] = baseline
        var batchesUsed = 0
        for batch in 1...3 {
            press(.down, times: 8, gap: 1.0)
            pause(1.5)
            batchesUsed = batch
            afterDown = ux6Probe(app, "bug41_01_after_down_batch\(batch)")
            if (afterDown["dark"] ?? -1) >= 800 { break }
        }
        shot(app, "bug41_01_after_down_final")
        let trailerEverActive = baseline["glass"] == 1 || afterDown["glass"] == 1
        if !trailerEverActive {
            add(XCTAttachment(string: "NOTE: no trailer was ever active for the opened title this run (glass=0/normal-glass at both baseline and after-down) — the trailer-dismantle/flatten assertions below are skipped; the dim-ramp assertions still run. \"Les Condés\" (this test's fixed anchor) has not been observed to resolve a trailer via -debug.trailerSmokeVideoId in this fixture, so this branch is expected to be the common case, not a failure."))
        }
        if (afterDown["dark"] ?? -1) < 800 {
            add(XCTAttachment(string: "NOTE: dim never reached 0.80 (dark=\(afterDown["dark"] ?? -1)) after \(batchesUsed * 8) down-presses — the opened title's page is likely too short (few genres/no cast/company/parental-guide rows) to accumulate the ~376pt of scroll offset the 0.80 latch now needs."))
        }
        XCTAssertGreaterThanOrEqual(afterDown["dark"] ?? -1, 800, "dim must reach at least 0.80 (dark>=800) after up to \(batchesUsed * 8) down-presses")
        if trailerEverActive {
            XCTAssertEqual(afterDown["trailer"], 0, "hero trailer layer must be dismantled once the dim hysteresis latches at 0.80 (trailerDimmedOut)")
            XCTAssertEqual(afterDown["glass"], 1, "top-block chips must be flat while a trailer has been active this visit (isTrailerActive)")
        } else {
            XCTAssertEqual(afterDown["glass"], 0, "no trailer active — chips must still render normal glass even at full dim (dim alone does not flatten them)")
        }

        press(.up, times: batchesUsed * 8, gap: 1.0)
        pause(1.5)
        shot(app, "bug41_02_after_up")
        let afterUp = ux6Probe(app, "bug41_02_after_up")
        if trailerEverActive {
            // `chipGlassFlat` tracks `isTrailerActive`, which does not unset on scroll position —
            // see the type/method doc above. `glass=1` (flat) staying flat for the rest of the
            // visit is the SHIPPED behavior, not a bug this test is meant to catch.
            XCTAssertEqual(afterUp["glass"], 1, "chips stay flat for the whole visit once a trailer has been active (isTrailerActive persists across scroll)")
            // Unlike `glass=`, `trailer=` DOES hand back: `trailerLayerVisible` is
            // `isTrailerActive && !trailerDimmedOut`, and the latch releases below 0.55.
            XCTAssertEqual(afterUp["trailer"], 1, "hero trailer layer must remount once the dim hysteresis releases below 0.55")
        } else {
            XCTAssertEqual(afterUp["glass"], 0, "no trailer was ever active this visit — chips render normal glass throughout")
        }
        XCTAssertLessThan(afterUp["dark"] ?? 9999, 550, "dim must have unwound back below 0.55 (dark<550) after \(batchesUsed * 8) up-presses")

        XCTAssertTrue(app.state == .runningForeground, "app must survive the full down/up scroll pass")
    }

    // MARK: - `debug.detailScrollAB` live-read contract (item 5)

    /// `DetailScrollAB.leg` moved from a launch-latched `let` to a live `UserDefaults` read so
    /// About's picker (F-C) can flip legs without a relaunch. This harness has no Settings
    /// round-trip in scope here, so instead of flipping the default mid-run it proves the CONTRACT
    /// the picker depends on: a process LAUNCHED with `-debug.detailScrollAB 4` reads leg 4 through
    /// that live accessor, with `dimDisabled`/`glassDisabled` (and by extension
    /// `buttonGlassDisabled`) following from it — dim pinned to 0 for the whole scroll, chips flat
    /// regardless of trailer state, `ab=4` in the diagnostic throughout.
    func testDetailScrollABLegFourIsReadCorrectly() throws {
        let app = launchToHome(extraArguments: detailScrollProbeLaunchArguments(ab: 4))
        openDetailFromHomeHero(app)
        shot(app, "bug41_ab4_00_detail_opened")
        let baseline = ux6Probe(app, "bug41_ab4_00_baseline")
        XCTAssertEqual(baseline["ab"], 4, "debug.detailScrollAB=4 must read back as leg 4 in the live debug_ux6 token")
        XCTAssertEqual(baseline["glass"], 1, "leg 4 flattens the top-block chips (glassDisabled) regardless of trailer state")

        press(.down, times: 8, gap: 1.0)
        pause(1.5)
        shot(app, "bug41_ab4_01_after_down8")
        let afterDown = ux6Probe(app, "bug41_ab4_01_after_down8")
        XCTAssertEqual(afterDown["ab"], 4, "leg must still read 4 after scrolling")
        XCTAssertEqual(afterDown["dark"], 0, "leg 4 (dimDisabled) pins the scroll dim to 0 even after 8 down-presses")

        XCTAssertTrue(app.state == .runningForeground, "app must survive the leg-4 scroll pass")
    }

    // MARK: - Body-eval growth under the scroll probe (items 6/7 — log-harvested, not asserted here)

    /// BUG-41 items 6/7: `DetailView.logBodyEval()` NSLogs `[BUG41] detailBodyEval=N` every 10th
    /// body evaluation, gated by the live `DetailScrollProbe.enabled` read. This test only DRIVES
    /// the scroll (so the counter accumulates something worth harvesting) and captures the
    /// `debug_ux6` AX trail as a cross-check; it deliberately does NOT assert on
    /// `detailBodyEval`'s growth rate — see the type doc for why that has to be a manual/agent log
    /// harvest instead of an in-test assertion.
    func testDetailScrollProbeBodyEvalGrowthLogHarvest() throws {
        let app = launchToHome(extraArguments: detailScrollProbeLaunchArguments(scrollProbe: true))
        openDeterministicContentRichDetail(app)
        shot(app, "bug41_probe_00_detail_opened")
        ux6Probe(app, "bug41_probe_00_baseline")

        press(.down, times: 10, gap: 0.8)
        pause(1.5)
        shot(app, "bug41_probe_01_after_down10")
        ux6Probe(app, "bug41_probe_01_after_down10")

        press(.up, times: 10, gap: 0.8)
        pause(1.5)
        shot(app, "bug41_probe_02_after_up10")
        ux6Probe(app, "bug41_probe_02_after_up10")

        XCTAssertTrue(app.state == .runningForeground, "app must survive the probe-enabled scroll pass — see the type doc for the log-harvest step this test doesn't (and can't) assert on directly")
    }

    // MARK: - Item 8 sim repro: Drop Game / Les Condés (the tester's named titles)

    /// Types `text` into the Search tab's field and returns whether it landed — same
    /// synthesis-first / keyboard-walk-fallback trick `NuvioTVUITests.typeOnKeyboard` documents
    /// (hardware keyboard synthesis into a focused tvOS text field, validated by watching the
    /// field's own `.value`), duplicated here rather than shared per this harness's own
    /// precedent (see the type doc). One `remote.press(.menu)` at the end dismisses the full-screen
    /// keyboard back to the results grid — `NuvioTVUITests.test19DiscoverSurvivesSearch`'s own
    /// teardown uses the same button for the same reason; skipping it was this test's first-draft
    /// bug (the keyboard stayed on screen and no result cell was ever reachable — see the report).
    @discardableResult
    private func typeIntoSearchField(_ app: XCUIApplication, _ text: String) -> Bool {
        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 6) else { return false }
        if !searchField.hasFocus {
            for _ in 0..<6 where !searchField.hasFocus {
                remote.press(.up)
                pause(0.4)
            }
        }
        remote.press(.select)
        pause(2) // full-screen keyboard presentation
        let before = (searchField.exists ? searchField.value as? String : nil) ?? ""
        app.typeText(text)
        pause(1)
        let after = (searchField.exists ? searchField.value as? String : nil) ?? ""
        remote.press(.menu) // dismiss the keyboard so the results grid becomes reachable
        pause(2.5) // debounce + results fetch
        return after != before && !after.isEmpty
    }

    /// Best-effort: walk toward the first result cell and select it. EXISTENCE-driven, not
    /// `hasFocus`-gated — the tvOS 27.0 SIMULATOR RUNTIME never reports `.hasFocus == true`
    /// (documented harness gotcha, `tvos-ui-sim-verification` notes: "3 stacked gaps once made a
    /// vacuous green"), which a first draft of this helper hit directly: `resultCell.hasFocus`
    /// stayed false through all 8 down-presses even though the "Drop"/"Les Condés" result cell was
    /// plainly visible and focus WAS almost certainly landing on it (system focus engine puts
    /// initial focus on the first/leftmost cell of the results row one Down from the search field —
    /// confirmed by comparing exported .xcresult screenshots pixel-for-pixel with/without the
    /// presses: both frames were identical because the loop never even got past its own guard, not
    /// because nothing moved). One fixed Down + Select instead — bounded, tolerant: a genuinely
    /// empty results screen just means the following `ux6Probe`/screenshot in the caller shows
    /// "debug_ux6 MISSING" or a Search screen instead of a Detail one, which the report calls out
    /// explicitly rather than this helper asserting past it.
    private func openFirstSearchResult(_ app: XCUIApplication) {
        remote.press(.down)
        pause(0.8)
        // 2026-09-04 finding: default focus after one Down does NOT reliably land on the leftmost
        // cell — a query with exactly one real match + a "See All" tile landed on "See All"
        // instead (confirmed via exported .xcresult screenshots: the very next screen was a
        // "Results • Movies" grid, not a Detail page), while a query with several matches landed on
        // the correct leftmost title. Four Lefts is a no-op once already at the leftmost cell and
        // reliably corrects the "See All" case either way.
        for _ in 0..<4 {
            remote.press(.left)
            pause(0.3)
        }
        remote.press(.select)
        pause(10) // Detail page fetch + hero-trailer resolve chain settle
    }

    /// BUG-41 item 8: opens the two French titles the tester named (Steven's beta.17 verdict —
    /// see the plan doc's BUG-41 repro-pair line) with the scroll probe on, and records — via
    /// screenshots + the `debug_ux6` AX trail, the same "human/agent reviews the attachments"
    /// philosophy this whole harness uses (see the type doc) — whether items 2/3 (trailer
    /// dismantle, cached-image fallbacks) are the title-dependent term in the choppiness report.
    /// Tolerant throughout: the fixture catalog's search results for either title are outside this
    /// test's control, so every step degrades to "note what happened" rather than a hard failure.
    func testSimReproDropGameAndLesCondes() throws {
        for title in ["Drop Game", "Les Condés"] {
            let app = launchToHome(extraArguments: detailScrollProbeLaunchArguments(scrollProbe: true))
            openTabByName(app, "Search")
            pause(1.5)
            let typed = typeIntoSearchField(app, title)
            let attachment = XCTAttachment(string: "repro \(title): typed=\(typed)")
            attachment.name = "bug41_repro_\(title)_typed"
            attachment.lifetime = .keepAlways
            add(attachment)
            if !typed {
                shot(app, "bug41_repro_\(title)_search_failed")
                continue
            }
            shot(app, "bug41_repro_\(title)_00_results")
            openFirstSearchResult(app)
            shot(app, "bug41_repro_\(title)_01_detail_top")
            let onDetail = app.staticTexts["debug_ux6"].waitForExistence(timeout: 4)
            if !onDetail {
                add(XCTAttachment(string: "NOTE: \(title) — no debug_ux6 element after opening the first result; the Down+Select landed somewhere other than a Detail page (see the attached screenshot) — most likely no result existed to land on."))
            }
            ux6Probe(app, "bug41_repro_\(title)_01_baseline")

            press(.down, times: 4, gap: 1.0)
            pause(1.5)
            shot(app, "bug41_repro_\(title)_02_after_down4")
            ux6Probe(app, "bug41_repro_\(title)_02_after_down4")

            press(.down, times: 4, gap: 1.0)
            pause(1.5)
            shot(app, "bug41_repro_\(title)_03_cast_or_episodes_region")
            ux6Probe(app, "bug41_repro_\(title)_03_after_down8")

            XCTAssertTrue(app.state == .runningForeground, "app must survive the \(title) repro walk")
            app.terminate()
            pause(1.0)
        }
    }

    /// Minimal tab-bar opener — trimmed copy of `NuvioTVUITests.openTab`'s walk (climb to the tab
    /// bar, right/left-hunt for the named tab, select), private to that file so duplicated here per
    /// this harness's own precedent (see the type doc). Only ever called with "Search".
    private func openTabByName(_ app: XCUIApplication, _ name: String) {
        let tabNames = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        press(.up, times: 1, gap: 0.5)
        let tab = app.buttons[name]
        for _ in 0..<6 where !tab.hasFocus {
            remote.press(.right)
            pause(0.35)
        }
        if !tab.hasFocus {
            for _ in 0..<8 where !tab.hasFocus {
                remote.press(.left)
                pause(0.35)
            }
        }
        remote.press(.select)
        pause(2)
        press(.down, times: 1)
    }
}
