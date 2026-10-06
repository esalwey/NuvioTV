import XCTest

/// Wave W5 (beta.18): the two BUG-87/BUG-89 defects the tester reported on build 117, gated through
/// the app's own geometry rather than pixels.
///
///  - **BUG-89, the Medium → Large regression.** After switching Poster Size in Settings, the
///    second-to-last row's regression comes back and stays back until the app is restarted, and the
///    correction — when it finally happens — reads as an "oops" snap rather than part of the size
///    change. Cause: the corrector's brakes (`disarmed`, `verifyFailures`, `pullBacks`,
///    `pullBackDisarmed`, `correctionsFired`, `lastCorrection` in `PinnedRowSettle`) are session-wide
///    statics that nothing reset short of process start, so evidence gathered under Medium's
///    geometry switched the corrector off for a regime it had never been tried against — leaving
///    only the belt, whose one tool is to hide the title. `PinnedRowSettle.noteRegimeChange(key:fits:)`
///    is the fix; leg A is its gate.
///  - **BUG-87, the vanished title.** On the tester's FIRST launch of build 117 a row title
///    disappeared entirely and a relaunch brought it back. Cause: the belt arms on a title's very
///    first `Reading`, which on a cold launch is routinely measured mid-fan-out, and recovery is
///    measurement-driven — on an untouched Home nothing fires another geometry pass, so the hide is
///    permanent. The first-reading grace and the recovery watchdog (`PinnedRowTitleTracking`,
///    `BrowseComponents.swift`) are the fix; leg B is its gate.
///
/// **Oracle: `debug_pinned`, the app's own settle line** — the same one test47/test48 read, for the
/// same reason those two give at length: the pinned title is offset by a `visualEffect`, which is a
/// RENDER-time transform invisible to layout, so its AX frame reports an un-slid position and a
/// frame-based check would pass while the rendered title sat on the artwork. `debug_pinned` carries
/// the geometry the corrector actually decided on, plus (Wave W5) the appended `regime=`/`fits=`
/// fields this file is mostly about. Screenshots are attached for review either way.
///
/// **Both legs skip LOUDLY rather than pass vacuously.** Poster Size is a SYNCED profile setting
/// with no launch-argument override (unlike `no_zoom_on_focus` and friends), so leg A cannot put the
/// fixture where it needs it — it can only read `debug_env`, say plainly that the fixture is in the
/// wrong state, and name the change that would fix it. That is test47's precedent verbatim.
///
/// Helper methods here are a trimmed COPY of `NuvioTVUITests`' (`shot`, `pause`, `press`,
/// `launchToHome`, `moveFocus`, `moveToSidebarRow`, `openTab`, `focusedButton`, `probeValue`,
/// `probeToken`) rather than a shared import — they are `private` to that file, and this harness
/// already accepts duplication over factoring out cross-file test helpers (the rationale
/// `TrailerSoakTests`, `RowLeadingEdgeTests` and `HeroOffLaunchTests` all state in their own type
/// docs). Like those copies, `launchToHome` here is deliberately the always-fresh-`launch()` form:
/// every assertion below depends on a COLD launch with the debug arguments actually in effect,
/// which the suite-order recovery dance in `NuvioTVUITests` cannot guarantee.
final class PinnedRowSettleRegimeTests: XCTestCase {

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
    private func launchToHome(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        app.launch()
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90),
                      "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// Settings SIDEBAR row by name. Copy of `NuvioTVUITests.moveToSidebarRow` — including the
    /// beta.15 §C5 finding it exists for: the native List's "Focused" trait lives on the row's
    /// wrapping `Cell`, not on the inner Button this harness queries by label, so a plain
    /// `moveFocus(until: app.buttons[title])` never detects arrival and silently overshoots.
    @discardableResult
    private func moveToSidebarRow(_ app: XCUIApplication, _ direction: XCUIRemote.Button,
                                  named title: String, max: Int = 12) -> Bool {
        let button = app.buttons[title]
        let cell = app.cells[title]
        func focused() -> Bool { button.hasFocus || (cell.exists && cell.hasFocus) }
        for _ in 0..<max {
            if button.exists && focused() { return true }
            remote.press(direction)
            pause(0.7)
        }
        return button.exists && focused()
    }

    /// From Home content, walk up to the tab bar, right to the wanted tab, and enter it. Copy of
    /// `NuvioTVUITests.openTab`; the climb is existence-driven rather than a fixed Up count for the
    /// reason documented there.
    private func openTab(_ app: XCUIApplication, named title: String) {
        let tabNames = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        press(.up, times: 1, gap: 0.5)
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 6) {
            _ = moveFocus(.left, until: tab, max: 8)
        }
        remote.press(.select)
        pause(2)
        press(.down, times: 1)
    }

    /// Whatever currently reports focus, across the four element kinds a Settings row can resolve
    /// as. Copy of `NuvioTVUITests.focusedButton` — see its comment for the two stacked findings
    /// (every List row is wrapped in a `Cell` that owns the focus trait; a real `Toggle`'s own
    /// element type is ambiguous between `.switch` and `.toggle` on this runtime).
    private func focusedElement(_ app: XCUIApplication) -> XCUIElement? {
        if let cell = app.cells.allElementsBoundByIndex.first(where: { $0.hasFocus }) { return cell }
        if let button = app.buttons.allElementsBoundByIndex.first(where: { $0.hasFocus }) { return button }
        if let toggle = app.toggles.allElementsBoundByIndex.first(where: { $0.hasFocus }) { return toggle }
        return app.switches.allElementsBoundByIndex.first { $0.hasFocus }
    }

    /// Reads `k=v` out of one of Home's invisible DEBUG probe labels (`debug_env`, `debug_pinned`).
    /// Returns nil when the key is absent or not an integer, so callers can fail loudly with the raw
    /// label rather than assert on a silently-defaulted 0.
    private static func probeValue(_ label: String, key: String) -> Int? {
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return Int(parts[1])
        }
        return nil
    }

    /// String twin of `probeValue`, for fields that carry a token rather than a number
    /// (`regime=large-fit`, `beltFadeReason=standdown`). Same exact-key parsing.
    private static func probeToken(_ label: String, key: String) -> String? {
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return String(parts[1])
        }
        return nil
    }

    /// The current settle line, attached to the result bundle with a screenshot beside it.
    private func settleLine(_ app: XCUIApplication, _ shotName: String) -> String? {
        shot(app, shotName)
        let probe = app.staticTexts["debug_pinned"]
        guard probe.waitForExistence(timeout: 10) else {
            XCTFail("debug_pinned probe missing — it is DEBUG-only (HomeView.swift); is this a Release build?")
            return nil
        }
        let line = probe.label
        let report = XCTAttachment(string: line)
        report.name = "\(shotName)_settle_line"
        report.lifetime = .keepAlways
        add(report)
        NSLog("[WAVEW5] %@ %@", shotName, line)
        return line
    }

    /// `debug_env`'s live `PosterStyle.width`, in points. Artwork height is width x 1.5 (Theme.Size's
    /// own table): Small 183pt wide, Medium 220, Large ~269 — the same buckets test47/test48 gate on.
    private func posterWidth(_ app: XCUIApplication) -> Int? {
        let env = app.staticTexts["debug_env"]
        guard env.waitForExistence(timeout: 15) else {
            XCTFail("debug_env probe missing — it is DEBUG-only (HomeView.swift); is this a Release build, or did Home never mount?")
            return nil
        }
        guard let width = Self.probeValue(env.label, key: "w") else {
            XCTFail("could not parse `w=` out of debug_env ('\(env.label)') — the probe's spelling changed; it is append-only by contract")
            return nil
        }
        return width
    }

    // MARK: - Leg A: BUG-89, the Medium → Large regime change

    /// The corrector's session-wide brakes must be released when the GEOMETRY REGIME changes, and
    /// the correction that follows must land inside the size change rather than a beat after it.
    ///
    /// What this asserts, after driving Settings ▸ Appearance ▸ Size from Medium to Large for real
    /// (the only way to move a synced setting — there is no launch-argument override):
    ///
    ///  1. `regime=` on the settle line actually CHANGED. This is the whole premise; without it
    ///     nothing below means anything, so a missing or unchanged token fails rather than skips.
    ///  2. the focused row reaches `inBand=1` within a second of the walk back into the rows. Under
    ///     the defect the corrector was disarmed for the new regime and never got there at all.
    ///  3. `corrN <= 1`. One nudge is the designed cost of a regime change (Wave G's table: Large's
    ///     engine rest takes exactly one). Two or more means the reset handed the loop a fresh
    ///     budget to fight with, which is the failure this test's fix must not reintroduce.
    ///  4. `beltFaded=0`. The belt hiding a title here IS the tester's "the regression returns" —
    ///     it is the terminal fallback for an uncorrectable rest, not the outcome of a size change.
    ///  5. `seq` holds still over a 5s idle. A climbing `seq` with nobody touching the remote is the
    ///     BUG-87 loop signature, and a regime reset is exactly the kind of state clear that could
    ///     restart it.
    func testW5aRegimeChangeReleasesTheCorrectorsBrakes() throws {
        let app = launchToHome(extraArguments: ["-debug.homeScrollProbe", "YES"])
        openTab(app, named: "Home")
        pause(1.5)

        // Premise: the fixture must START at Medium, because the reported defect is the Medium →
        // Large transition specifically. Poster Size is synced profile state, so this can only be
        // read and reported on — see the type doc.
        guard let startWidth = posterWidth(app) else { return }
        // FEAT-39: 212…228 keeps Medium+ (~234) out of this band, matching
        // `FixtureSetupTests.testSetPosterSizeMedium`'s tightened Medium gate — the old 200..<260
        // gate admitted Medium+ (~234) as "Medium", and this leg's Medium → Large premise silently
        // ran as a Medium+ → Large one instead.
        guard startWidth > 212, startWidth < 228 else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — Poster Size is not Medium (debug_env w=\(startWidth); Medium is ~220pt, Medium+ ~234, Large ~269). This leg drives the Medium → Large transition the tester reported, so it has to start at Medium. Set Settings > Appearance > Poster Size to Medium on this fixture and rerun.")
        }

        // Walk into a poster row so a pinned row is actually focused and publishing settles —
        // `debug_pinned` reports the FOCUSED row and nothing else. Three Downs clears Continue
        // Watching / Upcoming into a poster catalog row on this fixture, the same walk test47/test48
        // use. The 3s is test47's number: settle debounce (0.25) + a correction and its settle
        // (0.5) + the belt's fadeDelay (0.7) + the re-check chain, with headroom so nothing below
        // can be a timing artefact.
        press(.down, times: 3, gap: 0.9)
        pause(3.0)
        guard let beforeLine = settleLine(app, "w5a0_medium_rest") else { return }
        guard !beforeLine.hasSuffix(" -"), Self.probeValue(beforeLine, key: "margin") != nil else {
            throw XCTSkip("no focused pinned settle was reported at Medium ('\(beforeLine)') — the settle re-reveal is armed only in Home's PINNED (Nuvio-style) hero container, and only while a pinned row holds focus. Turn Settings > Home Screen > Nuvio-style hero on, or re-tune the Down walk for this fixture's row order, and rerun.")
        }
        guard let beforeRegime = Self.probeToken(beforeLine, key: "regime"), beforeRegime != "-" else {
            throw XCTSkip("the settle line carries no usable `regime=` ('\(beforeLine)') — that field is published by HomeView's `.onChange(of: plan.regimeKey)` into `PinnedRowSettle.noteRegimeChange`, so this build predates the Wave W5 call site (or is running a host that never publishes a regime). Nothing to compare; rebuild and rerun.")
        }
        // Belt and suspenders on top of the width gate above: `regime=`'s own tag
        // (`PinnedRowGeometry.regimeKey`'s leading `S`/`M`/`P`/`L`/`X`) is the app's own account of
        // which Poster Size it thinks it is running, so confirm it agrees with the width probe
        // before trusting the Medium-start premise at all.
        guard beforeRegime.hasPrefix("M") else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the settle line's regime tag ('\(beforeRegime)') is not Medium ('M…') even though debug_env's width gate passed (w=\(startWidth)); the two probes disagree, most likely Medium+ ('P…'). Run `testSetPosterSizeMedium` (FixtureSetupTests) to restore the fixture to Medium and rerun.")
        }

        // ── Drive the real setting ───────────────────────────────────────────────────────────
        guard try selectPosterSize(app, named: "Large") else { return }

        let measuredWidth = posterWidth(app)
        guard let afterWidth = measuredWidth, afterWidth >= 260 else {
            throw XCTSkip("Poster Size did not actually become Large (debug_env w=\(measuredWidth.map(String.init) ?? "?")) — the Settings walk selected something else, or the synced repository refused the write. This leg's premise is the transition itself, so there is nothing to assert. Rerun; if it persists the Appearance-pane walk needs re-tuning.")
        }

        // Back into the rows so a pinned row is focused and publishing again.
        press(.down, times: 3, gap: 0.9)

        // Gate 2 — the correction must land promptly. Polled rather than slept: "within 1s" is the
        // property (a correction folded into the size change, not a later snap), and a fixed sleep
        // would measure something weaker.
        var afterLine = ""
        var reachedBand = false
        let deadline = Date().addingTimeInterval(1.0)
        repeat {
            afterLine = app.staticTexts["debug_pinned"].label
            if Self.probeValue(afterLine, key: "inBand") == 1 { reachedBand = true; break }
            pause(0.1)
        } while Date() < deadline
        shot(app, "w5a1_large_rest")
        let afterReport = XCTAttachment(string: "before: \(beforeLine)\nafter:  \(afterLine)")
        afterReport.name = "w5a1_settle_lines"
        afterReport.lifetime = .keepAlways
        add(afterReport)
        NSLog("[WAVEW5] regime before=%@ after=%@", beforeLine, afterLine)

        // Gate 1 — the premise, asserted rather than assumed.
        guard let afterRegime = Self.probeToken(afterLine, key: "regime") else {
            XCTFail("the post-switch settle line carries no `regime=` at all ('\(afterLine)') — the field is append-only by contract and was present before the switch. Something stopped publishing it.")
            return
        }
        XCTAssertNotEqual(
            afterRegime, beforeRegime,
            "Poster Size went Medium → Large (debug_env w \(startWidth) → \(afterWidth)) and the corrector's regime key did NOT change ('\(beforeRegime)') — so `PinnedRowSettle.noteRegimeChange` never fired, and every brake accumulated under Medium's geometry is still holding against Large's. That is the tester's 'the regression returns until I restart the app'. Full line: \(afterLine)"
        )

        guard Self.probeValue(afterLine, key: "margin") != nil else {
            throw XCTSkip("no focused pinned settle after the switch ('\(afterLine)') — the walk back into the rows did not land in a pinned row, so there is no rest to judge. Rerun; if it persists the walk needs re-tuning for this fixture's row order.")
        }

        // Gate 2.
        XCTAssertTrue(
            reachedBand,
            "one second after returning to the rows at Large the focused row is still outside its legibility band (inBand=\(Self.probeValue(afterLine, key: "inBand").map(String.init) ?? "?"), margin=\(Self.probeValue(afterLine, key: "margin").map(String.init) ?? "?")) — under the defect the corrector was disarmed for a regime it had never been tried against, so the rest was never corrected at all and only the belt was left. Full line: \(afterLine)"
        )

        // Gate 3 — one nudge is the designed cost of a regime change; more is the loop.
        if let corrN = Self.probeValue(afterLine, key: "corrN") {
            XCTAssertLessThanOrEqual(
                corrN, 1,
                "the row needed \(corrN) corrections inside the window after the size change — Wave G's table puts Large's engine rest exactly one nudge from the band, so more than one means the regime reset handed the corrector a budget to FIGHT with rather than a clean slate. Full line: \(afterLine)"
            )
        } else {
            XCTFail("the post-switch settle line carries no `corrN=` ('\(afterLine)') — append-only by contract, and test47 relies on it too.")
        }

        // Gate 4 — the belt must not be what "fixes" this.
        if let beltFaded = Self.probeValue(afterLine, key: "beltFaded") {
            XCTAssertEqual(
                beltFaded, 0,
                "the visibility belt hid the row title after the Poster Size change (beltFadeReason=\(Self.probeToken(afterLine, key: "beltFadeReason") ?? "-")) — the belt is the terminal fallback for a rest no correction can fix, and a size change on healthy geometry is not that. A hidden title here is the tester's report reproducing. Full line: \(afterLine)"
            )
        }

        // Gate 5 — idle stability. A regime reset clears the brakes; it must not restart the loop
        // they were braking.
        var idleSamples: [String] = []
        for i in 0..<10 {
            let sample = app.staticTexts["debug_pinned"].label
            idleSamples.append(sample)
            let idleReport = XCTAttachment(string: sample)
            idleReport.name = "w5a2_\(i)_idle_sample"
            idleReport.lifetime = .keepAlways
            add(idleReport)
            pause(0.5)
        }
        NSLog("[WAVEW5] idle samples: %@", idleSamples.joined(separator: " || "))
        var seqValues: Set<String> = []
        for sample in idleSamples {
            guard let seq = Self.probeToken(sample, key: "seq") else {
                XCTFail("idle settle sample carries no `seq=` — the settle line is append-only by contract. Full sample: \(sample)")
                continue
            }
            seqValues.insert(seq)
            if let pull = Self.probeValue(sample, key: "pull") {
                XCTAssertEqual(pull, 0, "an idle sample after the size change required a pull-back correction with nobody touching the remote. Full sample: \(sample)")
            }
            if let pbDisarm = Self.probeValue(sample, key: "pbDisarm") {
                XCTAssertEqual(pbDisarm, 0, "an idle sample after the size change shows the pull-back detector disarmed — the corrector fought itself into a stand-down with no input. Full sample: \(sample)")
            }
        }
        XCTAssertEqual(
            seqValues.count, 1,
            "the settle counter moved through \(seqValues.count) distinct values across a 5s idle window with nobody touching the remote (\(seqValues.sorted().joined(separator: ", "))) — the corrector is still resolving settles after the regime change, which is the BUG-87 loop signature. Samples: \(idleSamples.joined(separator: " || "))"
        )
        XCTAssertEqual(app.state, .runningForeground, "app must survive the regime change and its correction")
    }

    // MARK: - Leg B: BUG-87, the title that vanished on a cold launch

    /// A cold launch, left completely alone, must not leave a row title hidden by the belt.
    ///
    /// The tester's build-117 report is one sentence: on his FIRST launch of the build the row title
    /// disappeared entirely, and a relaunch fixed it. The belt used to arm on a title's very first
    /// `Reading` — measured mid-fan-out on a cold launch — and recovery is measurement-driven, so on
    /// an untouched Home nothing ever fired the geometry pass that would have brought it back. The
    /// first-reading grace and the recovery watchdog both exist to close that.
    ///
    /// **Deviation, stated rather than hidden.** The idle window is genuinely input-free, but the
    /// ASSERTION cannot be: `debug_pinned` reports the FOCUSED pinned row and nothing else, and a
    /// cold Home parks focus on the hero CTA, so a strictly no-input leg has no `beltFaded=` field
    /// to read and would pass vacuously — the exact failure class this suite documents. So the leg
    /// idles hands-off for the full five seconds (which is what lets the cold-launch race play out
    /// and the grace/watchdog timers run), samples the probe throughout, and only THEN makes the
    /// minimum walk needed to focus a row and read its state. "The first thing you touch after a
    /// cold launch does not have a hidden title" is the tester's report in testable form.
    func testW5bColdLaunchLeavesNoTitleHidden() throws {
        let app = launchToHome(extraArguments: ["-debug.homeScrollProbe", "YES"])
        // Deliberately NO `openTab` here: that walks the tab bar, which is input. `launchToHome`
        // lands on Home already.
        shot(app, "w5b0_cold_home")

        // Hands off for five seconds. Long enough to cover the grace (0.5s), a fade that follows it
        // (fadeDelay 0.7), the belt's terminal ceiling (fadeMaxDefer 2.5 + fadeRecheckFloor 0.1) and
        // the recovery watchdog's whole bounded run (5 x 1s, started only if something did fade).
        var idleSamples: [String] = []
        for i in 0..<10 {
            let sample = app.staticTexts["debug_pinned"].label
            idleSamples.append(sample)
            let report = XCTAttachment(string: sample)
            report.name = "w5b1_\(i)_idle_sample"
            report.lifetime = .keepAlways
            add(report)
            pause(0.5)
        }
        NSLog("[WAVEW5] cold-launch idle samples: %@", idleSamples.joined(separator: " || "))
        // Any sample that DOES carry the field is judged — a settle published during the idle window
        // (a lazy row realizing, the launch sync burst reordering rows) is exactly the cold-launch
        // churn BUG-87 lives in.
        for sample in idleSamples where Self.probeValue(sample, key: "beltFaded") != nil {
            XCTAssertEqual(
                Self.probeValue(sample, key: "beltFaded"), 0,
                "a row title was hidden by the visibility belt during an untouched cold launch (beltFadeReason=\(Self.probeToken(sample, key: "beltFadeReason") ?? "-")) — this is the tester's build-117 report verbatim: the title disappeared on first launch and only a relaunch brought it back. The first-reading grace is supposed to stop a mid-fan-out measurement from arming the belt at all, and the recovery watchdog is supposed to un-hide it if one ever does. Full sample: \(sample)"
            )
        }

        // Now the minimum input that makes the state readable — see the deviation note above.
        press(.down, times: 3, gap: 0.9)
        pause(3.0)
        guard let line = settleLine(app, "w5b2_first_focused_row") else { return }
        guard !line.hasSuffix(" -"), Self.probeValue(line, key: "margin") != nil else {
            throw XCTSkip("no focused pinned settle was reported after the cold-launch walk ('\(line)') — the settle re-reveal and its belt are armed only in Home's PINNED (Nuvio-style) hero container, so this fixture is running the classic in-scroll hero and has no overlaid title for the belt to hide. Turn Settings > Home Screen > Nuvio-style hero on and rerun.")
        }
        guard let beltFaded = Self.probeValue(line, key: "beltFaded") else {
            XCTFail("the settle line carries no `beltFaded=` ('\(line)') — append-only by contract, and both test48 and this leg read it.")
            return
        }
        XCTAssertEqual(
            beltFaded, 0,
            "the first pinned row focused after a cold launch has its title hidden by the belt (beltFadeReason=\(Self.probeToken(line, key: "beltFadeReason") ?? "-"), net=\(Self.probeValue(line, key: "net").map(String.init) ?? "?"), intrLifted=\(Self.probeValue(line, key: "intrLifted").map(String.init) ?? "?")) — on a rest this healthy the belt has nothing to be protecting the artwork from, which makes this the BUG-87 first-reading race: the title armed on a measurement taken before the layout was final and nothing ever fired the geometry pass that would have recovered it. Full line: \(line)"
        )
        XCTAssertEqual(app.state, .runningForeground, "app must survive a cold launch and an idle Home")
    }

    // MARK: - Settings ▸ Appearance ▸ Size

    /// Drives the real Poster Size picker to `name`. Returns false (having already skipped or
    /// failed) when the walk cannot get there — never silently.
    ///
    /// The row is a `SettingsPickerRow`, i.e. a `Menu` wrapping a `Picker`
    /// (`Settings/SettingsRowViews.swift`), so this is two steps: focus the row and Select to open
    /// the menu, then focus the wanted option inside it and Select again. "Size" is a unique row-title
    /// prefix in the Appearance pane, which is what makes the focused-label walk below safe.
    private func selectPosterSize(_ app: XCUIApplication, named name: String) throws -> Bool {
        openTab(app, named: "Settings")
        guard moveToSidebarRow(app, .down, named: "Appearance", max: 10) else {
            throw XCTSkip("could not reach the Appearance sidebar category — the Settings sidebar's row order or labels changed. Poster Size can only be set through the real UI (it is synced profile state with no launch-argument override), so there is no fallback.")
        }
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)      // sidebar → pane
        pause(1.0)
        shot(app, "w5a_appearance_pane")

        // Entering the pane lands focus on the row nearest the sidebar item's Y, never reliably the
        // first one (`walkToRowByTreeIndex`'s own finding). Climb to the top first — Up past the top
        // is a no-op — then walk down looking for the row.
        press(.up, times: 25, gap: 0.25)
        var found = false
        for _ in 0..<30 {
            if let label = focusedElement(app)?.label, label.hasPrefix("Size") { found = true; break }
            remote.press(.down)
            pause(0.45)
        }
        guard found else {
            let seen = focusedElement(app)?.label ?? "<nothing reports focus>"
            throw XCTSkip("could not focus the Appearance pane's 'Size' row — the walk ended on '\(seen)'. The row is a Menu-backed SettingsPickerRow and this harness has no verified adjacency map for the pane; Poster Size cannot be set any other way (synced profile state, no launch-argument override), so this leg cannot run.")
        }
        shot(app, "w5a_size_row_focused")

        remote.press(.select)        // open the Menu
        pause(1.5)
        shot(app, "w5a_size_menu_open")
        let option = app.buttons[name]
        guard option.waitForExistence(timeout: 6) else {
            remote.press(.menu)      // leave the dropdown as we found it
            pause(1.0)
            throw XCTSkip("the Poster Size menu never exposed a '\(name)' option — tvOS Menu/Picker dropdowns do not always publish their rows as queryable buttons on this runtime. Nothing was changed.")
        }
        // The dropdown opens with the CURRENT selection focused, so the wanted option may be above
        // or below it. Try both directions before giving up, the same shape `openTab` uses.
        if !moveFocus(.down, until: option, max: 5) {
            _ = moveFocus(.up, until: option, max: 5)
        }
        guard option.hasFocus else {
            remote.press(.menu)
            pause(1.0)
            throw XCTSkip("the Poster Size menu's '\(name)' option would not take focus — nothing was changed. (Menu+Picker focus is a known soft spot on this runtime.)")
        }
        remote.press(.select)
        pause(2.5)                   // the picker writes through the synced repository
        shot(app, "w5a_size_selected")
        openTab(app, named: "Home")
        pause(2.0)
        return true
    }
}
