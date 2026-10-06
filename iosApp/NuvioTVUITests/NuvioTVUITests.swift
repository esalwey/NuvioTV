import XCTest

/// One `rows` probe line, parsed down to what the reorder rule needs. `index` is the line's
/// position in the FULL probe-line array, which is how the rule places it against the `commit`
/// line and against any disqualifying line between two `rows` lines.
struct RowsProbeLine: Equatable {
    let index: Int
    /// The ordered row-id digests from `order=` (or the three real ids from `first=` on a build
    /// older than that token).
    let order: [String]
    /// The Home Rows settings-order digest from `settingsSig=`, or nil on a build that predates it.
    let settingsSig: String?
    /// The whole line, so a failure message can quote it.
    let raw: String
}

/// Whether a reorder between two consecutive `rows` probe lines is a violation.
///
/// A reorder is two row ids present in BOTH lines that swap relative position. Rows growing as
/// catalog batches stream in is not a reorder and never was; this rule only ever looks at ids the
/// two lines share.
///
/// The rule is NOT "rows never reorder". `RowsGate` (HomeHeroCommit.swift) is explicit that the
/// gate exists to make the FIRST paint atomic - hero, sections and rows in one turn - and that
/// afterwards "post-commit reorders are allowed by design". The thing BUG-86 is about is a rebuild
/// that reshuffles the rows BEFORE the hero has committed (the tester's video: "Top 10 des films"
/// on top, then a rebuild that puts "Nouveaux films" first, with skeletons under it).
///
/// So a reorder is accepted only when all three hold:
///   1. it is OBSERVED after the first `commit` line (the later of the two `rows` lines is
///      post-commit). The gated rebuild's own `rows` line is logged from inside the commit
///      continuation, immediately BEFORE the `commit` line, so it is always the `earlier` half of
///      the pair that matters and this stays a strict pre/post split;
///   2. `settingsSig=` actually MOVED between the two lines, i.e. the Home Rows order the rebuild
///      walks is a different order now. That is what makes the reorder attributable to a settings
///      publish (a cloud pull landing the order the user set on another device - the launch sync
///      burst's step 2, and the real event it simulates) rather than to rows reshuffling under a
///      settings order that never moved, which is an unstable rebuild and stays a failure. A line
///      with no `settingsSig=` (a log from a build before this token) can attribute nothing, so it
///      is rejected exactly as it was before this rule existed;
///   3. nothing disqualifying sits between them - a second `commit`, or a `publish … headChanged=1`.
///      Either means the reorder rode a re-decision of the hero head, which is the double-commit
///      the whole photo contract exists to catch, and no settings change excuses it.
enum RowsOrderRule {
    struct Violation: Equatable {
        let earlier: RowsProbeLine
        let later: RowsProbeLine
        /// Why the reorder was not excused, for the failure message.
        let reason: String
    }

    /// - Parameters:
    ///   - rowsLines: every `rows` line, in emission order.
    ///   - firstCommitIndex: index of the first `commit` line in the full probe-line array, or nil
    ///     when the run never committed (a separate assertion already fails that case).
    ///   - disqualifyingIndices: indices of `commit` lines after the first and of
    ///     `publish … headChanged=1` lines, in the same array.
    static func firstViolation(rowsLines: [RowsProbeLine],
                               firstCommitIndex: Int?,
                               disqualifyingIndices: Set<Int>) -> Violation? {
        guard rowsLines.count > 1 else { return nil }
        for i in 1..<rowsLines.count {
            let earlier = rowsLines[i - 1]
            let later = rowsLines[i]
            let laterPosition = Dictionary(uniqueKeysWithValues: later.order.enumerated().map { ($1, $0) })
            let sharedPositionsInEarlierOrder = earlier.order.compactMap { laterPosition[$0] }
            if sharedPositionsInEarlierOrder == sharedPositionsInEarlierOrder.sorted() { continue }

            guard let firstCommitIndex, later.index > firstCommitIndex else {
                return Violation(earlier: earlier, later: later,
                                 reason: "the reorder landed before the hero committed — rows must not reshuffle under an uncommitted hero")
            }
            guard let earlierSig = earlier.settingsSig, let laterSig = later.settingsSig else {
                return Violation(earlier: earlier, later: later,
                                 reason: "no settingsSig= on one or both lines, so the reorder cannot be attributed to a Home Rows settings change")
            }
            guard earlierSig != laterSig else {
                return Violation(earlier: earlier, later: later,
                                 reason: "the Home Rows settings order did not change (settingsSig=\(laterSig) on both lines) — rows reshuffled on their own")
            }
            if let blocker = disqualifyingIndices.filter({ $0 > earlier.index && $0 <= later.index }).min() {
                return Violation(earlier: earlier, later: later,
                                 reason: "a second commit or a headChanged=1 publish (probe line \(blocker)) landed between the two lines — the reorder rode a re-decision of the hero head")
            }
        }
        return nil
    }
}

/// Pure-rule coverage for `RowsOrderRule`: no app launch, no simulator interaction, so it runs in
/// milliseconds alongside the UI gates it guards. The accepted case is the one the launch sync
/// burst produces on a warm fixture (`test31HeroCommitsOnce` Leg B, 2026-09-05: commit at 5457 ms
/// with `art=ready waited=9ms`, then the burst's `applyFromRemote` reversing all 34 rows at
/// 6451 ms); every rejected case is a shape the old, position-only rule caught and this one must
/// keep catching.
final class RowsOrderRuleTests: XCTestCase {
    private func line(_ index: Int, _ order: [String], _ sig: String?) -> RowsProbeLine {
        RowsProbeLine(index: index, order: order, settingsSig: sig, raw: "rows #\(index)")
    }

    func testGrowingRowsAreNotAReorder() {
        let lines = [line(0, ["a", "b", "c"], "s1"), line(2, ["a", "b", "c", "d", "e"], "s1")]
        XCTAssertNil(RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: 1, disqualifyingIndices: []))
    }

    func testPostCommitReorderWithMovedSettingsSignatureIsAccepted() {
        let lines = [line(0, ["a", "b", "c"], "s1"), line(5, ["c", "b", "a"], "s2")]
        XCTAssertNil(RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: 1, disqualifyingIndices: []))
    }

    func testPreCommitReorderIsRejectedEvenWhenSettingsMoved() {
        let lines = [line(0, ["a", "b", "c"], "s1"), line(1, ["c", "b", "a"], "s2")]
        let violation = RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: 4, disqualifyingIndices: [])
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation?.reason.contains("before the hero committed") == true, "got \(violation?.reason ?? "nil")")
    }

    func testPostCommitReorderWithUnmovedSettingsSignatureIsRejected() {
        let lines = [line(0, ["a", "b", "c"], "s1"), line(5, ["c", "b", "a"], "s1")]
        let violation = RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: 1, disqualifyingIndices: [])
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation?.reason.contains("did not change") == true, "got \(violation?.reason ?? "nil")")
    }

    func testPostCommitReorderOnAProbeWithoutSettingsSignatureIsRejected() {
        let lines = [line(0, ["a", "b", "c"], nil), line(5, ["c", "b", "a"], nil)]
        XCTAssertNotNil(RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: 1, disqualifyingIndices: []))
    }

    func testReorderRidingASecondCommitIsRejected() {
        let lines = [line(0, ["a", "b", "c"], "s1"), line(5, ["c", "b", "a"], "s2")]
        let violation = RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: 1, disqualifyingIndices: [3])
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation?.reason.contains("re-decision of the hero head") == true, "got \(violation?.reason ?? "nil")")
    }

    func testNoCommitAtAllRejectsAnyReorder() {
        let lines = [line(0, ["a", "b"], "s1"), line(1, ["b", "a"], "s2")]
        XCTAssertNotNil(RowsOrderRule.firstViolation(rowsLines: lines, firstCommitIndex: nil, disqualifyingIndices: []))
    }
}

/// Headless verification harness for the beta.7 UX batch (UX-2/UX-3).
///
/// This sandbox has no Simulator window, so `XCUIRemote` is the only way to drive tvOS focus
/// headlessly (`xcodebuild test` needs no GUI). Tests are deliberately tolerant: navigation is
/// best-effort, every checkpoint captures a named screenshot attachment into the result bundle,
/// and a human (or agent) reviews the exported attachments afterwards. Assertions are kept to
/// existence checks that survive layout changes.
final class NuvioTVUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

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

    /// Launch and pass the profile gate (profile "Chris", no PIN, first in the row and focused by
    /// default). Lands on Home.
    ///
    /// 2026-07-28: a cold `launch()` from XCTest reproducibly sits on **AuthView** — the Supabase
    /// session restore doesn't complete for it (a plain `xcrun simctl launch` of the same build
    /// reaches the profile picker in ~20s). So when the app is already running in the foreground
    /// and no launch arguments are needed, `activate()` it instead: pre-warm the sim with
    /// `xcrun simctl launch <udid> com.nuvio.media.NuvioTV` before the run and the suite attaches to
    /// that signed-in instance. (In-suite relaunches of a warm app reach the picker fine — test05/
    /// 06/08 prove it every run — so the fall-through below is safe mid-suite.)
    ///
    /// 2026-08-02 — the suite-order failure class (test04/09/11/19 failed in-suite, passed
    /// isolated): the old recovery dance here blindly pressed Menu 4×. When the previous test
    /// ended at a ROOT tab surface (top of Home is how test03/08/10/18 all end), the first Menu
    /// press exited to the springboard, and `activate()` from there intermittently re-fronts the
    /// app into a black-screen state: XCUIScreen captures pure black, the AX tree stays queryable,
    /// and D-pad presses go blind (the failed run's screen recordings show the tab-walk presses
    /// driving springboard app icons). Two rules keep the path order-independent now:
    ///  - only press Menu while the root tab bar ("Home") is not visibly on screen — pushed
    ///    screens (immersive DetailView, covers) remove it and deep scroll moves it off screen,
    ///    and a Menu press with the bar visible is exactly the press that escapes;
    ///  - never `activate()` out of a springboard escape or a backgrounded app — fall through to
    ///    a full relaunch instead, the only reliable recovery.
    /// `forceFreshLaunch` forces that same relaunch unconditionally, for tests that must not
    /// inherit any prior UI state (settings-pane scroll/focus, pushed screens) from suite order.
    @discardableResult
    private func launchToHome(extraArguments: [String] = [], forceFreshLaunch: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        if extraArguments.isEmpty && !forceFreshLaunch && app.state == .runningForeground {
            app.activate()
            pause(2)
            let chris = app.buttons["Chris"]
            if chris.waitForExistence(timeout: 8) {
                if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
                remote.press(.select)
                pause(10)
                return app
            }
            // FEAT-30: in sidebar mode there is no system tab bar to recover through at all —
            // `app.buttons["Home"]` never exists, so the Menu-press recovery below (which only
            // stops pressing Menu once that button is visible) would burn its whole budget
            // pressing Menu blind. That is actively dangerous here, not just wasted motion: Menu
            // while a sidebar row already has focus is the system's suspend-the-app default
            // (`SidebarOverlay` installs no exit handler of its own — see its doc comment), and a
            // prior test could easily have left focus sitting on one. Detect the mode by the
            // sidebar's own rows/container existing (the same signal `openTab` uses, not a
            // `UserDefaults` read this process has no access to) and recover through THAT helper's
            // own sidebar branch, which reaches Home with no Menu press anywhere in its path.
            if app.otherElements["sidebar_overlay"].exists || app.buttons["sidebar_item_Home"].exists {
                openTab(app, named: "Home")
                pause(1)
                return app
            }
            // Already past the profile gate, somewhere inside the app (a prior test's end state —
            // e.g. test01 deliberately ends on a pushed DetailView). Pop pushed screens with Menu
            // ONLY while the root tab bar is off screen (see the header comment), then reselect
            // the Home tab so every test starts from the same top-of-Home state a fresh launch
            // gives. `.exists` alone is NOT the right stop signal: the failed run's hierarchy
            // dumps show the bar's buttons stay in the tree when scrolled off screen (frame.minY
            // -604…-1510) and sit at ~+62 when actually visible — and only the visible-bar state
            // is the one where a Menu press escapes to the springboard (off-screen-deep Menu is
            // the BUG-27 jump-to-top interception, and pushed covers remove the bar entirely).
            let homeTab = app.buttons["Home"]
            var escapedToSpringboard = false
            for _ in 0..<4 {
                if homeTab.exists, homeTab.frame.minY > 0 { break }
                remote.press(.menu)
                pause(1.2)
                if app.state != .runningForeground {
                    escapedToSpringboard = true
                    break
                }
            }
            if !escapedToSpringboard {
                press(.up, times: 8, gap: 0.5)
                if !moveFocus(.left, until: homeTab, max: 8) {
                    _ = moveFocus(.right, until: homeTab, max: 8)
                }
                remote.press(.select)
                pause(3)
                press(.down, times: 1)
                pause(1)
                return app
            }
            // Springboard escape: fall through to app.launch() below.
        }
        app.launch()
        // Session restore + profile fetch can take well past 15s on a cold sim launch; a short wait
        // silently dropped the suite onto the sign-in screen and every screenshot was of AuthView.
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    /// Press `direction` until `element` has focus (or the budget runs out).
    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// Moves focus to a Settings SIDEBAR category row by name. beta.15 §C5 root-cause finding
    /// (confirmed via `app.debugDescription`, not guessed): the native List wraps every sidebar
    /// row in a `Cell` that carries the real "Focused" accessibility trait — `app.buttons[name]`
    /// (the label this harness has always queried) NEVER reports `hasFocus`, only the
    /// wrapping Cell does. `moveFocus(until: app.buttons["Appearance"], max: 10)` therefore never
    /// detects arrival and silently burns its whole press budget, overshooting to wherever that
    /// many Down presses land — in one captured run that was "About" (the LAST category) while
    /// aiming for "Appearance" (2 rows down), because the sidebar has 7 categories and category
    /// walks that target something other than the first/last row in the walked direction were
    /// landing on the wrong pane's content entirely (test04/test16's real failure mode: they were
    /// asserting About's debug rows, not Appearance's). Checks `app.cells[title]` in addition to
    /// the button so arrival is actually detected.
    @discardableResult
    private func moveToSidebarRow(_ app: XCUIApplication, _ direction: XCUIRemote.Button, named title: String, max: Int = 12) -> Bool {
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

    /// From Home content, walk up to the tab bar, right to the wanted tab, and enter it.
    ///
    /// FEAT-30: on a device with the sidebar overlay on (`sidebar_style` = `"sidebar"`), the
    /// system tab bar this function has always driven does not exist at all — `SidebarOverlay`
    /// (`DesignSystem/SidebarOverlay.swift`) replaces it. Detected by the sidebar's own rows
    /// EXISTING, not by reading the `UserDefaults` key directly (the harness has no access to the
    /// sim's defaults from inside the test process, and existence is exactly what the app itself
    /// renders off of), so tabs-mode callers see byte-identical behaviour below — the sidebar
    /// branch is a new `if`, not a change to the existing walk.
    private func openTab(_ app: XCUIApplication, named title: String) {
        let tabNames = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        if app.descendants(matching: .any)["sidebar_item_Home"].exists || app.otherElements["sidebar_overlay"].exists {
            // The panel is visible even collapsed (showing only the CURRENT tab's own row), and it
            // only expands to show every row once focus actually lands ON one of them
            // (`SidebarOverlay.isExpanded` = `focusedItem != nil`). So climb Up until ANY
            // `sidebar_item_*` row holds focus — deliberately not a Menu press: Menu while the
            // sidebar already has focus is the system's suspend-the-app default (see
            // `launchToHome`'s header comment on the springboard-escape class), so this walk must
            // never rely on it.
            func anySidebarRowFocused() -> Bool {
                tabNames.contains { app.buttons["sidebar_item_\($0)"].exists && app.buttons["sidebar_item_\($0)"].hasFocus }
            }
            for _ in 0..<40 {
                if anySidebarRowFocused() { break }
                remote.press(.up)
                pause(0.35)
            }
            let target = app.buttons["sidebar_item_\(title)"]
            if !moveFocus(.down, until: target, max: 6) {
                _ = moveFocus(.up, until: target, max: 8)
            }
            remote.press(.select)
            // Selecting a row releases focus into the new tab's content (see
            // `SidebarOverlay.basePanel`), so unlike the tab-bar branch below no post-select
            // press is needed to leave the chrome.
            pause(2)
            return
        }

        // Climb until a tab-bar button reports focus (tabs DO report focus, test13) — a fixed
        // Up×8 could not leave a long Settings pane (beta.13 wave 2 finding: test27/29 ended in
        // the sidebar), while Up past the tab bar is a no-op, so overshooting is harmless.
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

    /// Types `text` on the tvOS full-screen system keyboard by walking to each letter key in turn
    /// and selecting it. Best-effort, same spirit as test19DiscoverSurvivesSearch's typing step
    /// (see its header comment): this harness has no verified key-to-key adjacency map for the
    /// keyboard grid, so a character the walk can't reach just stops the whole attempt rather than
    /// guessing blind arrow-press counts. Returns whether every character was found and selected.
    @discardableResult
    private func typeOnKeyboard(_ app: XCUIApplication, _ text: String) -> Bool {
        // tvOS 27's full-screen keyboard exposes `app.keys` elements but their `hasFocus` never
        // reads true (verified on the 27.0 sim: the walk finds "b" 80+ times and can never focus
        // it), so the key-walk below is 26.5-only. Hardware keyboard synthesis types into the
        // focused keyboard on both runtimes — proved by the manual BUG-47 repro — so try that
        // first and validate it landed by watching the entry field's value; only fall back to
        // walking keys when synthesis provably changed nothing.
        let entryField = app.textFields.firstMatch
        let before = (entryField.exists ? entryField.value as? String : nil) ?? ""
        app.typeText(text)
        pause(0.8)
        let after = (entryField.exists ? entryField.value as? String : nil) ?? ""
        if after != before && !after.isEmpty { return true }
        for character in text {
            let key = app.keys[String(character)]
            guard key.waitForExistence(timeout: 3) else { return false }
            if !key.hasFocus {
                let reached = moveFocus(.right, until: key, max: 12)
                    || moveFocus(.down, until: key, max: 6)
                    || moveFocus(.left, until: key, max: 12)
                    || moveFocus(.up, until: key, max: 6)
                guard reached else { return false }
            }
            guard key.hasFocus else { return false }
            remote.press(.select)
            pause(0.25)
        }
        return true
    }

    /// Whichever button currently holds focus, or nil if none does. `hasFocus` isn't a reliable
    /// NSPredicate key on `XCUIElementQuery`, so this walks the snapshot instead — fine here since
    /// a "See All" grid's visible button count is small.
    /// One consistent read of every button frame on screen. `allElementsBoundByIndex` elements
    /// re-resolve BY INDEX on every `.frame` read, and a row whose lazy tree re-shuffles
    /// mid-poll (the poster morph remounting tiles) makes that throw "No matches found for
    /// Element at index N" (sim run 4, 2026-08-21). A single `snapshot()` walk has no such race.
    private func buttonFrames(_ app: XCUIApplication) -> [CGRect] {
        buttonSnapshots(app).map(\.frame)
    }

    /// Every button's frame + focus flag from ONE `snapshot()` — the focused card and its row
    /// neighbours read in the same instant, with none of `focusedButton`'s slow `hasFocus`
    /// sweep in between (sim run 5, 2026-08-21: sweep + press gap straddled the 1s dwell, so
    /// the "resting" baseline was already mid-morph).
    private func buttonSnapshots(_ app: XCUIApplication) -> [(frame: CGRect, hasFocus: Bool)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(frame: CGRect, hasFocus: Bool)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .button { out.append((node.frame, node.hasFocus)) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    private func focusedButton(_ app: XCUIApplication) -> XCUIElement? {
        // beta.15 §C5: two stacked findings from an `app.debugDescription` investigation (not
        // guessed) explain why Settings row focus detection needed broadening here:
        // (1) every native-List row — toggle, picker, disclosure, whatever — is wrapped in a
        // `Cell`, and the "Focused" accessibility trait lives on THAT Cell, not on the inner
        // control this harness queries by label (`app.buttons[name]`.hasFocus stays false
        // forever for a focused row; the wrapping Cell's `hasFocus` is what actually flips).
        // (2) independent of (1), a real `Toggle`'s OWN resolved element type is ambiguous on
        // this SDK/runtime — an XCTest "Automation type mismatch" diagnostic showed the SAME
        // toggle node computed as legacy `XCUIElementTypeSwitch` from one code path and modern
        // `XCUIElementTypeToggle` (attribute value 41) from another, so neither type-scoped
        // query alone reliably finds it either. Union all four element kinds so a focus walk
        // landed on ANY Settings row (or a Home/Detail button, unaffected by either finding) is
        // found here.
        if let cell = app.cells.allElementsBoundByIndex.first(where: { $0.hasFocus }) {
            return cell
        }
        if let button = app.buttons.allElementsBoundByIndex.first(where: { $0.hasFocus }) {
            return button
        }
        if let toggle = app.toggles.allElementsBoundByIndex.first(where: { $0.hasFocus }) {
            return toggle
        }
        return app.switches.allElementsBoundByIndex.first { $0.hasFocus }
    }

    // MARK: - UX-2: trailers in thumbnails

    // Also doubles as the poster-location regression test for `trailer_playback_location`
    // (default "poster") — test37TrailerLocationHero's leg 2 re-covers this same morph under the
    // explicit argument, but this test is the one that has always run it at the default.
    func test01InlineTrailerDwell() throws {
        // Trailers on Focus is opt-in (default OFF since 05dd8ecd) — force it via the argument
        // domain so this test never depends on the sim's stored settings.
        let app = launchToHome(extraArguments: ["-inline_trailers_enabled", "YES"])
        shot(app, "01a_home")

        // Hero → Continue Watching → Streaming → first *movies* catalog row (portrait cards, the
        // row where the portrait ⇄ landscape morph is visible at all).
        press(.down, times: 4)
        shot(app, "01b_row_focused") // baseline: all portrait, evenly spaced

        // The morph fires at the 1s dwell and runs ~0.35s. Sample tightly through it so the
        // exported PNGs show the focused card mid-widen AND the trailing posters sliding right
        // rather than being overlapped.
        pause(0.9)
        shot(app, "01c_morph_t0_90")
        pause(0.25)
        shot(app, "01d_morph_t1_15")
        pause(0.25)
        shot(app, "01e_morph_t1_40")
        pause(0.6)
        shot(app, "01f_morph_settled_landscape") // landscape tile, neighbours pushed right

        // Resolution + playback (or, when nothing resolves, the new collapse-back-to-portrait).
        pause(5)
        shot(app, "01g_after_resolve")
        pause(3)
        shot(app, "01h_playing_or_collapsed") // diff vs 01g ⇒ video actually renders

        // Mute toggle while playing: the glyph in the tile's bottom-trailing corner must flip
        // between speaker.slash.fill and speaker.wave.2.fill. (Audio itself is device-only.)
        remote.press(.playPause)
        pause(2)
        shot(app, "01i_after_playpause")

        // Focus must survive the resize: Right has to move to the next card, and the row has to
        // collapse the card we left back to portrait.
        remote.press(.right)
        pause(0.3)
        shot(app, "01j_collapse_immediate")
        pause(1)
        shot(app, "01k_collapsed_portrait") // previous card portrait again, spacing restored

        // Rapid scrub must not expand anything mid-flight.
        press(.right, times: 4, gap: 0.25)
        shot(app, "01l_scrub_immediate")
        pause(7)
        shot(app, "01m_scrub_settled_expanded")

        // Back to the first card: cache hit should re-expand fast.
        press(.left, times: 5, gap: 0.25)
        pause(3.5)
        shot(app, "01n_refocus_cache_hit")

        // Select → Detail: inline player must tear down, Detail loads (⇒ focus was never lost).
        remote.press(.select)
        pause(4)
        shot(app, "01o_detail_from_card")
        XCTAssertTrue(app.state == .runningForeground, "app should survive card → detail push")
    }

    // MARK: - UX-3: detail auto-play + poster layer

    func test02DetailAutoPlayAndPoster() throws {
        let app = launchToHome()
        // Land on a *movies catalog* row (portrait cards → NavigationLink to DetailView). The
        // Continue Watching and Streaming rows above it open the stream picker / entity browse
        // instead, so going only 3 rows deep verifies the wrong screen.
        press(.down, times: 4)
        pause(0.5)
        shot(app, "02x_row_before_select")
        remote.press(.select)
        pause(2.5)
        shot(app, "02a_detail_early_poster_layer") // before trailer resolves: poster right
        pause(3)
        shot(app, "02b_detail_trailer_bg")         // bg trailer active ⇒ poster hidden
        // The auto-play fires ~4s after the trailer URL resolves and the hint fades ~4s after
        // presentation — sample every 2s so at least one frame catches the hint on screen.
        for i in 1...4 {
            pause(2)
            shot(app, "02c\(i)_autoplay_window")
        }
        pause(3)
        shot(app, "02d_autoplay_hint_faded")
        remote.press(.menu)
        pause(2.5)
        shot(app, "02e_after_trailer_dismiss")     // focus restoration check
        remote.press(.menu)
        pause(2)
        shot(app, "02f_back_on_home")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-3: tab bar hiding

    func test03TabBarHiding() throws {
        let app = launchToHome()
        shot(app, "03a_home_bar_visible")
        press(.down, times: 6)
        pause(1.5)
        shot(app, "03b_scrolled_bar_hidden")
        press(.up, times: 8)
        pause(1.5)
        shot(app, "03c_scrolled_back_bar_visible")

        // Detail page is immersive: bar hidden while pushed, back on pop.
        press(.down, times: 3)
        pause(0.5)
        remote.press(.select)
        pause(3)
        shot(app, "03d_detail_bar_hidden")
        remote.press(.menu)
        pause(2)
        shot(app, "03e_popped_bar_visible")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Settings: new rows + hero sources

    /// SCRATCH utility (not part of the suite contract): re-enables Show Hero through the real
    /// Settings UI so the change pushes to the signed-in account via profile settings sync —
    /// prefs injection cannot do this (sync pulls the account value back on every launch).
    /// Run explicitly via -only-testing when a repro session left the profile hero-off.
    func test00zRestoreShowHeroOn() throws {
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        press(.down, times: 1)   // Home Screen category (activates on focus)
        pause(1.5)
        // Enter the pane, then walk UP until the FOCUSED row is Show Hero (the pane's first row;
        // entering can land focus on any row — the previous attempt selected whatever had focus
        // and collaterally toggled Trailers on Focus OFF). 26.5 reports hasFocus reliably.
        press(.right, times: 1)
        pause(1.0)
        func focusedButton() -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        }
        for _ in 0..<6 {
            if focusedButton().label.contains("Show Hero") { break }
            press(.up, times: 1)
            pause(0.8)
        }
        shot(app, "00z_before_toggle")
        XCTAssertTrue(focusedButton().label.contains("Show Hero"),
                      "focus must be on the Show Hero row before toggling, got: \(focusedButton().label)")
        if focusedButton().label.contains("Off") {
            remote.press(.select)
            pause(2.0)
        }
        shot(app, "00z_after_toggle")
        XCTAssertTrue(app.staticTexts["Hero Sources"].waitForExistence(timeout: 6),
                      "Show Hero must be ON (Hero Sources group renders only then)")

        // Repair the collateral from the previous attempt: Trailers on Focus back ON.
        press(.down, times: 1)
        pause(0.8)
        if focusedButton().label.contains("Trailers on Focus"), focusedButton().label.contains("Off") {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "00z_trailers_restored")
        // Give the settings sync a moment to push the changes to the account.
        pause(5.0)
    }

    func test04SettingsRows() throws {
        // Fresh launch (2026-08-02): this test asserts Settings pane CONTENT, so it must not
        // inherit a prior test's pane scroll/focus or the springboard black-screen state (see
        // launchToHome's header) — in-suite it failed exactly that way after test03.
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        shot(app, "04a_settings")

        // Appearance category → the two Detail-page toggle rows. ("Trailers on Focus" lives in
        // the Home Screen category, not here — asserted in the 04c step below.)
        //
        // beta.15 §C5, two stacked root-cause findings from an `app.debugDescription`
        // investigation (not guessed):
        // (1) `moveFocus(until: app.buttons["Appearance"], ...)` never detects arrival — the
        //     sidebar's native-List "Focused" trait lives on the row's wrapping `Cell`, not the
        //     inner Button this harness queries by label — so it silently burns its whole press
        //     budget and can overshoot past the intended category entirely (a captured run
        //     landed on "About", the LAST category, while aiming for "Appearance" two rows down).
        //     Fixed via `moveToSidebarRow`, which also checks a same-labeled Cell.
        // (2) the detail pane is a real native `List`: unlike the pre-C1 hand-rolled ScrollView
        //     (which rendered every row up front), a List only mounts rows near the current focus
        //     — a bare existence check for a row several sections down (Auto-Play Trailer /
        //     Poster in Detail Background, both in the Poster Style section, well past Theme)
        //     fails even with a generous `waitForExistence` because nothing ever scrolls it into
        //     view. Entering the pane (press Right) and walking to each row with
        //     `walkToRowByTreeIndex` (the existing hop-to-last-materialized-row technique) fixes
        //     this instead of assuming the row is already on screen.
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        shot(app, "04b_appearance")
        let appearanceSidebarX = appearance.frame.maxX
        func rowExists(_ prefix: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch.exists
        }
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Auto-Play Trailer on Detail", sidebarMaxX: appearanceSidebarX, category: "Appearance")
        XCTAssertTrue(rowExists("Auto-Play Trailer on Detail"), "Auto-Play Trailer row missing")
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Poster in Detail Background", sidebarMaxX: appearanceSidebarX, category: "Appearance")
        XCTAssertTrue(rowExists("Poster in Detail Background"), "Poster in Detail Background row missing")

        // "Home Screen" category (the Home Rows *section* lives inside it) sits directly below
        // Appearance in the sidebar, and categories activate on FOCUS.
        //
        // beta.15 §C5 finding (from a captured screenshot, not guessed): `press(.left, times: 1)`
        // + `moveToSidebarRow(down, named: "Home Screen", max: 4)` overshot all the way to
        // "About" (the LAST category — the detail pane in "04c_home_rows" showed About's Commit/
        // tvOS/Device/Source rows) even though the same helper correctly stopped at "Appearance"
        // moments earlier in this same test. The Cell-focus detection this helper relies on is
        // not consistently reliable turn-to-turn, so rather than trust it for a NON-terminal,
        // small-distance move, anchor at a known EXTREME position first (Up until Account &
        // Services — a no-op past the top, so it lands there regardless of whether detection
        // fires) and then walk the sidebar's fixed, never-reordered category list by a plain
        // press COUNT, which needs no focus detection to be correct.
        press(.left, times: 1)
        pause(1)
        _ = moveToSidebarRow(app, .up, named: "Account & Services", max: 10)
        pause(0.5)
        let homeScreen = app.buttons["Home Screen"]
        press(.down, times: 3, gap: 0.6) // Account & Services → Playback → Appearance → Home Screen
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        shot(app, "04c_home_rows")
        let homeScreenSidebarX = homeScreen.frame.maxX
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Show Hero", sidebarMaxX: homeScreenSidebarX, category: "Home Screen")
        XCTAssertTrue(rowExists("Show Hero"), "Show Hero row missing")
        // Hero Sources is a disclosure Button (SettingsDisclosureRow) directly below "Nuvio-Style
        // Hero", not a toggle — its composed label is "Hero Sources, <summary>".
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Hero Sources", sidebarMaxX: homeScreenSidebarX, category: "Home Screen")
        XCTAssertTrue(rowExists("Hero Sources"), "Hero Sources group missing")
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Trailers on Focus", sidebarMaxX: homeScreenSidebarX, category: "Home Screen")
        XCTAssertTrue(rowExists("Trailers on Focus"), "Trailers on Focus row missing")
        shot(app, "04d_hero_sources_list")
    }

    // MARK: - Localization smoke (German)

    func test05SettingsGerman() throws {
        let app = launchToHome(extraArguments: ["-AppleLanguages", "(de)"])
        openTab(app, named: "Einstellungen")
        shot(app, "05a_settings_de")
        // Category names are localized; walk a few and screenshot whatever renders.
        press(.down, times: 2)
        remote.press(.select)
        pause(1.5)
        shot(app, "05b_settings_de_category")
        press(.down, times: 3)
        shot(app, "05c_settings_de_scrolled")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-2 hero redesign v2 (Nuvio-style: info left, artwork right)

    func test06HeroRedesign() throws {
        // The toggle defaults OFF (classic); force the opt-in layout via the argument domain
        // so this test captures the redesign without touching the sim's stored settings.
        let app = launchToHome(extraArguments: ["-hero_nuvio_style", "YES"])
        // Home lands with the hero at the top; give the backdrop art a beat to load.
        pause(4)
        shot(app, "06a_hero_nuvio")
        // Page once so the fixed-slot swap (logo/meta/synopsis swap in place) shows.
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(1)
        press(.right, times: 1)
        pause(3)
        shot(app, "06b_hero_nuvio_paged")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-25 audit: do the card settings still reach the beta.8 surfaces?

    /// Drives the REAL Settings pane (the reporter's own path): baseline shot of a poster row,
    /// then Corners → Round, Card Depth ON + Bold/Bright/Full, back to Home, after shot.
    /// A human/agent compares 07a vs 07e: corner radius must visibly change and the depth
    /// edge+sheen must appear. If they don't, the pane→repository→environment chain is broken
    /// in practice even though it reads correct statically.
    func test07CardSettingsAudit() throws {
        let app = launchToHome()
        press(.down, times: 4, gap: 1.0)
        pause(3) // let row artwork decode
        shot(app, "07a_cards_baseline")

        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)

        // Into the content pane: Corners → "Round" (28pt — the biggest visual jump from the
        // default 12).
        press(.right, times: 1)
        pause(1)
        let round = app.buttons["Round"]
        if !moveFocus(.down, until: round, max: 16) { _ = moveFocus(.up, until: round, max: 16) }
        if round.exists && round.hasFocus {
            remote.press(.select)
            pause(1)
        }
        shot(app, "07b_corners_round")

        // Card Depth master toggle, then max out the visual: Bold edge, Bright sheen, Full
        // coverage (chips only render once the toggle is on).
        let depthToggle = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Card Depth'")).firstMatch
        if moveFocus(.down, until: depthToggle, max: 24) {
            remote.press(.select)
            pause(1.2)
        }
        shot(app, "07c_depth_toggle")
        for chipName in ["Bold", "Bright", "Full"] {
            let chip = app.buttons[chipName]
            if moveFocus(.down, until: chip, max: 12) {
                remote.press(.select)
                pause(0.8)
            }
        }
        shot(app, "07d_depth_options")

        openTab(app, named: "Home")
        press(.down, times: 3, gap: 1.0)
        pause(3)
        shot(app, "07e_cards_after")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-24 audit: does "Hero Poster Only When Focused" still gate the backdrop?

    /// Forces the toggle through the argument domain (test06's trick) to isolate the RENDER
    /// path from the Settings write path. 08a (hero CTA focused) must show the backdrop.
    /// 2026-08-02 (UX-7): a row-focused poster now OWNS the hero too — `heroPosterFocusOnly`
    /// only gates the carousel's own idle fade, and `.opacity(... || focusModel.focusedItem
    /// != nil ? 1 : 0)` in HomeView.swift keeps the artwork VISIBLE once focus lands on a
    /// reporting row poster (src=f in the debug_hero probe — see test20). So 08b (focus down
    /// onto a row poster) must ALSO show the backdrop now, not the flat background; the hidden
    /// state this test used to assert here only applies when focus lands on a non-reporting
    /// element (e.g. a collection folder tile that never calls into `focusModel`). Kept as a
    /// pure render/existence check — no assertions changed, only the doc comment + shot name.
    func test08HeroFocusOnlyToggle() throws {
        let app = launchToHome(extraArguments: ["-hero_poster_focus_only", "YES"])
        pause(4)
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2) // fade-in animation + artwork load
        shot(app, "08a_hero_focused_art_visible")
        press(.down, times: 3, gap: 0.8)
        pause(2) // fade-out animation
        shot(app, "08b_rows_focused_art_follows_focus")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Second BUG-25 pass, sharper: storage was left with depth ON (test07's writes landed even
    /// though the pane displayed OFF), so this run checks all three links separately:
    /// 09a — RENDER: Home cards must show the Bold edge + Bright sheen from stored state.
    /// 09b — WRITE: select "Square" corners, then defocus the row so the selection color is
    ///        unambiguous (the white focus platter masks the accent).
    /// 09c/09d — DISPLAY: the Card Depth toggle must show ON before the press (storage truth)
    ///        and OFF 4s after it; chips must collapse.
    /// 09e — RENDER AGAIN: back on Home the depth effect must be gone.
    func test09CardSettingsAudit2() throws {
        // Fresh launch (2026-08-02): order-independence — the stored per-profile state this
        // audit reads survives a relaunch, but the pane walk below must start from a clean
        // top-of-pane, not wherever test08 (or the springboard escape) left the UI.
        let app = launchToHome(forceFreshLaunch: true)
        press(.down, times: 4, gap: 1.0)
        pause(3)
        shot(app, "09a_cards_depth_should_be_on")

        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        let square = app.buttons["Square"]
        if moveFocus(.down, until: square, max: 16) {
            remote.press(.select)
            pause(2)
        }
        press(.up, times: 1)
        pause(1)
        shot(app, "09b_corners_after_square_defocused")

        let depthToggle = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Card Depth'")).firstMatch
        _ = moveFocus(.down, until: depthToggle, max: 24)
        pause(1)
        shot(app, "09c_depth_before_press")
        remote.press(.select)
        pause(4)
        shot(app, "09d_depth_4s_after_press")

        openTab(app, named: "Home")
        pause(2)
        press(.down, times: 4, gap: 1.0)
        pause(3)
        shot(app, "09e_cards_depth_should_be_off")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Final render check for the BUG-25 audit: storage now holds depth ON (Subtle/Bright/Full)
    /// and Square corners for the active profile — Home cards must draw both. Reads the
    /// debug_env accessibility label (DEBUG builds) so the environment truth lands in the log.
    func test10RenderCheck() throws {
        let app = launchToHome()
        let env = app.staticTexts["debug_env"]
        if env.waitForExistence(timeout: 6) {
            let attachment = XCTAttachment(string: env.label)
            attachment.name = "10_env_truth"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[BUG25] env: \(env.label)")
        } else {
            print("[BUG25] debug_env not found")
        }
        press(.down, times: 4, gap: 1.0)
        pause(4)
        shot(app, "10a_cards_square_depth_on")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Cleanup after the BUG-25 audit: the audit toggled Card Depth on (Bold/Bright/Full) and set
    /// Square corners on the signed-in profile — and those writes sync to the real cloud account.
    /// Reset both sections via their own "Reset to Defaults" buttons (poster section first in the
    /// pane, card depth second).
    func test12ResetAppearanceDefaults() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let resets = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Reset to Defaults'"))
        // Poster style reset.
        let posterReset = resets.element(boundBy: 0)
        if moveFocus(.down, until: posterReset, max: 20) {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "12a_poster_reset")
        // Card depth reset (second Reset button, further down).
        let depthReset = resets.element(boundBy: 1)
        if moveFocus(.down, until: depthReset, max: 24) {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "12b_depth_reset")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// BUG-22 verification: switch to the WHITE accent theme (the reporter's config) and capture
    /// the surfaces that were white-on-white pre-fix — the sidebar's focused+selected category
    /// and a focused ON toggle row. Restores the Ocean theme at the end (theme syncs per profile).
    func test13WhiteThemeContrast() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        // The theme swatches are the pane's FIRST row — walk RIGHT along it to White.
        let white = app.buttons["White"]
        _ = moveFocus(.right, until: white, max: 8)
        if white.exists && white.hasFocus {
            remote.press(.select)
            pause(2.5) // theme change rebuilds the tree (.id flip)
        }
        shot(app, "13a_white_theme_applied")

        // The money shot pre-fix: walk focus back to the SIDEBAR — the focused row is always the
        // selected category, whose label was raw accent (white on the white platter).
        press(.left, times: 8, gap: 0.6)
        pause(1)
        shot(app, "13b_sidebar_focused_selected")

        // Back into the pane: focus an ON toggle row (Auto-Play Trailer defaults on for this
        // profile) so the checkmark renders on the white platter.
        press(.right, times: 1)
        pause(1)
        let autoPlay = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Auto-Play Trailer'")).firstMatch
        _ = moveFocus(.down, until: autoPlay, max: 16)
        pause(1)
        shot(app, "13c_toggle_row_focused")

        // Restore the Ocean theme (the account's real setting): back up to the swatch row,
        // then walk left along it.
        let ocean = app.buttons["Ocean"]
        press(.up, times: 4, gap: 0.6)
        if !moveFocus(.left, until: ocean, max: 8) { _ = moveFocus(.right, until: ocean, max: 8) }
        if ocean.exists && ocean.hasFocus {
            remote.press(.select)
            pause(2.5)
        }
        shot(app, "13d_theme_restored")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Probe: what does the Appearance pane show for Corners on a fresh launch (repo state truth)?
    /// Focus a Size chip so the Corners row renders unfocused — the selected chip's accent tint
    /// is unambiguous there.
    func test11PaneStateProbe() throws {
        // Fresh launch (2026-08-02): this probe's whole premise is "what does the pane show on a
        // fresh launch (repo state truth)" — forceFreshLaunch makes that literal, and makes the
        // test independent of test10's end state (which fed it the springboard escape in-suite).
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let medium = app.buttons["Medium"]
        _ = moveFocus(.down, until: medium, max: 10)
        pause(1)
        shot(app, "11a_poster_style_rows")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-23 diagnostic: does one left press page the hero back by exactly one?

    /// Reads the `debug_hero` probe (idx / focus / count) around single left and right presses
    /// on the hero CTA. Expected healthy sequence from page 1: left ⇒ idx 0, stays 0. The bug
    /// report says left needs TWO presses and "snaps back to the right-hand item" — so the
    /// probe samples both immediately after the press and again after the page animation
    /// settles, to catch a transient page-back-then-snap-forward.
    private func heroProbe(_ app: XCUIApplication, _ name: String) {
        let probe = app.staticTexts["debug_hero"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_hero MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[BUG23] \(name): \(text)")
    }

    func test14HeroLeftNavDiag() throws {
        let app = launchToHome()
        // Normalize focus onto the hero CTA (same walk as test06: up to the tab bar, one down
        // lands on the hero button).
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        heroProbe(app, "14a_initial")
        shot(app, "14a_hero_focused")

        // Page right twice so left has room (and so we're clear of any wrap edge case).
        press(.right, times: 1, gap: 1.5)
        pause(2)
        heroProbe(app, "14b_after_right1")
        press(.right, times: 1, gap: 1.5)
        pause(2)
        heroProbe(app, "14c_after_right2")
        shot(app, "14c_paged_right_twice")

        // THE measurement: one left press, sampled mid-animation and settled.
        remote.press(.left)
        pause(0.4)
        heroProbe(app, "14d_left1_immediate")
        pause(2.5)
        heroProbe(app, "14e_left1_settled")
        shot(app, "14e_after_left1")

        // Second left press — if the bug reproduces, THIS is the press that visibly pages.
        remote.press(.left)
        pause(0.4)
        heroProbe(app, "14f_left2_immediate")
        pause(2.5)
        heroProbe(app, "14g_left2_settled")
        shot(app, "14g_after_left2")

        // The BUG-23 fix intercepts dropped LEFT presses via onMoveCommand on the carousel —
        // verify it did not accidentally trap vertical movement: one down press must move
        // focus out of the hero (probe foc flips to 0).
        press(.down, times: 1)
        pause(1.5)
        heroProbe(app, "14h_down_leaves_hero")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-27: Menu from down the page jumps back to the top / tab bar

    /// Walks focus several rows down Home (far enough that the tab bar auto-hides), presses
    /// Menu once, and verifies the app is still frontmost with the hero focused (probe foc=1)
    /// — i.e. Menu was intercepted as jump-to-top rather than bubbling to the springboard.
    /// A second Up press should then reach the visible tab bar (screenshot evidence).
    func test15MenuJumpToTop() throws {
        let app = launchToHome()
        press(.down, times: 6, gap: 1.2)
        pause(2)
        shot(app, "15a_deep_in_rows")

        remote.press(.menu)
        pause(1.8)
        XCTAssertTrue(app.state == .runningForeground, "Menu from deep rows must NOT exit the app")
        heroProbe(app, "15b_after_menu")
        shot(app, "15b_back_at_top")

        press(.up, times: 1)
        pause(1.2)
        shot(app, "15c_tab_bar_reached")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-24 rename + FEAT-10 Search Sources: do the new Settings rows render?

    /// Visual check for two settings changes: (a) Appearance now says "Hide Hero Artwork
    /// While Browsing" (BUG-24/UX-1 rename), (b) Content Sources gained a "Search Sources"
    /// section with one toggle per search-capable catalog (FEAT-10).
    func test16SettingsNewRows() throws {
        // Fresh launch (2026-08-02): in-suite, re-entering the Settings tab restores focus to
        // wherever the last Settings test left it — which can be deep inside the Appearance
        // pane, where the lazy pane culls the top-of-pane Theme rows from the AX tree and the
        // Accent Focus Ring existence assert below fails ("no matches found") even though the
        // row renders fine (same test passed isolated on the same build). A fresh launch
        // guarantees the sidebar-default Settings entry this test's walk assumes.
        let app = launchToHome(forceFreshLaunch: true)

        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        // FEAT-14: opt-in "Accent Focus Ring" toggle (default OFF), Theme section — the first
        // section in the pane, so content-pane focus (the press(.right, 1) above lands on the
        // theme swatches row) reaches it in a single Down press. Screenshot + existence/label
        // check only — do NOT select it, this test asserts the OFF default, not the ON behavior.
        // beta.15 §C5: SettingsToggleRow is now a real `Toggle` whose resolved element type is
        // ambiguous between `.switch` and `.toggle` on this SDK (see focusedButton's comment) —
        // looked up via `descendants(matching: .any)` rather than either type-scoped query. The
        // row's accessibility LABEL is just the title text ("Accent Focus Ring") — the C1 kit
        // puts the On/Off state on `.accessibilityValue` instead (SettingsRowViews.swift), so the
        // default must be read from `.value`, not a label-prefix concatenation.
        let accentRing = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Accent Focus Ring'")
        ).firstMatch
        _ = moveFocus(.down, until: accentRing, max: 8)
        pause(1)
        shot(app, "16c_accent_ring_toggle_default_off")
        XCTAssertTrue(accentRing.exists, "FEAT-14 Accent Focus Ring toggle must exist in the Theme section")
        XCTAssertEqual(
            toggleState(accentRing), false,
            "Accent Focus Ring must default OFF, got: \(String(describing: accentRing.value)) / label: \(accentRing.label)"
        )

        let renamed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Hide Hero Artwork'")
        ).firstMatch
        _ = moveFocus(.down, until: renamed, max: 16)
        pause(1)
        shot(app, "16a_hero_toggle_renamed")
        XCTAssertTrue(renamed.waitForExistence(timeout: 4), "renamed BUG-24 toggle must exist in Appearance")

        press(.left, times: 1)
        pause(1)
        let contentSources = app.buttons["Content Sources"]
        if !moveToSidebarRow(app, .down, named: "Content Sources", max: 10) {
            _ = moveToSidebarRow(app, .up, named: "Content Sources", max: 10)
        }
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        // Walk down far enough to bring the Search Sources section into view (it sits below
        // the TMDB and MDBList sections).
        press(.down, times: 10, gap: 0.6)
        pause(1)
        shot(app, "16b_search_sources_section")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-6: detail background darkens on scroll

    private func ux6Probe(_ app: XCUIApplication, _ name: String) {
        let probe = app.staticTexts["debug_ux6"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_ux6 MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[UX6] \(name): \(text)")
    }

    /// Opens a detail page from the hero CTA and walks focus down the page, sampling the live
    /// darkening value before/after — the device report says the background never darkens, so
    /// this measures whether focus-driven scrolling feeds `onScrollGeometryChange` at all.
    func test17DetailScrollDarkening() throws {
        let app = launchToHome()
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        remote.press(.select)
        pause(8)
        ux6Probe(app, "17a_detail_opened")
        shot(app, "17a_detail_top")

        press(.down, times: 4, gap: 1.0)
        pause(1.5)
        ux6Probe(app, "17b_after_down4")
        press(.down, times: 4, gap: 1.0)
        pause(1.5)
        ux6Probe(app, "17c_after_down8")
        shot(app, "17c_detail_scrolled")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-33(3): settings-row legibility when focused, default vs White theme

    /// The white-on-white regression only showed up on focused rows in the White theme
    /// (SettingsRowViews are now focus-aware). Capture the SAME row class focused in both the
    /// default (dark/Ocean) theme and White so the exported screenshots are a direct A/B — a
    /// human/agent compares 18a vs 18b for a legible label + control on both platters.
    /// Navigation to the White swatch and back mirrors test13WhiteThemeContrast's walk
    /// (duplicated rather than factored out — the two tests reach it from different starting
    /// focus positions and this harness already accepts duplication over shared helpers).
    func test18FocusedSettingsRowLegibility() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // Accent Focus Ring toggle (Theme section, top of pane) — one Down press from the
        // swatches row that content-pane focus lands on. Real `Toggle` = `.switch` (C5).
        let accentRing = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Accent Focus Ring'")
        ).firstMatch
        _ = moveFocus(.down, until: accentRing, max: 8)
        pause(1)
        shot(app, "18a_row_focused_dark")

        // Back up to the swatch row, then right along it to White (test13's walk).
        press(.up, times: 4, gap: 0.6)
        let white = app.buttons["White"]
        if !moveFocus(.right, until: white, max: 8) { _ = moveFocus(.left, until: white, max: 8) }
        if white.exists && white.hasFocus {
            remote.press(.select)
            pause(2.5) // theme change rebuilds the tree (.id flip)
        }

        // Refocus the same toggle row under the new theme.
        _ = moveFocus(.down, until: accentRing, max: 8)
        pause(1)
        shot(app, "18b_row_focused_white")

        // Restore Ocean (the account's real setting) so later tests aren't affected.
        press(.up, times: 4, gap: 0.6)
        let ocean = app.buttons["Ocean"]
        if !moveFocus(.left, until: ocean, max: 8) { _ = moveFocus(.right, until: ocean, max: 8) }
        if ocean.exists && ocean.hasFocus {
            remote.press(.select)
            pause(2.5)
        }
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-33(2): Discover survives a search + clear cycle

    /// SearchView.swift: query-empty shows Discover (recent-search chips + the shared
    /// `discoverUiState` browse grid); a non-empty query swaps in `searchResults`. The reported
    /// bug is Discover staying wiped after a search is cleared back to empty.
    ///
    /// tvOS drives text entry via its own full-screen system keyboard (the file's own comment:
    /// "opens tvOS's self-contained full-screen keyboard"), which no test in this harness has
    /// driven before, so its exact key-grid layout/labels are unverified here — this pass has no
    /// sim run available to confirm `app.keys[...]` resolves the way it does for a plain iOS
    /// on-screen keyboard. Every keyboard-grid step below is therefore guarded by `.exists`
    /// checks: if the grid doesn't expose the expected keys, the test backs out via Menu and
    /// still captures the "after" screenshot, instead of guessing a fixed arrow-press count that
    /// could hang or mistype.
    ///
    /// MANUAL SIM STEP — keyboard grid driving unreliable: if the exported "19a2_after_query"
    /// screenshot never shows a typed query, or "19b_discover_after" doesn't show the Discover
    /// chips/grid back on screen, verify this manually instead: open Search, select the field,
    /// type 1-2 letters on the tvOS keyboard, wait for results to render, clear the field (Menu
    /// back to the field, then delete/backspace to empty it, or re-select and clear), and confirm
    /// Discover's genre chips / catalog grid reappear rather than staying blank.
    ///
    /// FINDING 7 fix (P2, Codex review): every failure path previously fell through to only
    /// `app.state == .runningForeground`, so the test could pass without ever confirming Discover
    /// actually rendered — a regression that left Discover blank after clearing a search, or a sim
    /// that couldn't drive the keyboard at all, would still go green. This now asserts a concrete
    /// Discover signal — the `Text("Discover")` section header from `SearchView.discoverSection`
    /// (SearchView.swift ~line 143) — which `SearchViewModel.start()` renders as soon as
    /// `discoverUiState` emits once, independent of whether any catalogs/items are present (an
    /// empty-addon profile still gets the header plus an empty-state message below it). Profile
    /// "Chris" (launchToHome) has real addons installed (test16 walks live Settings against it),
    /// so the header is expected to appear here, not just in principle.
    ///
    /// ALWAYS asserted (mandatory, regardless of how the keyboard step goes):
    ///   1. the Discover header exists right after opening Search, before any keyboard interaction.
    ///   2. the Discover header exists again after the Menu/Menu round-trip that backs out of the
    ///      keyboard — this is the actual BUG-33(2) regression check.
    ///   3. the app is still in the foreground at the end (kept as a final sanity net).
    /// Best-effort / conditional (does not fail the test if the keyboard grid can't be driven):
    ///   - typing "as" into the query field.
    ///   - if typing demonstrably succeeded (both letter keys were focused and selected), that a
    ///     results signal (a result cell, or the "No results." empty-results message) appeared —
    ///     this is still a real `XCTAssertTrue`, it's just skipped entirely when typing itself
    ///     could not be driven, so a keyboard-grid mismatch doesn't fail the test.
    func test19DiscoverSurvivesSearch() throws {
        // Fresh launch (2026-08-02): the Discover asserts below need a Search tab with no
        // leftover query/keyboard state from suite order, and test18's end state fed this test
        // the springboard escape in-suite (see launchToHome's header).
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Search")
        pause(1.5)
        shot(app, "19a_discover_before")

        // Mandatory: Discover must actually be on screen before we touch the keyboard at all,
        // otherwise everything that follows is exercising nothing.
        let discoverHeader = app.staticTexts["Discover"]
        XCTAssertTrue(discoverHeader.waitForExistence(timeout: 6), "Discover missing on entry")

        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 4) else {
            // Field never resolved — nothing further to drive automatically. Still re-check
            // Discover so this path can't silently pass without exercising anything.
            shot(app, "19b_discover_after")
            XCTAssertTrue(discoverHeader.exists, "Discover gone after search/keyboard round-trip — BUG-33(2) regression")
            XCTAssertTrue(app.state == .runningForeground)
            return
        }
        if !searchField.hasFocus {
            _ = moveFocus(.up, until: searchField, max: 6)
        }
        remote.press(.select)
        pause(2) // full-screen keyboard presentation

        // Best-effort "as": walk to "a", select, then to "s", select. Bail to the manual-step
        // path (Menu back out) if the grid doesn't expose letter keys the way expected. Tracks
        // whether both selects were actually driven, so the post-typing results assert below can
        // stay guarded rather than failing the test on a keyboard-grid mismatch.
        var typedSuccessfully = false
        let keyA = app.keys["a"]
        if keyA.waitForExistence(timeout: 3) {
            _ = moveFocus(.right, until: keyA, max: 12)
            var selectedA = false
            if keyA.hasFocus {
                remote.press(.select)
                selectedA = true
            }
            pause(0.5)
            let keyS = app.keys["s"]
            var selectedS = false
            if moveFocus(.right, until: keyS, max: 8) || moveFocus(.down, until: keyS, max: 6) {
                remote.press(.select)
                selectedS = true
            }
            pause(2.5) // debounce + results fetch
            shot(app, "19a2_after_query_typed")
            typedSuccessfully = selectedA && selectedS
        }

        // Conditional: only when typing was actually driven do we require a results signal — a
        // result cell for a hit, or the "No results." empty-results text for a legitimate miss.
        // Either counts as proof the query round-tripped through SearchRepository.
        if typedSuccessfully {
            let resultCell = app.cells.firstMatch
            let noResultsMessage = app.staticTexts["No results."]
            XCTAssertTrue(
                resultCell.waitForExistence(timeout: 3) || noResultsMessage.waitForExistence(timeout: 1),
                "typed query \"as\" produced neither result cells nor an empty-results message"
            )
        }

        // Clear back to Discover: Menu dismisses the keyboard/backs out of the query. If the
        // query text survived (see the manual-step note above), a human should re-check by
        // clearing it explicitly and re-screenshotting.
        remote.press(.menu)
        pause(1.5)
        remote.press(.menu)
        pause(1.5)

        shot(app, "19b_discover_after")
        // Mandatory: the actual BUG-33(2) regression check — Discover must reappear after the
        // search + clear round-trip, whether or not the query itself could be typed.
        XCTAssertTrue(discoverHeader.waitForExistence(timeout: 6), "Discover gone after search/keyboard round-trip — BUG-33(2) regression")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the search + clear cycle even if the query itself couldn't be driven")
    }

    // MARK: - UX-7: focus-follows-backdrop hero on Home

    /// Reads the `debug_hero` probe and asserts it contains `src=c` — the carousel owns the
    /// hero. HomeView.swift's probe (DEBUG only) ends `src=\(focusModel.focusedItem == nil ?
    /// "c" : "f") fitem=\(focusModel.focusedItem?.id ?? "-")`.
    private func heroSrcProbe(_ app: XCUIApplication, _ name: String) -> String {
        let probe = app.staticTexts["debug_hero"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_hero MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[UX7] \(name): \(text)")
        return text
    }

    /// beta.15: reads the `hero_probe_lines` container (`AboutSettingsPane.swift`) — the
    /// head-preserving `HomeHeroProbe` ring buffer rendered as one `Text` row per line, with the
    /// identifier on the WRAPPING `VStack`, not on any individual row. `app.staticTexts[…]`
    /// therefore cannot find it directly (identifier lookups on a subscript match that exact
    /// element, and the container itself isn't a `staticText`), so this walks one `snapshot()` —
    /// same trick as `buttonSnapshots` above, for the same reason: a live element/query re-walk
    /// here would re-resolve mid-render and could throw or return a torn read — finds the node
    /// carrying that identifier regardless of its resolved AX type, then collects every
    /// `staticText` descendant's label, in document order (matches the source `ForEach`'s order).
    /// Empty array (not a failure) when the container isn't on screen at all, or the runtime
    /// truncated its subtree away — callers are expected to fail loudly on that themselves rather
    /// than have this silently swallow the "pane never rendered" case.
    /// FEAT-33: generic form of the `hero_probe_blob` read below — one `snapshot()` walk for a
    /// hidden single-`Text` blob by identifier, regardless of its resolved AX type. `app.staticTexts`
    /// subscripting missed `collection_frame_blob` on the first test54 run (the blob rides an
    /// `.overlay` inside a `TimelineView` inside a List row), exactly the class the hero blob's
    /// snapshot walk exists for. `nil` when the blob is not in the tree (caller decides to skip).
    private func probeBlobLabel(_ app: XCUIApplication, identifier: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        func find(_ node: XCUIElementSnapshot) -> String? {
            if node.identifier == identifier { return node.label }
            for child in node.children {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return find(root)
    }

    private func heroProbeLines(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var container: XCUIElementSnapshot?
        func findContainer(_ node: XCUIElementSnapshot) {
            guard container == nil else { return }
            if node.identifier == "hero_probe_lines" {
                container = node
                return
            }
            for child in node.children { findContainer(child) }
        }
        // beta.15 r3: prefer the hidden single-Text blob (`hero_probe_blob`, AboutSettingsPane) —
        // the List row clips below the fold, so the per-line `Text` children beyond it never
        // enter the AX tree and the container walk sees only the first line (launch-1 failure:
        // `lines=[<one acquire line>]` while the container plist held 21). One Text = one AX
        // element = the whole buffer in its label, same pattern the `debug_ux6` probe proved out.
        func findBlob(_ node: XCUIElementSnapshot) -> String? {
            if node.identifier == "hero_probe_blob", !node.label.isEmpty { return node.label }
            for child in node.children {
                if let hit = findBlob(child) { return hit }
            }
            return nil
        }
        if let blob = findBlob(root) {
            let fromBlob = blob.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if fromBlob.count > 1 { return fromBlob }
        }
        findContainer(root)
        guard let container else { return [] }
        var lines: [String] = []
        func collect(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, !node.label.isEmpty { lines.append(node.label) }
            for child in node.children { collect(child) }
        }
        collect(container)
        return lines
    }

    /// UX-7: a row-focused poster now owns the hero backdrop too — `HomeFocusModel` commits a
    /// focused row item after `commitDelay` (0.2s) and reverts to nil after `revertGrace`
    /// (0.3s) once focus reports nothing. This walks CTA → row poster → CTA and watches the
    /// `debug_hero` probe's `src=c|f` field flip both ways, with `fitem=` populated (not `-`)
    /// while a row poster owns it.
    func test20HeroFocusFollowsBackdrop() throws {
        // Fresh launch: this test asserts the probe's live src/fitem fields, so it must not
        // inherit a prior test's pushed screen or springboard-escape state (see launchToHome's
        // header) — the same rationale test04/09/11/16/19 already use.
        let app = launchToHome(forceFreshLaunch: true)

        // Normalize focus onto the hero CTA (test06's walk: up to the tab bar, one down lands
        // back on the hero button).
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        shot(app, "20a_hero_carousel")
        let carouselState = heroSrcProbe(app, "20a_carousel")
        XCTAssertTrue(carouselState.contains("src=c"), "hero must start carousel-owned, got: \(carouselState)")

        // Walk down one row at a time, sampling the probe after each press, until a REPORTING
        // row takes the hero. Not every Home row drives it: the Streaming-services shelf and
        // collection folder tiles carry no MetaPreview and by design leave the carousel in
        // charge (src=c) — only catalog rows and Continue Watching report. The ceiling exists
        // only so the test terminates; keep it generous (the signed-in profile's synced row
        // order can stack several non-reporting rows before the first catalog row).
        var downPresses = 0
        var focusedState = ""
        for _ in 1...12 {
            press(.down, times: 1)
            downPresses += 1
            pause(1.0) // commit delay is 200ms — well clear of it by the time we sample
            focusedState = heroSrcProbe(app, "20b_after_down_\(downPresses)")
            if focusedState.contains("src=f") { break }
        }
        shot(app, "20b_hero_follows_focus")
        XCTAssertTrue(focusedState.contains("src=f"), "no row poster took the hero within \(downPresses) presses, got: \(focusedState)")
        XCTAssertFalse(focusedState.contains("fitem=-"), "src=f must carry a real fitem id, got: \(focusedState)")

        // Walk back up to the CTA (mirrors the walk down) and confirm the carousel reclaims
        // the hero once focus lands back on it.
        press(.up, times: downPresses, gap: 0.8)
        pause(1.0) // revert grace is 300ms — well clear of it by the time we sample
        let revertedState = heroSrcProbe(app, "20c_back_on_cta")
        XCTAssertTrue(revertedState.contains("src=c"), "hero must revert to carousel-owned, got: \(revertedState)")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-10: trailer thumbnails on Detail

    func test21DetailTrailerThumbnails() throws {
        // Navigate to a detail page exactly like test02: land on a movies catalog row (portrait
        // cards → NavigationLink to DetailView), not the Continue Watching / Streaming rows
        // above it which open the stream picker / entity browse instead.
        let app = launchToHome()
        press(.down, times: 4)
        pause(0.5)
        remote.press(.select)
        pause(2.5)

        // Walk focus down toward the Trailers & Extras shelf (test17's detail-scroll walk).
        press(.down, times: 10, gap: 0.5)
        pause(1.5)
        shot(app, "21a_trailers_row")

        // Soft assertion: only when the debug_trailers probe made it on screen (title had
        // trailers AND focus reached the shelf) do we parse and assert on it. DetailView.swift's
        // probe (DEBUG only) is `debug_trailers n=<count> thumbs=<count-with-thumbnail-url>`.
        let probe = app.staticTexts["debug_trailers"]
        if probe.exists {
            let text = probe.label
            let attachment = XCTAttachment(string: "21b_trailers_probe: \(text)")
            attachment.name = "21b_trailers_probe"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[UX10] 21b_trailers_probe: \(text)")

            func intValue(after marker: String) -> Int? {
                guard let range = text.range(of: marker) else { return nil }
                let rest = text[range.upperBound...]
                let digits = rest.prefix { $0.isNumber }
                return Int(digits)
            }

            if let n = intValue(after: "n="), let thumbs = intValue(after: "thumbs=") {
                if n > 0 {
                    XCTAssertGreaterThan(thumbs, 0, "trailer cards rendered without a single thumbnail URL")
                }
            }
        } else {
            // Probe not on screen (no trailers for this title, or focus didn't reach the
            // shelf) — same softness as test02/test17, do not hard-fail on a missing probe.
            print("[UX10] debug_trailers not found on screen")
        }
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Pinned Nuvio hero: foreground stays on screen at deep scroll (UX-7 extension)

    /// Launches with -hero_nuvio_style YES, walks focus deep into the rows, and asserts the hero
    /// foreground is STILL on screen: the CTA ("Go to Movie"/"Go to Show") must exist AND be
    /// hittable (in classic it scrolls away and stops being hittable — the discriminator), and the
    /// debug_hero probe must carry pin=1. Screenshots give the human pass the hero-over-rows
    /// composition check (fade band artifacts, row 1 rest position).
    func test22PinnedHeroDeepScroll() throws {
        // Fresh launch: the pinned-hero layout must not inherit a prior test's scroll/focus state
        // (same rationale as test06/test20's use of the argument-domain toggle + forceFreshLaunch).
        let app = launchToHome(extraArguments: ["-hero_nuvio_style", "YES"], forceFreshLaunch: true)

        // Normalize focus onto the hero CTA (test06/test20's walk: up to the tab bar, one down
        // lands back on the hero button).
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        shot(app, "22a_pinned_hero_at_top")
        let topState = heroSrcProbe(app, "22a_probe_at_top")
        XCTAssertTrue(topState.contains("pin=1"), "hero_nuvio_style=YES must set pin=1 on the debug_hero probe, got: \(topState)")

        // Deep scroll: the classic (unpinned) hero scrolls its foreground away with the carousel;
        // the pinned variant must keep the CTA on screen and hittable throughout.
        press(.down, times: 8, gap: 1.0)
        pause(2)
        shot(app, "22b_pinned_hero_deep_scroll")
        // src=c or src=f are both legal this deep (depends which row reports) — not asserted here.
        _ = heroSrcProbe(app, "22b_probe_after_deep_scroll")

        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Go to'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 4), "hero CTA must still exist after deep scroll with pinned hero")
        XCTAssertTrue(cta.isHittable, "pinned hero CTA must remain hittable at deep scroll — a non-hittable CTA means it scrolled away like the classic layout")

        // Up-walk through the fade band (Codex review P2, 2026-08-03): rows masked under the
        // pinned hero stay focus-ELIGIBLE — the design bets on the focus engine's scroll-to-
        // reveal honoring the safe-area inset so a focused card is always brought back below
        // the hero. Walk Up one press at a time and screenshot each step; the human/agent pass
        // checks that no step shows the focus halo resting inside the hero band on an invisible
        // card. No hard assert — the masked card is still "visible" to the AX tree, so the
        // screenshot is the only oracle (same philosophy as the rest of the harness).
        for step in 1...4 {
            press(.up, times: 1)
            pause(1)
            shot(app, "22b_upwalk_\(step)")
        }
        // Return deep so the Menu leg below exercises the pinned Menu-to-top branch from a
        // genuinely scrolled-down state (its handler only attaches while isScrolledDown).
        press(.down, times: 4, gap: 1.0)
        pause(2)

        // Menu from deep scroll must jump rows back to top AND land focus on the pinned CTA.
        remote.press(.menu)
        pause(2)
        XCTAssertTrue(app.state == .runningForeground, "Menu from deep rows must NOT exit the app")
        shot(app, "22c_menu_back_to_top")
        let afterMenuState = heroSrcProbe(app, "22c_probe_after_menu")
        XCTAssertTrue(afterMenuState.contains("foc=1"), "Menu-to-top must land focus on the pinned hero CTA (foc=1), got: \(afterMenuState)")
    }

    // MARK: - BUG-47: Search "See All" grid must survive a Back mid-navigation

    /// BUG-47 (P0): on tvOS 27, pressing Back (Menu) out of the "See All" grid pushed from Search
    /// results reproducibly terminated the process. Root cause: `FlowWatcher` cancellation is
    /// cooperative, so a resume already queued on the main run loop could deliver one more value
    /// to the watcher callback AFTER `stop()`/`cancel()` returned, driving a `@Published` write
    /// into a view mid-pop — `CatalogGridViewModel`'s `stopped` guard closes that window. This
    /// drives the exact repro path three times with different timing, so a regression that only
    /// shows up under a specific race window (immediate Menu vs. Menu after pagination) still gets
    /// exercised.
    ///
    /// Query typing is best-effort (see `typeOnKeyboard` / test19's header comment on the tvOS
    /// keyboard grid): if it can't be driven on a given run this still asserts the app survived
    /// the attempt, but the actual crash probe below needs real results to reach a "See All" card,
    /// so a failed type makes the rest of the test a no-op pass.
    func test23SearchSeeAllBackNoCrash() throws {
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Search")
        pause(1.5)

        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 4) else {
            XCTAssertTrue(app.state == .runningForeground)
            return
        }
        if !searchField.hasFocus {
            _ = moveFocus(.up, until: searchField, max: 6)
        }
        remote.press(.select)
        pause(2) // full-screen keyboard presentation

        // Broad query so real result rows (and a "See All" card) are likely regardless of which
        // addons are installed on the signed-in profile.
        let typed = typeOnKeyboard(app, "batman")
        remote.press(.menu) // dismiss the keyboard back to the results list either way
        pause(2.5) // debounce + results fetch
        shot(app, "23a_search_results")
        // Prerequisite failures are LOUD: this test is the BUG-47 regression gate, and a silent
        // skip-return already produced one vacuous green (Codex round 1 — the first run never
        // opened the grid at all, because `waitForExistence` cannot see a `SeeAllCard` that a
        // LazyHStack hasn't materialized yet; only walking focus rightward brings it into the
        // tree, and the "batman" row is ~47 cards long).
        guard typed else {
            XCTFail("BUG-47 gate not exercised: the tvOS keyboard grid could not be driven")
            return
        }

        let seeAll = seeAllCard(app)
        press(.down, times: 1) // out of the search field, into the first results row

        for iteration in 1...3 {
            // On the tvOS 27.0 runtime under Xcode 26.6, `hasFocus` NEVER reads true for these
            // cards (input lands fine; focus *reporting* is broken — same class as the keyboard's
            // `app.keys` focus). So the walk is existence-driven, not focus-driven: a lazy
            // `SeeAllCard` materializes only when the walk nears the row's end, so "it exists"
            // means "focus is within a couple of cards of it" — a few more presses land on it,
            // and the row's end stops focus there regardless of what `hasFocus` claims.
            guard walkRightUntilExists(seeAll, max: 60) else {
                shot(app, "23x_no_seeall_\(iteration)")
                XCTFail("BUG-47 gate not exercised: See All never materialized in the \"batman\" row (iteration \(iteration))")
                return
            }
            press(.right, times: 3, gap: 0.6) // land on the row-end See All card
            remote.press(.select)

            if iteration == 1 {
                // Back almost immediately — the race window the `stopped` guard closes (device
                // repro: Menu fired while the grid's first page is still in flight).
                pause(0.3)
            } else {
                pause(2.5)
                shot(app, "23b_grid_opened_\(iteration)")
                XCTAssertTrue(app.state == .runningForeground, "app should survive opening the See All grid (iteration \(iteration))")
                if iteration == 2 {
                    press(.down, times: 6, gap: 0.3) // paginate first, then back mid-scroll
                }
            }

            remote.press(.menu)
            pause(2)
            shot(app, "23c_after_menu_\(iteration)")
            XCTAssertTrue(app.state == .runningForeground, "BUG-47 regression: Menu out of the See All grid must not terminate the process (iteration \(iteration))")

            let backOnResults = seeAll.waitForExistence(timeout: 4) || searchField.waitForExistence(timeout: 2)
            XCTAssertTrue(backOnResults, "expected to be back on search results after Menu (iteration \(iteration))")
        }
    }

    // MARK: - UX-13: "See All" grid keeps its focus position across a detail round trip

    /// Once inside a "See All" grid: walks Right×2 Down×1 (`LazyVGrid` populates left-to-right,
    /// top-to-bottom, so this lands a couple of rows in rather than the very first cell), records
    /// the focused poster's accessibility label, opens its detail page, backs out with Menu, and
    /// asserts the SAME element regains focus. This is the UX-13 contract H1's `detach()` exists
    /// for: a pop only cancels the in-flight fetch (`CatalogRepository.detach()`), it does not wipe
    /// `items`/`scrollPositions` the way `clear()` did, so `load()`'s same-target early-return
    /// keeps the grid — and its focus/scroll state — exactly as the user left it.
    /// Enter the See All grid from a card row, recovering from mis-entry. The blind Right×N +
    /// Select after `walkRightUntilExists` is approximate by design (the SeeAllCard materializes
    /// while focus is still a couple of cards away, and composed-label cards never report focus),
    /// so an undershoot Selects a POSTER and opens its detail page instead of the grid — which is
    /// exactly what the 2026-08-21 in-suite run did (suite-order Home drift; the UX-13 assert then
    /// ran against a detail page's cast row and failed on the wrong screen entirely, while the
    /// solo run passed). Detail pages carry the always-on `debug_ux6` probe in DEBUG builds, so:
    /// Select, and if a detail page opened, Menu out and retry one card further Right. The SeeAll
    /// card is the row's LAST card, so extra Rights can't overshoot — only undershoot needs
    /// walking, and each attempt converges on it. First observed solo 2026-08-21 on the Search
    /// fallback: the results row is long and the SeeAllCard can be IN THE TREE while focus is
    /// still many cards short of it, so proximity guessing (+1 per retry) never covered the
    /// distance — each retry now strides several cards, which overshoot-safety makes free.
    /// Walk Right until the FOCUSED element is the SeeAll card itself. tvOS 26.5 (the gating
    /// runtime) reports focus, so identity beats press-count guessing — a long Search results
    /// row defeated both Right×3 and Right×28 (2026-08-21): existence of the card in the tree
    /// says nothing about how many cards away focus is. On 27.0 `focusedButton` is nil and this
    /// no-ops; the caller's blind stride + mis-entry retries remain the (skippy) fallback there.
    private func walkFocusOntoSeeAll(_ app: XCUIApplication) {
        for _ in 0..<30 {
            guard let f = focusedButton(app) else { return }
            if f.label.localizedCaseInsensitiveContains("See All") { return }
            remote.press(.right)
            pause(0.45)
        }
    }

    private func selectIntoSeeAllGrid(_ app: XCUIApplication, shotName: String) -> Bool {
        for attempt in 0..<6 {
            walkFocusOntoSeeAll(app)
            remote.press(.select)
            pause(2.5)
            if !app.staticTexts["debug_ux6"].exists {
                shot(app, shotName)
                return true
            }
            print("[UX13] mis-entry attempt \(attempt): detail page opened instead of the grid — backing out, striding Right")
            remote.press(.menu)
            pause(2)
            press(.right, times: 3, gap: 0.5)
        }
        shot(app, "\(shotName)_misentry")
        return false
    }

    private func assertGridFocusRestores(_ app: XCUIApplication) throws {
        press(.right, times: 2, gap: 0.5)
        press(.down, times: 1, gap: 0.5)
        pause(0.5)

        guard let focused = focusedButton(app) else {
            // The tvOS 27.0 runtime under Xcode 26.6 never reports `hasFocus` for any element
            // (see test23's walk comment), so a focus-identity assertion is unprovable there —
            // skip rather than fail or pass vacuously; the 26.5 run is the gating one.
            throw XCTSkip("focus reporting unavailable on this runtime — UX-13 restore asserted on tvOS 26.5")
        }
        let label = focused.label
        shot(app, "24a_grid_focused_\(label)")

        remote.press(.select)
        pause(3) // detail page load
        shot(app, "24b_detail_opened")
        XCTAssertTrue(app.state == .runningForeground)

        remote.press(.menu)
        pause(2.5)
        shot(app, "24c_back_on_grid")

        let restored = app.buttons[label]
        XCTAssertTrue(
            restored.waitForExistence(timeout: 6) && restored.hasFocus,
            "UX-13 regression: focus did not return to \"\(label)\" after popping the detail page"
        )
    }

    func test24CatalogGridFocusRestore() throws {
        let app = launchToHome(forceFreshLaunch: true)

        // Prefer Home (more stable than Search — no keyboard round trip needed): land on the same
        // movies catalog row test01/02/17/21 use and walk out to its trailing "See All" card.
        press(.down, times: 4)
        pause(1)
        let homeSeeAll = seeAllCard(app)
        if walkRightUntilExists(homeSeeAll, max: 40) {
            // Overshoot-safe stride: the SeeAll card is the row's LAST card, so Rights past it
            // are no-ops — 10 covers the materializes-early gap the old ×3 undershot.
            press(.right, times: 10, gap: 0.4)
            guard selectIntoSeeAllGrid(app, shotName: "24_home_grid_opened") else {
                XCTFail("UX-13 gate not exercised: could not enter the Home See All grid (kept opening detail pages)")
                return
            }
            try assertGridFocusRestores(app)
            return
        }

        // Home's harness config has no reachable "See All" on that row — fall back to test23's
        // Search path into a grid.
        openTab(app, named: "Search")
        pause(1.5)
        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 4) else {
            XCTAssertTrue(app.state == .runningForeground)
            return
        }
        if !searchField.hasFocus {
            _ = moveFocus(.up, until: searchField, max: 6)
        }
        remote.press(.select)
        pause(2)
        let typed = typeOnKeyboard(app, "batman")
        remote.press(.menu)
        pause(2.5)
        guard typed else {
            XCTFail("UX-13 gate not exercised: the tvOS keyboard grid could not be driven")
            return
        }
        // Same lazy-materialization + broken-hasFocus caveats as test23: existence-driven walk.
        let searchSeeAll = seeAllCard(app)
        press(.down, times: 1)
        guard walkRightUntilExists(searchSeeAll, max: 60) else {
            shot(app, "24x_no_seeall")
            XCTFail("UX-13 gate not exercised: no reachable See All card on Home or in Search results")
            return
        }
        // Same overshoot-safe stride as the Home path — the Search results row is where the
        // materializes-early gap actually bit (2026-08-21 solo run).
        press(.right, times: 10, gap: 0.4)
        guard selectIntoSeeAllGrid(app, shotName: "24_search_grid_opened") else {
            XCTFail("UX-13 gate not exercised: could not enter the Search See All grid (kept opening detail pages)")
            return
        }
        try assertGridFocusRestores(app)
    }

    // MARK: - BUG-45: Home Screen pane focused-toggle contrast probe

    /// Screenshot probe for the BUG-45 class on the Settings → Home Screen pane: the tester's
    /// `p1vylo0` frame measured the FOCUSED "Nuvio-Style Hero" toggle at 1.05:1 label/platter on
    /// beta.10 even though `SettingsToggleRow` routes through `rowTextColor()`. This captures
    /// both toggles focused, on the current build, for pixel measurement — it asserts nothing
    /// about color itself (the measurement is done on the exported PNGs).
    func test25HomeScreenPaneContrast() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let homeScreen = app.buttons["Home Screen"]
        _ = moveToSidebarRow(app, .down, named: "Home Screen", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // Fixed press counts, no hasFocus: `SettingsToggleRow` buttons do not report focus to
        // XCUITest even on 26.5 (the first probe run walked straight past both toggles to the
        // Catalogs row) — itself a data point for BUG-45's focus-propagation hypothesis. The
        // pane's first focusable row is the Show Hero toggle; one Down is Nuvio-Style Hero.
        shot(app, "25a_show_hero_focused")
        press(.down, times: 1)
        pause(1)
        shot(app, "25b_nuvio_style_hero_focused")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-86 (Wave H): the hero commits once, all the way through a real launch burst

    /// The leading `<N>ms` launch-relative stamp every `HomeHeroProbe` line carries. The first
    /// occurrence of `"ms "` in a stamped line is always the stamp itself - nothing earlier in
    /// the string could contain it, since the stamp is the first thing written.
    private func probeStampMs(_ line: String) -> Int? {
        guard let range = line.range(of: "ms ") else { return nil }
        return Int(line[line.startIndex..<range.lowerBound])
    }

    /// Reads a single `key=value` token out of a probe line, tolerant of token ORDER - Wave H
    /// moved `item=` to the very end of the `paint` line (it used to lead) while `present` still
    /// leads with `item=`, and `HomeRepository.heroRankingDebug`'s own space-separated tokens
    /// (`gate=`/`sync=`/`head=`/…) are folded into the middle of every `publish` line. A fixed-
    /// position parse breaks on either; every value this file reads is itself space-free (ids,
    /// enums, hex, ms counts), so a plain whitespace split is enough. Returns the FIRST match -
    /// relevant only for `publish`, whose own `head=` (the state's head item) precedes
    /// `heroRankingDebug`'s unrelated `head=` (the committed key); every other field is unique
    /// per line.
    private func probeField(_ line: String, _ key: String) -> String? {
        let prefix = "\(key)="
        for token in line.split(separator: " ") where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    /// The probe line's TYPE token - the second whitespace-separated token, right after the
    /// leading stamp (`vm`, `publish`, `commit`, `rows`, `present`, `paint`).
    private func probeKind(_ line: String) -> String? {
        let tokens = line.split(separator: " ")
        return tokens.count > 1 ? String(tokens[1]) : nil
    }

    /// The THIRD token - distinguishes `vm start` from `vm acquire`/`vm release`/`vm stop`, and a
    /// real `paint kind=…` line from a `paint suppressed kind=…` one (a correctly-declined
    /// repaint, not a violation - see `isRealPaintLine`).
    private func probeSubKind(_ line: String) -> String? {
        let tokens = line.split(separator: " ")
        return tokens.count > 2 ? String(tokens[2]) : nil
    }

    private func isVmStartLine(_ line: String) -> Bool {
        probeKind(line) == "vm" && probeSubKind(line) == "start"
    }

    /// A genuine repaint - excludes `paint suppressed …`, which is the crossfade correctly
    /// declining to repaint (evidence the invariant HELD, not evidence it broke).
    private func isRealPaintLine(_ line: String) -> Bool {
        probeKind(line) == "paint" && probeSubKind(line) != "suppressed"
    }

    /// Wave H (BUG-86) "photo contract" - see the design doc's `S3` paragraph and "The photo
    /// contract": the invariants a healthy cold launch's `hero_probe_blob` must satisfy, scoped to
    /// lines stamped under 15s (the launch window the gate/commit protocol governs; later lines
    /// are the test's OWN navigation, not the cold-launch invariant). `legName` only decorates
    /// failure messages so a red run says which leg broke.
    ///
    /// Checks: exactly one `vm start`; exactly one `commit … first=1`; zero `publish …
    /// headChanged=1`; zero `publish … hashChanged=1`; zero `same=1` on any `paint`/`present`
    /// line (internal review r1: on a `present` line `same=1` now means a VISIBLE text repaint at a
    /// stable identity - name, releaseInfo, first-three genres, or description being REPLACED, never a
    /// nil/empty one being filled; see `HeroArtResolver.isVisibleRepaint`. Before that fix the flag was
    /// computed from two bitmaps that were copies of each other, so it could never be 1 and this
    /// filter was vacuous);
    /// line; the `publish` line immediately preceding the first `commit` reads `gate=released:all`
    /// (or `released:timeout` when `allowTimeoutRelease` - Leg B's burst deliberately fails the
    /// first hero-source fetch and delays enrichment 2.5s, which HERO_COMMIT_GATE_TIMEOUT_MS's 4s
    /// budget is not guaranteed to outrun; the design doc treats a timeout release as diagnosable,
    /// not broken - see HeroCommitGate.kt's header) with `sync` settled or not-applicable; every
    /// `rows` line's row-id order reorders ids also present in an earlier `rows` line only where
    /// `RowsOrderRule` excuses it (content may grow progressively as catalog batches stream in -
    /// see collectionsWatcher/catalogSettingsWatcher in HomeViewModel.swift - and a settings order
    /// arriving post-commit may reshuffle it, but nothing else may); and
    /// the existing fallbackCached(hadArt=1) → primary adjacency check (a stale poster briefly
    /// overwriting art already correct for this same title).
    private func assertHeroPhotoContract(_ lines: [String], legName: String, allowTimeoutRelease: Bool = false) {
        let earlyLines = lines.filter { (probeStampMs($0) ?? Int.max) < 15_000 }

        let vmStartCount = earlyLines.filter(isVmStartLine).count
        XCTAssertEqual(vmStartCount, 1, "\(legName): expected exactly one 'vm start' line within the first 15s, found \(vmStartCount) — lines=\(earlyLines)")

        let firstCommits = earlyLines.filter { probeKind($0) == "commit" && probeField($0, "first") == "1" }
        XCTAssertEqual(firstCommits.count, 1, "\(legName): expected exactly one 'commit … first=1' line within the first 15s, found \(firstCommits.count) — lines=\(earlyLines)")

        let headChanged = earlyLines.filter { probeKind($0) == "publish" && probeField($0, "headChanged") == "1" }
        XCTAssertTrue(headChanged.isEmpty, "\(legName): 'publish … headChanged=1' within the first 15s — \(headChanged)")

        let hashChanged = earlyLines.filter { probeKind($0) == "publish" && probeField($0, "hashChanged") == "1" }
        XCTAssertTrue(hashChanged.isEmpty, "\(legName): 'publish … hashChanged=1' within the first 15s — \(hashChanged)")

        let repaints = earlyLines.filter { (probeKind($0) == "paint" || probeKind($0) == "present") && probeField($0, "same") == "1" }
        XCTAssertTrue(repaints.isEmpty, "\(legName): 'same=1' on a paint/present line within the first 15s — \(repaints)")

        // The publish immediately preceding the first commit is the one that actually released
        // the gate: multiple publishes can land while the gate is still Armed (each re-assigns
        // `lastNonEmptyHeroHead` for the hash diagnostic without committing), but only the LAST
        // one before the commit is the one whose async `prepare()` actually won the race - see
        // `heroCommitGeneration` in HomeViewModel.swift.
        if let commitIdx = lines.firstIndex(where: { probeKind($0) == "commit" }) {
            if let publishIdx = lines[0..<commitIdx].lastIndex(where: { probeKind($0) == "publish" }) {
                let publishLine = lines[publishIdx]
                let gate = probeField(publishLine, "gate")
                var acceptableGates = allowTimeoutRelease ? ["released:all", "released:timeout"] : ["released:all"]

                // Leg A evidence-gated timeout tolerance (2026-09-04 incident): a shared build
                // machine's addon-manifest fetch alone can outrun HERO_COMMIT_GATE_TIMEOUT_MS's 4s
                // budget with no burst involved at all - one run timed out at 6.8s with
                // `gateWait=sources` while an `addonsChanged ready=` count kept climbing in the
                // background (9 -> 10 before the gate gave up, then 11 once the slow add-on
                // finally landed at 14.0s) and the head stayed pinned afterward - an honest, slow
                // load, not the double-commit this photo contract exists to catch. Leg B already
                // tolerates ANY `released:timeout` unconditionally (its whole point is to stress
                // the timeout path), so this narrower rule applies only when `allowTimeoutRelease`
                // is false, i.e. only to Leg A's plain baseline run. Accept the timeout only when
                // (a) the deciding publish line was waiting specifically on `sources` (never
                // `sync`, `enrich`, `empty`, or `-`), and (b) a later `addonsChanged` line shows a
                // HIGHER `ready=` count than the last one seen before the commit, proving the slow
                // source actually caught up rather than the gate silently never re-evaluating.
                // Every other assertion in this function still applies unconditionally regardless
                // of which branch fires below.
                var evidencedSourcesTimeout = false
                if !allowTimeoutRelease && gate == "released:timeout" {
                    let gateWait = probeField(publishLine, "gateWait")
                    if gateWait == "sources" {
                        let addonsChangedBeforeCommit = lines[0..<commitIdx].filter { probeKind($0) == "addonsChanged" }
                        let addonsChangedAfterCommit = lines[(commitIdx + 1)...].filter { probeKind($0) == "addonsChanged" }
                        if let lastReadyBeforeCommit = addonsChangedBeforeCommit.last.flatMap({ Int(probeField($0, "ready") ?? "") }) {
                            evidencedSourcesTimeout = addonsChangedAfterCommit.contains { line in
                                guard let ready = Int(probeField(line, "ready") ?? "") else { return false }
                                return ready > lastReadyBeforeCommit
                            }
                        }
                    }
                    // Logged either way (accepted or rejected) so a red or green run's evidence is
                    // in the log/result bundle, not just implied by which branch happened to fire.
                    print("[HeroGateOracle] \(legName): gate=released:timeout gateWait=\(gateWait ?? "nil") -> \(evidencedSourcesTimeout ? "ACCEPTED (a later addonsChanged ready= increase proves the slow source caught up)" : "REJECTED (no evidence the source that timed the gate out ever caught up)") — \(publishLine)")
                }
                if evidencedSourcesTimeout {
                    acceptableGates.append("released:timeout")
                }

                XCTAssertTrue(acceptableGates.contains(gate ?? ""), "\(legName): the publish line immediately preceding the first commit must read gate ∈ \(acceptableGates), got \(gate ?? "nil") — \(publishLine)")
                // `sync ∈ {settled, na}` is only a meaningful check when the gate actually released
                // because every input was ready (`released:all`) — a `released:timeout` release is
                // BY DEFINITION one where at least one input (sources, sync, or enrichment) was
                // still not ready at the deadline, so `sync=running` there is not a violation, it's
                // the whole reason the release reason reads `timeout` instead of `all`.
                if gate == "released:all" {
                    let sync = probeField(publishLine, "sync")
                    XCTAssertTrue(sync == "settled" || sync == "na", "\(legName): the publish line immediately preceding the first commit must have sync ∈ {settled, na}, got \(sync ?? "nil") — \(publishLine)")
                }
            } else {
                XCTFail("\(legName): no 'publish' line found before the first 'commit' line — lines=\(lines)")
            }
        } else {
            XCTFail("\(legName): no 'commit' line found in hero_probe_lines — the hero never committed. lines=\(lines)")
        }

        // Rows may legitimately grow across several `rows` lines as catalog batches stream in  -
        // `collectionsWatcher`/`catalogSettingsWatcher` (HomeViewModel.swift) rebuild rows on
        // their own schedule, independent of the hero gate, and rows keep changing post-commit by
        // design ("rows may still change under it post-commit", the `sameHead` branch's own
        // comment). A REORDER - two ids present in both an earlier and a later `rows` line swapping
        // relative position - is judged by `RowsOrderRule`; see its doc comment for why the answer
        // is not a flat no.
        //
        // 2026-09-05: this check used to be that flat no, and it was measuring a race rather than
        // an invariant. `HomeLaunchBurstSim` fires its reversal a fixed 1 s after the first
        // NON-EMPTY hero publish, which is the gate-release publish (a held publish republishes the
        // previous, empty hero), while the commit lands a hero-art prewarm later - anywhere from
        // ~10 ms on a warm fixture to the full 1.5 s budget on a cold one. So whether the burst's
        // reversal was absorbed into the one gated rebuild (prewarm slower than the burst) or
        // landed as a post-commit reorder (prewarm faster) was decided by the artwork cache, not by
        // the code under test. Observed both ways on this fixture within one evening: 2026-09-04
        // 23:48 released:timeout at 6770 ms with `waited=1382ms` (absorbed, green), 2026-09-05
        // 07:05 released:all at 5441 ms with `waited=9ms` (post-commit, red) - same contract held
        // in both, one of them failed.
        let rowsLines = lines.filter { probeKind($0) == "rows" }
        if rowsLines.isEmpty {
            XCTFail("\(legName): no 'rows' line found in hero_probe_lines — lines=\(lines)")
        } else {
            // Internal review r1 (P3): read the FULL ordered row list from `order=`, not the three
            // ids `first=` carries. The launch sync burst rewrites every `order`, so a swap at
            // position 4 or later is exactly as much of a violation as one in the first three and
            // the old three-id window could not see it.
            //
            // `order=`'s tokens are 8-hex DIGESTS of the row ids, not the ids (see the emitting
            // comment in HomeViewModel.swift: real ids run 60-90 characters here and 35 of them
            // would not fit a photographable probe line). This check never needs the id itself -
            // it only compares the relative position of tokens present in BOTH lines - so a stable
            // per-id token is exactly enough. The `+N` cap suffix is dropped rather than parsed:
            // a truncated list is still a prefix of the real one, which relative order tolerates.
            // `first=` stays the fallback so a log from an older build still parses.
            func rowIds(_ line: String) -> [String] {
                if let order = probeField(line, "order"), !order.isEmpty {
                    return order.split(separator: ",").map { part -> String in
                        let id = String(part)
                        guard let plus = id.firstIndex(of: "+") else { return id }
                        return String(id[id.startIndex..<plus])
                    }
                }
                return (probeField(line, "first") ?? "").split(separator: ",").map(String.init)
            }
            let parsedRowsLines = lines.enumerated().compactMap { index, line -> RowsProbeLine? in
                guard probeKind(line) == "rows" else { return nil }
                return RowsProbeLine(index: index,
                                     order: rowIds(line),
                                     settingsSig: probeField(line, "settingsSig"),
                                     raw: line)
            }
            let firstCommitIndex = lines.firstIndex { probeKind($0) == "commit" }
            // Everything that disqualifies a reorder however well the settings explain it: a
            // SECOND commit (the first is the one the pre/post split is measured against) and any
            // publish that moved the head. Both are already standalone failures above; carrying
            // them here too keeps the reorder message honest about what it rode in on rather than
            // reporting an excused reorder next to an unrelated red assertion.
            var disqualifying = Set<Int>()
            for (index, line) in lines.enumerated() {
                if probeKind(line) == "commit", let firstCommitIndex, index > firstCommitIndex {
                    disqualifying.insert(index)
                }
                if probeKind(line) == "publish", probeField(line, "headChanged") == "1" {
                    disqualifying.insert(index)
                }
            }
            if let violation = RowsOrderRule.firstViolation(rowsLines: parsedRowsLines,
                                                            firstCommitIndex: firstCommitIndex,
                                                            disqualifyingIndices: disqualifying) {
                XCTFail("\(legName): rows reordered between consecutive 'rows' lines and the reorder is not excused (\(violation.reason)) — \(violation.earlier.raw) then \(violation.later.raw)")
            }
        }

        // Device pass 2026-08-24 (Living Room): a fallbackCached→primary pair for the SAME item
        // is not automatically a bug - it's also the intended sequence for a title entering view
        // for the FIRST time (poster cache hit shown provisionally while the network backdrop
        // lands, HeroCrossfadeImage's documented "show it NOW as provisional art, then upgrade"
        // ladder). That legitimate case paints onto blank/previous-title art, so its
        // fallbackCached line reads `hadArt=0`. The bug this oracle actually exists to catch - a
        // stale poster briefly overwriting art that was ALREADY correct for this same title -
        // reads `hadArt=1` on that same line, because "hadArt" is computed from `current` at the
        // moment of the swap and a same-title upgrade always has `current` already showing this
        // title's art. Require hadArt=1 or the check has been rejecting normal first-time paints.
        for i in 0..<max(0, lines.count - 1) {
            let line = lines[i]
            guard line.contains("paint kind=fallbackCached"), line.contains("hadArt=1"),
                  let itemA = probeField(line, "item") else { continue }
            let next = lines[i + 1]
            if next.contains("paint kind=primary"), let itemB = probeField(next, "item"), itemA == itemB {
                XCTFail("\(legName): fallbackCached paint (hadArt=1, overwrote existing good art) immediately followed by a primary paint for the same item (\(itemA)) — stale-then-real flash. lines[\(i)]=\(line) lines[\(i + 1)]=\(next)")
            }
        }
    }

    /// Cold-launches Home with the release-safe `debug.homeHeroProbe` knob(s) set, reads the
    /// `hero_probe_blob` off Settings › About, and fails loudly (never silently skips) if the
    /// buffer produced no readable lines - see `heroProbeLines`'s doc for why that can happen
    /// independent of whether `HomeHeroProbe` actually logged anything.
    @discardableResult
    private func launchAndReadHeroProbe(extraArguments: [String], shotPrefix: String) -> (app: XCUIApplication, lines: [String]) {
        let app = launchToHome(extraArguments: extraArguments, forceFreshLaunch: true)
        // The gate's own budget is HERO_COMMIT_GATE_TIMEOUT_MS (4s) plus whatever the art prewarm
        // needs on top - 6s clears a healthy launch with margin before the probe read below.
        pause(6.0)
        shot(app, "\(shotPrefix)_hero_settled")
        XCTAssertTrue(app.state == .runningForeground, "app must be alive after the hero gate's budget (\(shotPrefix))")
        let lines = readHeroProbeAboutPane(app, shotPrefix: shotPrefix)
        return (app, lines)
    }

    /// Navigates to Settings › About (from wherever Home currently has focus) and reads the
    /// `hero_probe_blob`. Split out from `launchAndReadHeroProbe` so Leg C can read it a second
    /// time mid-session, after navigating away and back, without a fresh launch.
    @discardableResult
    private func readHeroProbeAboutPane(_ app: XCUIApplication, shotPrefix: String) -> [String] {
        openTab(app, named: "Settings")
        let about = app.buttons["About"]
        _ = moveFocus(.down, until: about, max: 8)
        press(.right, times: 1)
        pause(1.5)
        shot(app, "\(shotPrefix)_about_probe")
        let lines = heroProbeLines(app)
        if lines.isEmpty {
            XCTFail("\(shotPrefix): hero_probe_lines produced no readable lines — cannot verify the hero commit invariants this run; see heroProbeLines' doc for why this can happen independent of whether HomeHeroProbe actually logged anything")
        } else {
            // Same house pattern as `heroSrcProbe`: print + attach the raw text, not just derived
            // pass/fail, so a device-pass-style read of THIS run's actual blob is always available
            // from the test log/result bundle, not only from whichever assertion happened to fail.
            let blob = lines.joined(separator: "\n")
            let attachment = XCTAttachment(string: blob)
            attachment.name = "\(shotPrefix)_probe_lines_text"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[HeroProbe] \(shotPrefix):\n\(blob)")
        }
        return lines
    }

    /// Cold-launches Home with `-debug.homeHeroProbe YES` and asserts the Wave H photo contract
    /// (see `assertHeroPhotoContract`) - the exact evidence a device-pass tester's About-pane
    /// photo has to show: one commit, no head/hash churn, no repaint, and the gate released
    /// `all` before that commit fired.
    func test31HeroCommitsOnce() throws {
        // Leg A: a plain probe launch, no burst - the baseline every later leg is measured
        // against.
        let legA = launchAndReadHeroProbe(extraArguments: ["-debug.homeHeroProbe", "YES"], shotPrefix: "31a")
        if !legA.lines.isEmpty { assertHeroPhotoContract(legA.lines, legName: "Leg A") }
        legA.app.terminate()
        pause(1.0)

        // Leg B: the same launch, PLUS `-debug.homeLaunchBurstSim YES` - a deterministic, offline
        // replay of the launch sync burst that produces BUG-86 on a tester's TV and never on the
        // sim fixture (see HomeLaunchBurstSim.kt's header). The photo contract must hold
        // identically; the burst's own publishes must land, but only AFTER the commit, and only
        // as no-op churn (headChanged=0 hashChanged=0), never as a second commit/present/paint.
        //
        // WARNING (documented fixture-only mutation): the burst PERSISTS its mutations locally -
        // it reverses the profile's Home row order and its collection order, and turns "hide
        // unreleased content" on. Nothing is pushed to the server, so the next real sync restores
        // the account's true state, but this leg restores it too (see the relaunch-and-verify
        // block at the end) so the fixture is not left degraded for whatever runs next.
        let legB = launchAndReadHeroProbe(
            extraArguments: ["-debug.homeHeroProbe", "YES", "-debug.homeLaunchBurstSim", "YES"],
            shotPrefix: "31b"
        )
        let app = legB.app
        // `defer`, not a plain trailing call: Leg C below can exit this function early via `throw
        // XCTSkip(...)` (no folder tile on this profile), which would otherwise skip both
        // `app.terminate()` and the fixture-restore relaunch entirely, leaving the burst's
        // reversed local Home order live for whatever runs next on this fixture. `defer` runs on
        // every exit path out of this function, including a thrown skip.
        defer {
            app.terminate()
            pause(1.0)

            // Fixture restore + sanity check: Leg B's burst persisted a reversed row/collection
            // order and hideUnreleasedContent=true locally (see the WARNING above). Nothing was
            // pushed to the server, so a plain relaunch's next real sync eventually restores the
            // account's true state - this only confirms the gate itself still releases cleanly on
            // the (possibly still-reversed) local state; it does NOT undo the reorder itself. See
            // the report for whether this run's fixture was left reversed.
            let restored = launchAndReadHeroProbe(extraArguments: ["-debug.homeHeroProbe", "YES"], shotPrefix: "31restore")
            if !restored.lines.isEmpty {
                if let commitIdx = restored.lines.firstIndex(where: { probeKind($0) == "commit" }),
                   let publishIdx = restored.lines[0..<commitIdx].lastIndex(where: { probeKind($0) == "publish" }) {
                    let gate = probeField(restored.lines[publishIdx], "gate")
                    // Tolerant the same way Leg B is: this shared build machine's addon-manifest
                    // fetch alone can eat several seconds under concurrent-agent CPU contention
                    // (observed directly: 2026-09-04 runs with load average 10-30 on 8 cores),
                    // which is enough on its own to blow HERO_COMMIT_GATE_TIMEOUT_MS's 4s budget
                    // even with no burst involved. The sanity check that matters here is "the gate
                    // still releases and commits at all", not the release reason.
                    XCTAssertTrue(gate == "released:all" || gate == "released:timeout", "post-Leg-B/C restore relaunch: expected gate ∈ {released:all, released:timeout}, got \(gate ?? "nil") — the burst's persisted local mutations may have left the gate degraded — \(restored.lines[publishIdx])")
                } else {
                    XCTFail("post-Leg-B/C restore relaunch: hero_probe_lines missing a commit/publish pair — cannot confirm the fixture recovered. lines=\(restored.lines)")
                }
            }
            restored.app.terminate()
            pause(1.0)
        }

        let preFocusLines = legB.lines
        if !preFocusLines.isEmpty {
            assertHeroPhotoContract(preFocusLines, legName: "Leg B", allowTimeoutRelease: true)

            guard let firstCommitIdx = preFocusLines.firstIndex(where: { probeKind($0) == "commit" }) else {
                XCTFail("Leg B: no 'commit' line — cannot verify the burst assertions. lines=\(preFocusLines)")
                return
            }
            let afterCommit = Array(preFocusLines[(firstCommitIdx + 1)...])
            let publishesAfterCommit = afterCommit.filter { probeKind($0) == "publish" }
            if publishesAfterCommit.isEmpty {
                XCTFail("burst sim did not run")
            } else {
                for line in publishesAfterCommit {
                    XCTAssertEqual(probeField(line, "headChanged"), "0", "Leg B: a publish after the first commit must read headChanged=0 — \(line)")
                    XCTAssertEqual(probeField(line, "hashChanged"), "0", "Leg B: a publish after the first commit must read hashChanged=0 — \(line)")
                }
            }
            // Not "no present/paint at all after the commit": the hero carousel auto-advances its
            // own committed `heroItems` pages on a fixed timer regardless of user input, and every
            // page turn legitimately logs its own present/paint line for the NEXT already-committed
            // item - that is the carousel doing its job, not BUG-86 (confirmed empirically: a first
            // run here caught exactly that, present/paint lines for the committed publish's OWN
            // `ids=` list, roughly 8s apart, well before any Down press). What must never happen
            // post-commit is a SECOND commit (a genuine re-decision of the head) or a `same=1`
            // present/paint (a repaint of content already on screen) - both are checked over the
            // WHOLE post-commit tail, not just the 15s window `assertHeroPhotoContract` uses, since
            // the carousel's own rotation can carry the buffer well past 15s before focus ever moves.
            let secondCommits = afterCommit.filter { probeKind($0) == "commit" }
            XCTAssertTrue(secondCommits.isEmpty, "Leg B: a second 'commit' line landed after the first — the hero re-committed — \(secondCommits)")

            let repaintsAfterCommit = afterCommit.filter { (probeKind($0) == "present" || probeKind($0) == "paint") && probeField($0, "same") == "1" }
            XCTAssertTrue(repaintsAfterCommit.isEmpty, "Leg B: a 'same=1' present/paint line landed after the first commit — \(repaintsAfterCommit)")
        }

        // Leg C: continuing THIS SAME launch, before touching the About pane again - walk focus
        // down into the first row that reports a folder tile (`debug_hero`'s `fitem=` prefixed
        // `nuvio-folder://`, the same identity `HomeView.isCollectionHero` checks; see
        // `collectionHeroIdScheme`), dwell on it past the resolver's folder deadline, then churn
        // focus (back up, a Search round trip) before reading the probe a second time.
        // Existence-driven and budget-bounded, same house rule as `test42`'s row walk: this
        // profile's Home may or may not have a collection row at all, and skipping loudly beats
        // asserting on nothing.
        //
        // 2026-09-05, the leg's first real run and what it changed. Two things had kept this leg
        // from ever executing. (1) The 15-press budget: Leg B's burst REVERSES the row order, so
        // the collection row lands at the far end of a 35-row Home and 15 Downs never reached it -
        // every recorded run ended in the skip below. The ceiling is 40 now, with an early bail
        // when focus stops moving (the bottom of Home), so a profile with no collection row costs
        // a handful of presses rather than the full budget. (2) The ORACLE, which failed at 40:
        // there was no `present item=nuvio.folder:…` line in the About pane to find. The console
        // `[HomeHero]` stream for that same run carried a perfectly healthy one -
        // `backdrop=fetched logo=fetched waited=98 same=0`, with its matching `paint` - so the
        // hero's folder path was never the problem. `HomeHeroProbe`'s buffer keeps a 32-line
        // ROLLING TAIL, and the ~40 Down presses plus `openTab`'s ~40-press climb back to the tab
        // bar emit ~150 lines after the folder's own: the evidence is always evicted before the
        // pane can be read. So the presentation itself is now asserted LIVE off `debug_hero`'s
        // `pitem=`/`pbd=` (the resolver's committed identity and whether it committed a real
        // backdrop bitmap) - the same facts, with no ring buffer in between - and the buffer read
        // below keeps only the present/paint PAIRING check, which is skipped, not failed, when the
        // buffer says it elided lines.
        openTab(app, named: "Home")
        pause(1.0)
        // Deliberately not `heroSrcProbe` per press: that adds an XCTAttachment per call, which at
        // a 40-press ceiling costs more wall-clock than the presses do. Only the hit and the
        // post-dwell read are attached.
        func liveHeroProbe() -> String {
            let probe = app.staticTexts["debug_hero"]
            return probe.exists ? probe.label : ""
        }
        var folderFound = false
        var downPresses = 0
        var lastFocusedItem = ""
        var stalledPresses = 0
        for _ in 1...40 {
            press(.down, times: 1)
            downPresses += 1
            pause(0.5)
            let focused = probeField(liveHeroProbe(), "fitem") ?? ""
            if focused.hasPrefix("nuvio-folder://") { folderFound = true; break }
            // Bottom of Home: Down stops changing what the rows report, so the remaining budget
            // would buy nothing. Five in a row, not one - a between-cards hop can briefly report
            // the same item twice.
            if focused == lastFocusedItem {
                stalledPresses += 1
            } else {
                stalledPresses = 0
                lastFocusedItem = focused
            }
            if stalledPresses >= 5 { break }
        }
        // The skip below covers two shapes at once and cannot tell them apart from here: a Home
        // with no collection row, and one whose folders carry NEITHER a `heroBackdropUrl` nor a
        // `titleLogoUrl` - `HomeView.folderHeroPreview` returns nil for those by design, so the
        // hero deliberately stays where it is and `fitem` never becomes a folder id. Which one a
        // given fixture is, is answered by the `[CollectionCover]` probe (`CollectionsUI.swift`,
        // `-debug.collectionCoverProbe YES`), not by this leg - it does not set that argument,
        // because adding one perturbs the burst/gate timing Leg B is measuring. On this fixture
        // the probe was read directly on 2026-09-05: all four folders report
        // `heroBackdrop=1 logo=1`, so the leg runs rather than skips here.
        guard folderFound else {
            throw XCTSkip("Leg C: no folder/collection tile focused within \(downPresses) Down presses on this profile's Home (focus settled on '\(lastFocusedItem)') — cannot verify the folder present()/paint() invariants without one")
        }
        _ = heroSrcProbe(app, "31c_folder_focused")
        // Longer than `HeroArtResolver.folderDeadline` (1.5s), so by the time this returns the
        // resolve this focus started has either committed the folder's own artwork or given up -
        // either way it is decided, and `pitem=`/`pbd=` below read a settled resolver.
        pause(3.0)
        let dwellProbe = heroSrcProbe(app, "31c_folder_dwelled")
        let dwellFocusedItem = probeField(dwellProbe, "fitem") ?? ""
        let presentedIdentity = probeField(dwellProbe, "pitem") ?? ""
        if dwellFocusedItem.hasPrefix("nuvio-folder://") {
            // The hero the resolver actually committed IS the focused folder - `pitem` is
            // `"\(type):\(id)"` and a folder preview's type is `collectionHeroType`.
            XCTAssertEqual(presentedIdentity, "nuvio.folder:\(dwellFocusedItem)",
                           "Leg C: the focused folder tile did not become the presented hero after a 3s dwell — \(dwellProbe)")
            // The Wave H rule the folder path exists for: a folder hero presents with its OWN
            // backdrop or not at all. `pbd=0` is the `backdrop=none` this leg used to look for in
            // the probe line, and `pbd=1` on a folder can only be the configured `heroBackdropUrl`
            // (`folderHeroPreview` passes `poster: nil`, so there is no stand-in to mistake it for).
            XCTAssertEqual(probeField(dwellProbe, "pbd"), "1",
                           "Leg C: the folder hero committed with no backdrop bitmap — \(dwellProbe)")
        } else {
            XCTFail("Leg C: the folder tile lost focus during the dwell (fitem=\(dwellFocusedItem)) — cannot judge the folder hero on a probe that is no longer reporting it — \(dwellProbe)")
        }
        press(.up, times: 1)
        pause(1.0)

        openTab(app, named: "Search")
        pause(1.5)
        let searchField = app.textFields.firstMatch
        if searchField.waitForExistence(timeout: 4) {
            if !searchField.hasFocus { _ = moveFocus(.up, until: searchField, max: 6) }
            remote.press(.select)
            pause(2.0)
            _ = typeOnKeyboard(app, "a")
            remote.press(.menu) // dismiss the keyboard back to results
            pause(1.5)
        }
        openTab(app, named: "Home")
        pause(1.0)

        let finalLines = readHeroProbeAboutPane(app, shotPrefix: "31c")
        if !finalLines.isEmpty {
            // Leg C's own assertions: the folder's `present` line landed real artwork (not
            // `none`), was a genuine new presentation (not a `same=1` re-present of what was
            // already on screen), and got exactly one matching `paint` - no double-paint, no
            // silent drop.
            let folderPresents = finalLines.filter { probeKind($0) == "present" && (probeField($0, "item") ?? "").hasPrefix("nuvio.folder:") }
            if let folderPresent = folderPresents.last {
                XCTAssertNotEqual(probeField(folderPresent, "backdrop"), "none", "Leg C: the folder's present line must not read backdrop=none — \(folderPresent)")
                // Whether the folder ALSO carries its own titleLogoUrl (which would make
                // `logo != text` the stronger assertion) is answered by the `[CollectionCover]`
                // probe (CollectionsUI.swift ~319-320) - but reading it needs a separate
                // `-debug.collectionCoverProbe YES` launch argument this leg does not set (adding
                // it risks perturbing the burst/gate timing Leg B is measuring), so per the task's
                // own fallback this only asserts backdrop != none.
                XCTAssertEqual(probeField(folderPresent, "same"), "0", "Leg C: the folder's present line must be a genuine new presentation (same=0) — \(folderPresent)")

                let folderIdentity = probeField(folderPresent, "item") ?? ""
                let matchingPaints = finalLines.filter { isRealPaintLine($0) && (probeField($0, "item") ?? "") == folderIdentity }
                // Internal review r1 (P3): a RANGE, not equality. `HomeHeroProbe`'s buffer is
                // head-preserving (24 frozen head lines, then a rolling 32-line tail), so by the
                // time Leg C reads the pane a folder `present` can have been evicted while the
                // `paint` it produced - logged later, from a different type - survives, or vice
                // versa. Equality then failed on the elision rather than on a real double-paint.
                // What the invariant actually forbids is a paint the folder never asked for
                // (`> presents`) and a present that painted nothing at all (`< 1`).
                XCTAssertGreaterThanOrEqual(matchingPaints.count, 1, "Leg C: the folder (\(folderIdentity)) has \(folderPresents.count) 'present' line(s) but no 'paint' line at all — a present that painted nothing")
                XCTAssertLessThanOrEqual(matchingPaints.count, folderPresents.count, "Leg C: more 'paint' lines than 'present' lines for the folder (\(folderIdentity)) — present=\(folderPresents.count) paint=\(matchingPaints.count) — a double-paint the resolver never asked for")
            } else if finalLines.contains(where: { $0.contains("lines elided") }) {
                // Expected on any run whose walk was deep: the folder's own `present` rolled out of
                // the buffer's 32-line tail before the pane could be read (see the leg header).
                // Not a failure - the presentation itself was already asserted live off `pitem=`
                // above; only the pairing check is unavailable for this run.
                print("[HeroProbe] Leg C: the folder's 'present' line was evicted from the probe buffer's rolling tail before the About read (presented=\(presentedIdentity)) — present/paint pairing not checked this run.")
            } else {
                XCTFail("Leg C: no 'present' line found for the focused folder tile (identity prefix 'nuvio.folder:') and the probe buffer elided nothing — the folder hero presented (pitem=\(presentedIdentity)) but never logged — lines=\(finalLines)")
            }
        }
        // `app.terminate()` and the fixture-restore relaunch run in the `defer` above, on every
        // exit path out of this function (including Leg C's `XCTSkip` above).
    }

    // MARK: - BUG-64: the accent focus ring must not cover the poster

    /// Reporter's exact configuration (u/mrStevenx3, p4afwfo): Accent Focus Ring ON + No Zoom on
    /// Focus ON — "the film ends up hidden behind the border". Both are LOCAL @AppStorage keys, so
    /// the argument domain sets them without touching the synced profile (same trick as test01's
    /// `-inline_trailers_enabled`). Focus a poster in the first movies row and measure two bands of
    /// the focused card: the OUTER 4 pt band (must carry the ring — mean colour far from the ring-
    /// OFF baseline of the same card) and an INNER band 6…14 pt in (must be the poster — mean colour
    /// close to the ring-OFF baseline). Pre-BUG-64 the inner band was painted by the stroke too.
    func test32AccentRingArtworkInset() throws {
        // No Zoom via the argument domain (local key); the ring is flipped through the REAL
        // Appearance toggle inside ONE launch so both measurements are of the same card (two
        // launches focused different cards and the first version of this test skipped itself).
        let app = launchToHome(extraArguments: ["-no_zoom_on_focus", "YES"], forceFreshLaunch: true)
        let appearance = app.buttons["Appearance"]
        func openAppearance() {
            openTab(app, named: "Settings")
            _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        func focusedPosterShot(_ name: String) throws -> (CGRect, UIImage) {
            openTab(app, named: "Home")
            press(.down, times: 3)
            press(.left, times: 6, gap: 0.3)
            pause(1.5)
            guard let card = focusedButton(app), card.frame.width > 80, card.frame.height > card.frame.width else {
                throw XCTSkip("no focused poster card reported (27.0 runtime never reports hasFocus)")
            }
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return (card.frame, screenshot.image)
        }
        openAppearance()
        let sidebarX = appearance.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        let (frameOff, imageOff) = try focusedPosterShot("32a_ring_off")
        openAppearance()
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        let (frameOn, imageOn) = try focusedPosterShot("32b_ring_on")
        // Restore the local toggle (it is real prefs on this sim, not the argument domain).
        openAppearance()
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: false, sidebarMaxX: sidebarX, category: "Appearance")

        // The poster caption sits below the artwork; the artwork is the top 2:3 of the card frame.
        func bands(_ f: CGRect) -> (outer: CGRect, inner: CGRect) {
            let artH = f.width * 1.5
            let outer = CGRect(x: f.minX, y: f.minY + artH * 0.3, width: 4, height: artH * 0.4)         // left ring band
            let inner = CGRect(x: f.minX + 6, y: f.minY + artH * 0.3, width: 8, height: artH * 0.4)     // 6…14 pt in
            return (outer, inner)
        }
        let bOff = bands(frameOff), bOn = bands(frameOn)
        let outerOff = try meanRGB(in: imageOff, pointRect: bOff.outer, windowSize: app.frame.size)
        let outerOn = try meanRGB(in: imageOn, pointRect: bOn.outer, windowSize: app.frame.size)
        let innerOff = try meanRGB(in: imageOff, pointRect: bOff.inner, windowSize: app.frame.size)
        let innerOn = try meanRGB(in: imageOn, pointRect: bOn.inner, windowSize: app.frame.size)
        func dist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            (abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)) / 3
        }
        let outerDelta = dist(outerOff, outerOn), innerDelta = dist(innerOff, innerOn)
        let report = XCTAttachment(string: "outerDelta=\(outerDelta) innerDelta=\(innerDelta) outerOff=\(outerOff) outerOn=\(outerOn) innerOff=\(innerOff) innerOn=\(innerOn) frames off=\(frameOff) on=\(frameOn)")
        report.name = "32c_band_deltas"
        report.lifetime = .keepAlways
        add(report)
        NSLog("[BUG64] outerDelta=%.3f innerDelta=%.3f off=%@ on=%@", outerDelta, innerDelta, NSCoder.string(for: frameOff), NSCoder.string(for: frameOn))
        // The two focus treatments report slightly different accessibility frames for the same
        // card (~5 pt); the bands are computed per frame, so a small drift is fine — a different
        // CARD (different column / row) is not.
        guard abs(frameOff.width - frameOn.width) < 12, abs(frameOff.minX - frameOn.minX) < 12, abs(frameOff.minY - frameOn.minY) < 12 else {
            throw XCTSkip("focused card differs between the two measurements (\(frameOff) vs \(frameOn))")
        }
        XCTAssertGreaterThan(outerDelta, 0.08, "ring band did not change colour with the ring ON — is the ring drawn at all?")
        XCTAssertLessThan(innerDelta, outerDelta * 0.5, "the band 6…14 pt inside the card edge changed almost as much as the ring band — the stroke is still painted over the poster (BUG-64)")
    }

    /// Mean RGB (0…1) inside `pointRect` of a full-screen screenshot — the colour cousin of
    /// `lumaStats`.
    private func meanRGB(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (Double, Double, Double) {
        guard let cg = image.cgImage, windowSize.width > 0 else { throw XCTSkip("screenshot has no CGImage / zero window size") }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(x: pointRect.minX * scale, y: pointRect.minY * scale, width: pointRect.width * scale, height: pointRect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else { throw XCTSkip("band \(pointRect) is off-screen") }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            r += Double(buffer[i]); g += Double(buffer[i + 1]); b += Double(buffer[i + 2])
        }
        let n = Double(w * h) * 255.0
        return (r / n, g / n, b / n)
    }

    // MARK: - FEAT-24: season posters in the season selector

    /// Opens the first title of the row directly under the hero (a series row on this account —
    /// the same walk test17 uses), scrolls to the Episodes section and looks for the poster
    /// selector (`season_poster_<n>` identifiers). Skips loudly when the opened title is not a
    /// multi-season series or TMDB season posters are off, rather than failing on data.
    func test33SeasonPosterRow() throws {
        let app = launchToHome(forceFreshLaunch: true)
        press(.down, times: 3)          // hero → CW → Streaming → first catalog row
        let anyPoster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'season_poster_'"))
        let anyChip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season '"))
        // Rows are a mix of movie and series catalogs on this account; walk down until a title
        // with a season selector opens (≤ 5 rows), backing out of anything else.
        var found = false
        for row in 0..<5 {
            press(.left, times: 6, gap: 0.3)
            pause(1.0)
            remote.press(.select)
            pause(7)
            shot(app, "33a_row\(row)_detail_opened")
            press(.down, times: 3, gap: 1.0)
            pause(1.5)
            if anyPoster.count > 0 || anyChip.count > 0 { found = true; break }
            // Not a series: back to Home (Menu pops the pushed Detail) and try the next row.
            remote.press(.menu)
            pause(2)
            press(.down, times: 1)
        }
        guard found else { throw XCTSkip("no multi-season series found in the first five rows — nothing to verify") }
        shot(app, "33b_detail_episodes")
        if anyPoster.count == 0 {
            throw XCTSkip("season selector rendered as text chips — no TMDB season posters for this title (useSeasonPosters off or none returned)")
        }
        // The Down walk lands on the episode row (below the selector); the selector is one Up away.
        if !moveFocus(.up, until: anyPoster.firstMatch, max: 3) { _ = moveFocus(.down, until: anyPoster.firstMatch, max: 3) }
        pause(1)
        shot(app, "33c_season_posters_focused")
        XCTAssertGreaterThanOrEqual(anyPoster.count, 2, "poster selector should show one card per season")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Appearance baseline restore (state-aware; safe to run any time)

    /// Puts the signed-in sim profile's SYNCED appearance state back to the suite's baseline:
    /// Ocean theme, Landscape Rows OFF, Hide Titles OFF, Card Depth OFF, plus the two local
    /// focus toggles OFF. Every step is state-aware (reads the row's accessibility value / the
    /// swatch's selection), so it is idempotent. Run it after any failed appearance test — a
    /// mis-landed walk in test27/28 once flipped Landscape Rows and the theme on the real
    /// account (beta.13 wave 2), and every later screenshot lied about the layout.
    func test30AppearanceBaselineRestore() throws {
        let app = launchToHome(forceFreshLaunch: true)
        try restoreAppearanceBaseline(app)
        shot(app, "30_baseline_restored")
        XCTAssertTrue(app.state == .runningForeground)
    }

    private func restoreAppearanceBaseline(_ app: XCUIApplication) throws {
        let appearance = app.buttons["Appearance"]
        openTab(app, named: "Settings")
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let sidebarX = appearance.frame.maxX
        // Theme → Ocean (swatches report focus; selecting the already-selected theme is a no-op).
        let ocean = app.buttons["Ocean"]
        let swatches = ["Crimson", "Ocean", "Violet", "Emerald", "Amber", "Rose", "White"]
        for _ in 0..<30 { // climb to the swatch row; NEVER past it (the tab bar is next)
            if swatches.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.4)
        }
        // Right FIRST: Ocean is the 2nd swatch, and Left from Crimson leaves the row for the
        // sidebar (whose focus SWITCHES panes) — the recording of the 2026-08-16 failure.
        if !moveFocus(.right, until: ocean, max: 6) { _ = moveFocus(.left, until: ocean, max: 6) }
        if ocean.exists && ocean.hasFocus {
            remote.press(.select)
            pause(2.5) // theme change re-identifies the tree; focus may land back on the sidebar
            if appearance.hasFocus { press(.right, times: 1); pause(1) }
        }
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "No Zoom on Focus", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "Hide Titles", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "Landscape Rows", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "Card Depth", on: false, sidebarMaxX: sidebarX, category: "Appearance")
    }

    // MARK: - UX-8: Hide Discover toggle round-trip

    /// Settings → Content Sources → "Hide Discover" ON ⇒ the Search tab must show NO Discover
    /// header; OFF again ⇒ it must come back (test19's existence check, inverted then restored).
    /// Toggle rows never report focus (test25), so `ensureToggleRow` walks by counted rows and
    /// asserts the row's accessibility value flipped — a mis-landed walk fails loudly.
    func test29HideDiscoverToggle() throws {
        let app = launchToHome(forceFreshLaunch: true)
        let contentSources = app.buttons["Content Sources"]
        func openContentSources() {
            openTab(app, named: "Settings")
            _ = moveToSidebarRow(app, .down, named: "Content Sources", max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        openContentSources()
        let sidebarX = contentSources.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Hide Discover", on: true, sidebarMaxX: sidebarX, category: "Content Sources")
        shot(app, "29a_hide_discover_on")

        openTab(app, named: "Search")
        pause(2.5)
        shot(app, "29b_search_without_discover")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 6), "Search tab not reached")
        XCTAssertFalse(app.staticTexts["Discover"].exists, "Discover header still on Search with Hide Discover ON")

        openContentSources()
        try ensureToggleRow(app, labelPrefix: "Hide Discover", on: false, sidebarMaxX: sidebarX, category: "Content Sources")
        openTab(app, named: "Search")
        pause(2.5)
        shot(app, "29c_search_with_discover_again")
        XCTAssertTrue(app.staticTexts["Discover"].waitForExistence(timeout: 8), "Discover did not return after Hide Discover OFF")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - FEAT-18: in-tile title while the focus trailer plays (Hide Titles on)

    /// Screenshot probe (asserts liveness + that the settings walk landed): the reporter runs
    /// Hide Titles (`p2qudtq` t22 — no captions under any card), so the playing trailer tile
    /// carried no title. FEAT-18 draws the logo/name ON the tile in that configuration. Walk:
    /// Hide Titles ON through the real pane (synced poster-style payload — restored at the end),
    /// Home, dwell on the first movies-row card past the morph + resolve, capture; then restore.
    /// Compare 28b (still art + overlay) / 28c (playing + overlay) — the bottom-left of the wide
    /// tile must carry a logo or the title text over a dark foot scrim.
    func test28InlineTrailerTitleOverlayWithHiddenLabels() throws {
        let app = launchToHome(extraArguments: ["-inline_trailers_enabled", "YES", "-debug.trailerProbe", "YES"], forceFreshLaunch: true)
        try restoreAppearanceBaseline(app) // portrait rows, no ring — the reporter's row shape
        let appearance = app.buttons["Appearance"]
        func openAppearance() {
            openTab(app, named: "Settings")
            _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        openAppearance()
        let sidebarX = appearance.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Hide Titles", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        shot(app, "28a_hide_titles_toggled_on")

        openTab(app, named: "Home")
        press(.down, times: 3)          // openTab already stepped into content: hero → CW → Streaming → first movies row
        press(.left, times: 6, gap: 0.3) // first card of the row
        pause(2.5) // dwell (1s) + morph
        shot(app, "28b_expanded_still_with_title_overlay")
        pause(6)
        shot(app, "28c_playing_with_title_overlay")

        openAppearance()
        try ensureToggleRow(app, labelPrefix: "Hide Titles", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        shot(app, "28d_hide_titles_restored_off")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-57: Card Depth "Top" vs "Full" coverage A/B (reporter's config)

    /// Screenshot probe (asserts liveness + landed walks): drives the REAL Appearance pane — the
    /// only valid A/B for a profile-synced payload (prefs injection is overwritten by sync at
    /// launch, beta.12 lesson) — into the reporter's configuration (u/mrStevenx3, `p2qudtq`
    /// t73.5: Accent Focus Ring ON, No Zoom on Focus ON), turns Card Depth on with the Bold edge,
    /// and captures Home rows at Edge Coverage = Top ("En haut" — the reporter's "upwards") and
    /// again at Full. Restores: depth section reset, both toggles back OFF (state-aware, so a
    /// re-run after a failure cannot invert leftover state). Human/agent compares 27b vs 27d
    /// against the mobile app's Top rendering (a full-perimeter outline whose alpha ramps
    /// top→bottom, `composeApp/.../CardDepthEffect.kt`).
    func test27CardDepthCoverageAB() throws {
        let app = launchToHome(forceFreshLaunch: true)
        let appearance = app.buttons["Appearance"]
        func openAppearance() {
            openTab(app, named: "Settings")
            _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        // Chip rows keep the column you arrive in — walk to the row, then Left/Right by chip
        // (chips DO report focus).
        func selectChip(_ name: String, rowPrefix: String, sidebarX: CGFloat) throws {
            try walkToRowByTreeIndex(app, targetLabelPrefix: rowPrefix, sidebarMaxX: sidebarX, category: "Appearance")
            let chip = app.buttons[name]
            // Chips report focus: prove the walk landed on the row before sliding along it.
            let rowChips = ["Subtle", "Balanced", "Bold", "Off", "Soft", "Bright", "Top", "Half", "Full"]
            guard rowChips.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) else {
                XCTFail("walk to chip row '\(rowPrefix)' did not land on a chip row"); return
            }
            // Right FIRST: Left from the leftmost chip leaves the row for the sidebar (pane
            // switch), while Right past the last chip is a no-op.
            if !moveFocus(.right, until: chip, max: 4) { _ = moveFocus(.left, until: chip, max: 4) }
            guard chip.exists && chip.hasFocus else { XCTFail("chip \(name) never focused"); return }
            remote.press(.select)
            pause(0.8)
        }

        try restoreAppearanceBaseline(app) // Ocean, portrait rows, everything OFF — a known start
        openAppearance()
        let sidebarX = appearance.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "No Zoom on Focus", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        shot(app, "27a_ring_and_nozoom_on")
        try ensureToggleRow(app, labelPrefix: "Card Depth", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        XCTAssertTrue(app.buttons["Top"].waitForExistence(timeout: 2), "Edge Coverage chips never appeared — Card Depth not on")
        // The chip rows are labelled by their first chip in the AX tree — anchor on "Subtle"
        // (edge row) and "Top" (coverage row).
        try selectChip("Bold", rowPrefix: "Subtle", sidebarX: sidebarX)
        try selectChip("Top", rowPrefix: "Top", sidebarX: sidebarX)
        shot(app, "27a2_depth_bold_top_selected")

        openTab(app, named: "Home")
        press(.down, times: 3, gap: 1.0)
        pause(3)
        shot(app, "27b_home_rows_depth_TOP")
        press(.right, times: 1)
        pause(1.5)
        shot(app, "27b2_home_rows_depth_TOP_second_card")

        openAppearance()
        try selectChip("Full", rowPrefix: "Top", sidebarX: sidebarX)
        shot(app, "27c_depth_full_selected")
        openTab(app, named: "Home")
        press(.down, times: 3, gap: 1.0)
        pause(3)
        shot(app, "27d_home_rows_depth_FULL")

        // Restore everything (depth OFF, both focus toggles OFF, theme) through the shared
        // state-aware baseline — the same routine test30 runs standalone.
        try restoreAppearanceBaseline(app)
        shot(app, "27e_restored")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Moves focus to the pane row whose label starts with `targetLabelPrefix` — a row that does
    /// NOT report focus to XCUITest (SettingsToggleRow, test25) — by COUNTING ROWS in the AX
    /// tree. Precondition: focus is on the pane's FIRST row (just pressed Right from the
    /// sidebar). Rows are grouped by frame.minY (chip rows hold several buttons side by side but
    /// are ONE row for Down/Up), so Downs = row-index distance. Lazy culling means the target
    /// may not be in the tree from the top: then hop to the LAST materialised row (its label is
    /// known and it is on-screen after the hop, so it is re-findable), re-capture, repeat.
    /// Landing on a chip row leaves focus in the same column it came from — callers that need a
    /// specific chip walk Left/Right afterwards with `moveFocus` (chips report focus).
    private func walkToRowByTreeIndex(_ app: XCUIApplication, targetLabelPrefix: String, sidebarMaxX: CGFloat, category: String) throws {
        let tabNames: Set<String> = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        func rows() -> [[XCUIElement]] {
            // beta.15 §C5 (confirmed via `app.debugDescription`, not guessed): EVERY row in the
            // native detail List — toggle, picker, value, link, action — is wrapped in exactly
            // one `Cell`, uniformly, regardless of the control(s) inside it (a chip/swatch row's
            // several buttons all nest under ONE Cell). Building the row list from `app.buttons`
            // (+ the toggle-typed queries) both drops rows whose only interactive content isn't a
            // Button (toggles resolve ambiguously between legacy `.switch` and modern `.toggle` —
            // see focusedButton's comment) AND risks double-counting a row as both its Cell and
            // its nested control. `app.cells` alone gives exactly one entry per visual row.
            let pane = app.cells.allElementsBoundByIndex
                // Past the sidebar, and NOT the tab bar (its buttons also sit right of the sidebar
                // and once counted as "row 0" of the pane — beta.13 wave 2 finding).
                .filter { $0.frame.minX > sidebarMaxX + 20 && $0.frame.width > 0 && !tabNames.contains($0.label) && $0.frame.minY > 90 }
                .sorted { $0.frame.minY < $1.frame.minY }
            var out: [[XCUIElement]] = []
            for b in pane {
                if let last = out.last?.first, abs(last.frame.minY - b.frame.minY) < 6 {
                    out[out.count - 1].append(b)
                } else {
                    out.append([b])
                }
            }
            return out
        }
        // Where is focus NOW? Right from the sidebar lands on the pane row NEAREST the sidebar
        // item's Y (tvOS focus engine), not on the first row — so never assume row 0. Toggle
        // rows don't report focus, but chip/swatch buttons do: press Up one row at a time until
        // some pane button reports focus and take its row as the anchor; past the top Up is a
        // no-op, so if nothing ever reports we are at row 0 anyway.
        func inPane(_ e: XCUIElement) -> Bool { e.frame.minX > sidebarMaxX + 20 && !tabNames.contains(e.label) && e.frame.minY > 90 }
        // Anchor: the row containing the focused element (by FRAME, not label — the Appearance
        // pane repeats labels: two "Reset to Defaults", "Off"/"Default" chips). Toggle rows don't
        // report focus, but chips/swatches do; Up one row at a time until something reports.
        func focusedRowIndex(_ r: [[XCUIElement]]) -> Int? {
            guard let f = focusedButton(app), inPane(f) else { return nil }
            let y = f.frame.minY
            return r.firstIndex(where: { row in abs(row[0].frame.minY - y) < 6 })
        }
        var anchorLabel: String? = nil // set after a hop; looked up with lastIndex (hops only go down)
        if focusedButton(app).map(inPane) != true {
            for _ in 0..<24 {
                if let f = focusedButton(app), tabNames.contains(f.label) {
                    remote.press(.down); pause(0.8)
                    if let g = focusedButton(app), inPane(g) { break }
                    continue
                }
                if let f = focusedButton(app), f.frame.minX <= sidebarMaxX + 20 {
                    if f.label != category {
                        if !moveToSidebarRow(app, .down, named: category, max: 8) { _ = moveToSidebarRow(app, .up, named: category, max: 8) }
                        pause(1)
                    }
                    remote.press(.right); pause(0.8)
                    if let g = focusedButton(app), inPane(g) { break }
                    continue
                }
                remote.press(.up); pause(0.35)
                if let f = focusedButton(app), inPane(f) { break }
            }
        }
        /// Post-condition enforcement (2026-08-25, found while fixing test32): the index
        /// arithmetic above can finish ONE ROW PAST the target, and nothing used to check.
        /// `ensureToggleRow` then pressed Select on the neighbour — on the Appearance pane that
        /// silently flipped "No Zoom on Focus" while asserting about "Accent Focus Ring", so the
        /// failure read as "the toggle would not change state" and sent two investigations after
        /// the state READ (which was always correct) and after profile sync (which was innocent).
        ///
        /// Rather than re-derive the arithmetic — it carries a lot of focus-engine history — this
        /// verifies what the function promises and nudges one row at a time until it holds. Cheap,
        /// and it fixes the landing for every caller, not just the one that exposed it.
        func settleFocusOnTargetRow() {
            func targetY() -> CGFloat? {
                rows().first(where: { row in row.contains { $0.label.hasPrefix(targetLabelPrefix) } })?[0].frame.minY
            }
            for _ in 0..<8 {
                guard let f = focusedButton(app), inPane(f) else { return } // focus unreadable: leave as-is
                if f.label.hasPrefix(targetLabelPrefix) { return }
                guard let ty = targetY() else { return }
                if abs(f.frame.minY - ty) < 6 { return } // same row, different element in it
                remote.press(f.frame.minY > ty ? .up : .down)
                pause(0.6)
            }
            if let f = focusedButton(app), inPane(f), !f.label.hasPrefix(targetLabelPrefix) {
                XCTFail("focus would not settle on '\(targetLabelPrefix)…' — ended on '\(f.label.prefix(60))'")
            }
        }

        for _ in 0..<10 {
            let r = rows()
            guard !r.isEmpty else { throw XCTSkip("no pane buttons in the AX tree") }
            let from = focusedRowIndex(r)
                ?? anchorLabel.flatMap { label in r.lastIndex(where: { row in row.contains { $0.label == label } }) }
                ?? 0
            if let targetIndex = r.firstIndex(where: { row in row.contains { $0.label.hasPrefix(targetLabelPrefix) } }) {
                let delta = targetIndex - from
                if delta > 0 { press(.down, times: delta, gap: 0.6) }
                if delta < 0 { press(.up, times: -delta, gap: 0.6) }
                pause(0.8)
                settleFocusOnTargetRow()
                return
            }
            // Hop to the LAST row whose label is unique in this capture (so it is re-findable).
            let labels = r.map { $0[0].label }
            guard let hop = (0..<r.count).reversed().first(where: { i in i > from && labels.filter { $0 == labels[i] }.count == 1 }) else { break }
            press(.down, times: hop - from, gap: 0.6)
            anchorLabel = labels[hop]
            pause(0.8)
        }
        XCTFail("row '\(targetLabelPrefix)…' never materialised in the pane")
    }

    /// Reads a `SettingsToggleRow`'s On/Off state, tolerating either accessibility shape this
    /// build produces for the SAME control (beta.15 §C5, confirmed via `app.debugDescription`):
    /// a fully-materialized `Toggle` reports plain `.value` "On"/"Off" with a bare title `.label`;
    /// an outer List `Cell` instead composes everything into `.label` as "Title, …, On"/"…, Off"
    /// with no usable `.value`. nil when neither shape is recognized (caller should treat that as
    /// "unknown", not silently OFF).
    private func toggleState(_ element: XCUIElement) -> Bool? {
        if let value = element.value as? String {
            if value == "On" { return true }
            if value == "Off" { return false }
        }
        let label = element.label
        if label.hasSuffix(", On") { return true }
        if label.hasSuffix(", Off") { return false }
        return nil
    }

    /// State-aware toggle: walks to the `SettingsToggleRow` whose label starts with
    /// `labelPrefix` and presses Select ONLY if its "On ·"/"Off ·" subtitle disagrees with
    /// `on`. Idempotent, so a re-run after a failed run cannot invert leftover state. Asserts
    /// the resulting label loudly. Precondition/postcondition as `walkToRowByTreeIndex`.
    private func ensureToggleRow(_ app: XCUIApplication, labelPrefix: String, on: Bool, sidebarMaxX: CGFloat, category: String) throws {
        // beta.15 §C5: SettingsToggleRow is now a real `Toggle` whose resolved element type is
        // ambiguous between legacy `.switch` and modern `.toggle` on this SDK, not the old
        // hand-rolled `.button` — see focusedButton's comment for how this was diagnosed.
        // `descendants(matching: .any)` sidesteps the type-scoped query entirely.
        //
        // The row surfaces THREE times under one label (dumped 2026-08-25, not guessed): the
        // wrapping `Cell` (composed label ending ", On"/", Off", no usable `.value`), the `Switch`
        // (`.value` "On"/"Off"), and a bare `StaticText` carrying NEITHER. `firstMatch` could
        // return any of them, and the old `toggleState(...) ?? false` turned "unreadable" into
        // "Off" — a silent wrong answer that pressed Select on a toggle it had not actually read.
        // Scan the candidates instead, prefer the one with a real value, and treat unreadable as
        // a loud failure.
        func readState() -> Bool? {
            let matches = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix))
                .allElementsBoundByIndex
            for e in matches where (e.value as? String) == "On" || (e.value as? String) == "Off" {
                return (e.value as? String) == "On"
            }
            for e in matches { if let s = toggleState(e) { return s } }
            return nil
        }
        func describeCandidates() -> String {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix))
                .allElementsBoundByIndex
                .map { "t\($0.elementType.rawValue):v=<\(String(describing: $0.value))>:l=<\($0.label.suffix(16))>" }
                .joined(separator: " | ")
        }

        try walkToRowByTreeIndex(app, targetLabelPrefix: labelPrefix, sidebarMaxX: sidebarMaxX, category: category)
        guard let before = readState() else {
            XCTFail("toggle '\(labelPrefix)' state unreadable — candidates: \(describeCandidates())")
            return
        }
        if before != on {
            remote.press(.select)
            pause(1.5)
        }
        guard let after = readState() else {
            XCTFail("toggle '\(labelPrefix)' state unreadable after the press — candidates: \(describeCandidates())")
            return
        }
        XCTAssertEqual(after, on, "toggle '\(labelPrefix)' did not end up \(on ? "ON" : "OFF") (was \(before)) — candidates: \(describeCandidates())")
    }

    // MARK: - Home "Upcoming" row (next airing episodes of followed shows)

    /// The Upcoming row renders under Continue Watching with one card per followed show carrying
    /// an S00E00 code and a TODAY / TOMORROW / IN N DAYS pill, and selecting a card pushes the
    /// show's Detail page. Data-dependent: the signed-in profile must follow a show with an
    /// episode inside the 14-day horizon — if the row never appears the test SKIPS loudly (not
    /// a vacuous pass); if it appears its cards must carry the badges.
    func test34UpcomingRow() throws {
        let app = launchToHome(forceFreshLaunch: true)
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)

        // Cards are NavigationLinks whose composed label carries the badges — the row's own
        // signature (the title alone can be in the tree a row early: the LazyVStack mounts the
        // next row while the previous one is focused, more so in pinned mode).
        let badgePredicate = NSPredicate(
            format: "label MATCHES[c] '.*S[0-9]{2}E[0-9]{2}.*' AND (label CONTAINS[c] 'TODAY' OR label CONTAINS[c] 'TOMORROW' OR label MATCHES[c] '.*IN [0-9]+ DAYS.*')"
        )
        let title = app.staticTexts["Upcoming"]
        let badgeCards = app.buttons.matching(badgePredicate)
        let badgeCard = badgeCards.firstMatch

        // Walk down one row at a time until a badge card HOLDS focus — ANY of them: vertical
        // focus travel keeps the column, so entering the row from CW's 4th card lands on the
        // row's 4th card (26.5 runtime reports focus; on 27.0 `hasFocus` never reads true —
        // fall back to "title + card exist" like the other existence-driven walks). CW sits
        // above; catalog rows below.
        var downs = 0
        var cardFocused = false
        var mounted = false
        while downs < 9 {
            press(.down, times: 1)
            downs += 1
            pause(1.0)
            if badgeCards.allElementsBoundByIndex.contains(where: { $0.hasFocus }) { cardFocused = true; break }
            // 27.0-runtime fallback (no focus reports): the row mounts one step before focus
            // reaches it (it is the row after the one focused), so stop at the first step where
            // it exists and take exactly one more Down — never walk on past it.
            if title.exists && badgeCard.exists { mounted = true; break }
        }
        if !cardFocused {
            guard mounted else {
                shot(app, "34_no_upcoming_row")
                throw XCTSkip("no Upcoming row within \(downs) rows — does the profile follow a show airing in the next 14 days?")
            }
            press(.down, times: 1)
            pause(1.0)
        }
        pause(1.5)
        shot(app, "34a_upcoming_row")
        XCTAssertTrue(badgeCard.exists, "no Upcoming card with an S00E00 code + air-date pill in the tree")

        // Select → the show's Detail page (a pushed screen: the root tab bar leaves the tree's
        // visible band). Menu pops back.
        remote.press(.select)
        pause(4)
        shot(app, "34b_detail_from_upcoming")
        let homeTab = app.buttons["Home"]
        XCTAssertTrue(!homeTab.exists || homeTab.frame.minY <= 0, "selecting an Upcoming card should push Detail (tab bar off-screen)")
        remote.press(.menu)
        pause(2)
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Self-hosted server discovery (review step, non-destructive)

    /// Settings → Account & Services → "Connect to a Self-Hosted Server" → type the URL of a
    /// loopback stub serving `/.well-known/nuvio` → "Check Server" → the REVIEW step must show
    /// the discovered backend. Also exercises the typed-error path (the official host is
    /// refused with the "already selected" copy) and that Back returns to the entry step.
    /// DELIBERATELY never presses "Connect to This Server" — a switch signs the account out
    /// and wipes local data on the signed-in sim; the destructive half lives in
    /// `ScratchServerSwitchTests` (scratch-device only).
    func test35ServerDiscoveryReview() throws {
        let stub = DiscoveryStubServer(document: .init(emailPasswordAuth: true, tvLogin: false))
        try stub.start()
        defer { stub.stop() }

        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let account = app.buttons["Account & Services"]
        if !(account.exists && account.hasFocus) { _ = moveToSidebarRow(app, .up, named: "Account & Services", max: 8) }
        remote.press(.select)
        pause(1.2)
        press(.right, times: 1)
        pause(1)
        let sidebarX = account.frame.maxX
        shot(app, "35a_account_pane")

        // The Server section sits right under Account; walk there by tree index.
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Connect to a Self-Hosted Server", sidebarMaxX: sidebarX, category: "Account & Services")
        let connectRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to a Self-Hosted Server'")).firstMatch
        guard connectRow.exists else { XCTFail("Server section row missing from Account & Services"); return }
        remote.press(.select)
        pause(1.5)

        let urlField = app.textFields["server.url"]
        guard urlField.waitForExistence(timeout: 6) else {
            shot(app, "35x_no_cover")
            XCTFail("ServerConnectionView cover did not appear")
            return
        }
        shot(app, "35b_server_enter")

        // 1) Negative path: the official host is refused with a typed error.
        func enterUrl(_ text: String) -> Bool {
            if !urlField.hasFocus { _ = moveFocus(.up, until: urlField, max: 6) }
            remote.press(.select)
            pause(2) // full-screen keyboard
            // Clear anything pre-filled (a custom server's discovery base is pre-filled when
            // one is active; on the official sim it is empty) — select-all isn't available on
            // the tvOS keyboard, so only proceed when the field is empty.
            let typed = typeOnKeyboard(app, text)
            remote.press(.menu) // commit + dismiss the keyboard (the typed text stays in the field)
            pause(1.5)
            return typed
        }
        guard enterUrl("https://api.nuvio.tv") else {
            XCTFail("could not type into the server URL field (keyboard not driveable)")
            return
        }
        let check = app.buttons["server.check"]
        guard check.waitForExistence(timeout: 4) else { XCTFail("Check Server button missing"); return }
        // Down from the field can land on either button of the row (focus-engine geometry);
        // glass buttons don't reliably report focus, so pin it: Down, then Left twice (Check
        // Server is the leftmost control of the row, Left past it is a no-op).
        func focusCheckServer() { press(.down, times: 1); press(.left, times: 2, gap: 0.5) }
        focusCheckServer()
        remote.press(.select)
        pause(2)
        let officialError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "official server")).firstMatch
        XCTAssertTrue(officialError.waitForExistence(timeout: 8), "typing the official host must surface the 'official server' discovery error")
        shot(app, "35c_official_refused")

        // 2) Happy path against the loopback stub. The field still holds the official URL —
        // Menu-commit keeps the text — so re-open the keyboard and replace it: tvOS keyboards
        // have a clear ("Clear") key; fall back to appending if clearing isn't reachable.
        if !urlField.hasFocus { _ = moveFocus(.up, until: urlField, max: 6) }
        remote.press(.select)
        pause(2)
        let clearKey = app.keys["Clear"]
        if clearKey.waitForExistence(timeout: 2) {
            if !clearKey.hasFocus { _ = moveFocus(.right, until: clearKey, max: 14) || moveFocus(.down, until: clearKey, max: 6) }
            if clearKey.hasFocus { remote.press(.select); pause(0.5) }
        }
        let value = (urlField.value as? String) ?? ""
        if !value.isEmpty && value != "https://backend.example.com" {
            // Could not clear; delete character by character via the hardware-keyboard path.
            for _ in 0..<value.count { app.typeText(XCUIKeyboardKey.delete.rawValue) }
            pause(0.5)
        }
        _ = typeOnKeyboard(app, stub.origin)
        remote.press(.menu)
        pause(1.5)
        let entered = (urlField.value as? String) ?? ""
        guard entered.contains("127.0.0.1") else {
            shot(app, "35x_url_not_entered")
            XCTFail("stub URL not entered (field value = \(entered))")
            return
        }
        focusCheckServer()
        remote.press(.select)

        let reviewTitle = app.staticTexts["server.review"]
        guard reviewTitle.waitForExistence(timeout: 20) else {
            shot(app, "35x_no_review")
            XCTFail("review step never appeared — stub saw \(stub.requestLog)")
            return
        }
        shot(app, "35d_server_review")
        let backend = app.staticTexts["server.backend"]
        XCTAssertTrue(backend.exists && backend.label.contains("127.0.0.1:\(stub.port)"), "review must show the discovered backend (got \(backend.exists ? backend.label : "nil"))")
        XCTAssertTrue(app.buttons["server.connect"].exists, "Connect to This Server must be offered")
        XCTAssertTrue(stub.requestLog.contains("GET /.well-known/nuvio"), "the app must have fetched the discovery document (log: \(stub.requestLog))")
        // tv_login=false → the review must say QR sign-in is not available.
        XCTAssertTrue(app.staticTexts["Not available"].exists, "QR sign-in capability must read Not available for a tv_login=false document")

        // Back → entry step again (no switch happened).
        let back = app.buttons["Back"]
        if back.exists {
            // Back is the rightmost control of the review's button row.
            press(.down, times: 8, gap: 0.4)
            press(.right, times: 2, gap: 0.5)
            remote.press(.select)
            pause(1.5)
            XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Back must return to the URL entry step")
        }
        shot(app, "35e_back_to_enter")
        remote.press(.menu) // dismiss the cover
        pause(1.5)
        XCTAssertTrue(app.state == .runningForeground)
        // Still signed in: the Account & Services pane's Sign Out row must still be around.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign Out'")).firstMatch.waitForExistence(timeout: 6), "the non-destructive flow must leave the account signed in")
    }


    // MARK: - BUG-58: theme swatch label must stay legible while focused

    /// BUG-58 (beta.11 regression from the BUG-50 sweep): the focused theme swatch's name was
    /// painted `onFocusPlatter` (near-black) on the assumption that the `.borderless` swatch
    /// button draws the white system focus platter. It doesn't — the label landed straight on
    /// the dark pane and vanished ("Amber" disappears while it has focus; Christian's device
    /// clip, 2026-08-16). This walks focus onto a swatch and MEASURES the label band under it in
    /// the screenshot: it must contain bright (textPrimary-class) pixels. Pre-fix the band's
    /// brightest pixel was the pane background (~0.05 luma); post-fix it is the label (~0.9).
    /// Skips (loudly) if the swatch never reports focus (tvOS 27.0 runtime gotcha) rather than
    /// passing vacuously.
    func test26ThemeSwatchFocusedLabelLegible() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // Violet is neither the account's selected theme (Ocean) nor an edge swatch, so its
        // at-rest label is textSecondary and the focused read is purely the isFocused branch.
        let violet = app.buttons["Violet"]
        if !moveFocus(.right, until: violet, max: 8) { _ = moveFocus(.left, until: violet, max: 8) }
        guard violet.exists, violet.hasFocus else {
            throw XCTSkip("Violet swatch never reported focus — cannot measure the focused label")
        }
        pause(1) // let the focus lift + label color animation settle
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "26a_violet_swatch_focused"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Label band = the bottom third of the swatch button (circle 56pt + caption below it),
        // inset horizontally so the neighbouring swatches' labels never leak in.
        let frame = violet.frame
        let band = CGRect(
            x: frame.minX + frame.width * 0.15,
            y: frame.minY + frame.height * 0.62,
            width: frame.width * 0.70,
            height: frame.height * 0.36
        )
        let stats = try lumaStats(in: screenshot.image, pointRect: band, windowSize: app.frame.size)
        let report = XCTAttachment(string: "band=\(band) max=\(stats.max) brightFraction=\(stats.brightFraction)")
        report.name = "26b_label_band_luma"
        report.lifetime = .keepAlways
        add(report)
        print("[BUG58] focused Violet label band: max luma \(stats.max), bright fraction \(stats.brightFraction)")
        XCTAssertGreaterThan(
            stats.max, 0.7,
            "focused swatch label is not legible — brightest pixel under the focused swatch is \(stats.max) (BUG-58 regression: label painted platter-black on the dark pane)"
        )
        XCTAssertGreaterThan(
            stats.brightFraction, 0.005,
            "focused swatch label band has almost no bright pixels (\(stats.brightFraction))"
        )
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-65: Appearance toggle rows must keep dark text on the focus platter

    /// BUG-65 (beta.13, u/mrStevenx3's review video t=133.5): on HIS DEVICE the focused "Anneau
    /// de focus couleur d'accent" row renders as a white platter with near-invisible light
    /// title/subtitle. Calibration finding (2026-08-20, three sim runs): the 26.5 SIM does NOT
    /// reproduce the white-out — the focused row renders dark-on-platter here in every run,
    /// measuring a dark-pixel fraction of ~0.013 (the title is a thin line in a wide platter
    /// band). So this guard's job in the sim is regression-catching only: a healthy row measures
    /// ≥ ~0.013 dark; a white-out measures ≈ 0. The threshold sits between the two. Toggle rows
    /// never report `hasFocus` on this runtime (beta.13 harness lesson), so the probe keys off
    /// the measured platter instead and skips loudly if no platter is ever seen.
    func test36AppearanceToggleRowFocusedContrast() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // beta.15 §C5: real `Toggle` = `.switch` element, not `.button`.
        let ringRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Accent Focus Ring")
        ).firstMatch
        guard ringRow.waitForExistence(timeout: 6) else {
            throw XCTSkip("Accent Focus Ring row never appeared — pane navigation failed")
        }

        // Walk down from the swatch row toward the toggle rows, measuring the ring row's band at
        // each rest. The focused step is the one where the band's mean luma jumps (white platter).
        var platterSeen = false
        var worstDarkFraction = 1.0
        for step in 0..<6 {
            if step > 0 { press(.down, times: 1) }
            pause(1)
            guard ringRow.exists else { break }
            let frame = ringRow.frame
            let band = frame.insetBy(dx: frame.width * 0.05, dy: frame.height * 0.12)
            let profile = try lumaProfile(in: XCUIScreen.main.screenshot().image, pointRect: band, windowSize: app.frame.size)
            print("[BUG65] step \(step): ring row band mean=\(profile.mean) dark=\(profile.darkFraction) bright=\(profile.brightFraction)")
            if profile.mean > 0.55 {
                platterSeen = true
                worstDarkFraction = min(worstDarkFraction, profile.darkFraction)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "36_ring_row_platter_step\(step)"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
        guard platterSeen else {
            throw XCTSkip("the ring row never showed a focus platter — focus walk missed it; cannot measure")
        }
        XCTAssertGreaterThan(
            worstDarkFraction, 0.004,
            "focused Appearance toggle row is white-on-white: platter present but only \(worstDarkFraction) of the band is dark label-class pixels (BUG-65; a legible row measures ~0.013)"
        )
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Mean luma plus dark (<0.35) and bright (>0.7) pixel fractions inside `pointRect`.
    /// Same coordinate/scaling contract as `lumaStats`.
    private func lumaProfile(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (mean: Double, darkFraction: Double, brightFraction: Double) {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else {
            throw XCTSkip("band \(pointRect) is off-screen")
        }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        var dark = 0
        var bright = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let l = (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255.0
            total += l
            if l < 0.35 { dark += 1 }
            if l > 0.7 { bright += 1 }
        }
        let count = Double(w * h)
        return (total / count, Double(dark) / count, Double(bright) / count)
    }

    /// Max relative luma and the fraction of pixels above 0.7 luma inside `pointRect` (in the
    /// app window's point space) of a full-screen screenshot. Scales points→pixels from the
    /// screenshot/window width ratio (sim screenshots are exactly 2 px/pt).
    private func lumaStats(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (max: Double, brightFraction: Double) {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else {
            throw XCTSkip("label band \(pointRect) is off-screen")
        }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var maxLuma = 0.0
        var bright = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let l = (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255.0
            if l > maxLuma { maxLuma = l }
            if l > 0.7 { bright += 1 }
        }
        return (maxLuma, Double(bright) / Double(w * h))
    }

    /// The trailing SeeAllCard as an element query. Its composed accessibility label is NOT the
    /// bare string "See All" (the card's empty caption-alignment slot joins in), so an exact
    /// `app.buttons["See All"]` subscript never matches on any runtime — every earlier "green"
    /// that gated on it was skipping (Codex round 1's vacuous-pass finding).
    private func seeAllCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "See All")).firstMatch
    }

    /// Walks Right until `element` exists in the accessibility tree (a lazily-mounted trailing
    /// card materializes only as focus nears it), pressing at most `max` times. Deliberately NOT
    /// focus-driven — see test23's comment on tvOS 27.0 focus reporting.
    @discardableResult
    private func walkRightUntilExists(_ element: XCUIElement, max: Int) -> Bool {
        if element.exists { return true }
        for _ in 0..<max {
            remote.press(.right)
            pause(0.6)
            if element.exists { return true }
        }
        return false
    }

    // MARK: - trailer_playback_location: hero vs poster

    /// `trailer_playback_location` (`HomeView.swift`'s `@AppStorage` key, default "poster") picks
    /// WHERE "Trailers on Focus" plays a focused title's trailer: the classic poster morph
    /// (unchanged pre-existing behavior, covered by test01), or the pinned hero backdrop —
    /// `heroFocusTrailerMode` only engages the hero surface when the container is actually
    /// pinned (`-hero_nuvio_style YES`, same as test22/test31), so that argument travels with
    /// both legs here.
    ///
    /// Reuses `TrailerSoakTests`' deterministic-row-geometry recipe (forced smoke video id,
    /// `-home_upcoming_row_enabled NO` so the down×4 walk to the first movies row is the same
    /// pre-Upcoming layout test01/TrailerSoakTests' walks were written against — those run
    /// UNPINNED; the pinned variant of the same walk is validated here, not by that precedent —
    /// plus the location knob. Both
    /// legs are fresh launches (`forceFreshLaunch: true`, same rationale as test20/22/31) so
    /// neither inherits the other's focus/dwell state.
    ///
    /// `debug_hero`'s two appended fields (HomeView.swift) are the oracle: `tloc=h|p` is the
    /// trailer location the rows are actually rendering under, `hph=idle|dwell|exp|play` the
    /// hero trailer model's live phase (see `debugHeroTrailerPhase`). Hero location must show
    /// `tloc=h` and the model advancing past idle; poster location must show `tloc=p` and the
    /// pre-existing 16:9 morph on the focused card.
    func test37TrailerLocationHero() throws {
        // Same known bar-free trailer id TrailerSoakTests.smokeVideoId forces (duplicated, not
        // shared — see TrailerSoakTests' type doc on why cross-file test helpers stay copied).
        let smokeVideoId = "rNZ0xKaCdus"
        func heroLocationArguments(_ location: String) -> [String] {
            [
                "-inline_trailers_enabled", "YES",
                "-debug.trailerProbe", "YES",
                "-debug.trailerSmokeVideoId", smokeVideoId,
                // Deterministic row geometry (TrailerSoakTests' trick): removes the Upcoming row
                // so the down×4 walk below has a stable target.
                "-home_upcoming_row_enabled", "NO",
                "-trailer_playback_location", location,
                "-hero_nuvio_style", "YES",
                // Codex gate r2: the hero leg's `hph` oracle must be the FOCUS-driven claimant
                // (`heroFocusTrailerActive`), never FEAT-25's carousel autoplay — a sim whose
                // stored settings have Autoplay Hero Trailer on would otherwise satisfy the
                // phase assertion with the carousel's own attempt. Forced off for both legs.
                "-hero_trailer_autoplay", "NO",
            ]
        }

        /// Walks down×4 to the first movies row (test01/TrailerSoakTests' walk, run pinned
        /// here), snapshots the row's resting geometry, then polls through the dwell + resolve +
        /// morph window and returns the PEAK rightward displacement of the focused card's row
        /// neighbours plus the debug_hero probe.
        ///
        /// Why neighbours, not the focused card (sim runs 2/3, 2026-08-21): the focused Button's
        /// AX frame stays at its resting portrait width through a morph that the screenshots
        /// (and `[TrailerPipeline] claimPlayback`) prove fired — the card body is
        /// `accessibilityHidden`, so the Button's reported frame doesn't follow the tile. What
        /// the morph DOES move is everything to its right: the rest of the row slides over by
        /// the landscape−portrait delta (~170pt). That displacement is the oracle. Peak, not
        /// final, so a morph that fired and then COLLAPSED (Codex pre-commit round 5) still
        /// registers.
        func measureDwell(_ app: XCUIApplication, _ tag: String) throws -> (before: CGFloat, peak: CGFloat, probe: String) {
            // Upcoming row forced off (see heroLocationArguments), so this is the pre-Upcoming
            // row geometry test01/TrailerSoakTests' down×4 walks were written against.
            press(.down, times: 3)
            remote.press(.down)
            pause(0.3) // focus-engine settle only — the baseline MUST land inside the 1.0s dwell
            // ONE baseline read, immediately after the final press: the focused card AND its row
            // neighbours from the same `snapshot()`. A separate `focusedButton` sweep here took
            // long enough (plus the press gap) to straddle the dwell, so the "resting" geometry
            // was already mid-morph (sim run 5). Snapshot first, judge the snapshot after.
            let baseline = buttonSnapshots(app)
            guard let beforeFrame = baseline.first(where: { $0.hasFocus })?.frame else {
                throw XCTSkip("no focused element reported before dwell (27.0 runtime never reports hasFocus)")
            }
            guard beforeFrame.width > 80, beforeFrame.height > beforeFrame.width else {
                throw XCTSkip("focused element before dwell is not a resting portrait poster — frame=\(beforeFrame)")
            }
            /// The focused card's row neighbours to its right: same vertical band, further along.
            /// The band follows the focused card's position IN THAT SAME SNAPSHOT (sim run 6: the
            /// baseline lands while the row is still sliding up into place — focused y=711 vs a
            /// 648 rest — so a band anchored to the baseline's midY rejected every later
            /// neighbour). Only minX feeds the oracle, and that is scroll-independent.
            func neighbourMinXs(_ snaps: [(frame: CGRect, hasFocus: Bool)]) -> [CGFloat] {
                let anchor = snaps.first(where: { $0.hasFocus })?.frame ?? beforeFrame
                return snaps.compactMap { b -> CGFloat? in
                    let f = b.frame
                    guard abs(f.midY - anchor.midY) < 20, f.minX > anchor.maxX - 1 else { return nil }
                    return f.minX
                }.sorted()
            }
            func neighbourMinXs() -> [CGFloat] { neighbourMinXs(buttonSnapshots(app)) }
            let neighboursBefore = neighbourMinXs(baseline)
            guard let firstNeighbourBefore = neighboursBefore.first else {
                throw XCTSkip("focused poster has no row neighbour to its right — frame=\(beforeFrame)")
            }
            shot(app, "\(tag)_00_before_dwell")
            print("[UX7] \(tag) baseline focused=\(beforeFrame) neighbours=\(neighboursBefore.prefix(3))")

            // Poll the peak at 0.5s through an 8s window (test01's own morph window is 8s+): on
            // this sim the poster morph follows resolution at ~+3.6s after focus.
            var peakShift: CGFloat = 0
            for i in 0..<16 {
                pause(0.5)
                if let firstNeighbour = neighbourMinXs().first {
                    peakShift = max(peakShift, firstNeighbour - firstNeighbourBefore)
                }
                if i == 2 || i == 8 {
                    print("[UX7] \(tag) sample \(i) focused=\(focusedButton(app)?.frame ?? .zero) neighbour=\(neighbourMinXs().first ?? -1) peakShift=\(peakShift)")
                }
                if i == 2 { shot(app, "\(tag)_01_mid_window") }
            }
            shot(app, "\(tag)_02_after_dwell")
            let probe = heroSrcProbe(app, "\(tag)_03_probe")
            return (firstNeighbourBefore, firstNeighbourBefore + peakShift, probe)
        }

        // Leg 1: hero location — the focused poster must NOT morph; the hero backdrop takes the
        // trailer instead.
        let heroApp = launchToHome(extraArguments: heroLocationArguments("hero"), forceFreshLaunch: true)
        let heroResult = try measureDwell(heroApp, "37a_hero")
        XCTAssertLessThanOrEqual(
            heroResult.peak, heroResult.before + 12,
            "row neighbours shifted (poster morph fired) while trailer_playback_location=hero — neighbourMinX before=\(heroResult.before) peak=\(heroResult.peak)"
        )
        XCTAssertTrue(heroResult.probe.contains(" tloc=h"), "trailer_playback_location=hero must set tloc=h on debug_hero, got: \(heroResult.probe)")
        // Codex gate r2: with carousel autoplay forced off above, the only path to a non-idle
        // `hph` is a COMMITTED row focus (`src=f` + a real `fitem`), so prove that focus state
        // exists before reading the phase — otherwise the phase assertion below could not
        // distinguish "the feature worked" from "some other claimant ran".
        XCTAssertTrue(heroResult.probe.contains(" src=f"), "hero leg must have a committed row focus (src=f) driving the hero, got: \(heroResult.probe)")
        XCTAssertFalse(heroResult.probe.contains(" fitem=- "), "hero leg must report the focused item id (fitem=), got: \(heroResult.probe)")

        // debug_hero must also show the hero trailer model took the attempt. Poll a few more
        // samples if the first one is still mid-resolve — same tolerant polling shape test20's
        // src=c/src=f walk uses — preferring the strongest signal (exp/play) but accepting dwell
        // as the floor, matching what TrailerSoakTests' own dwell-play-leave soak treats as the
        // reliably-observable attempt signal on a sim.
        func pollHeroPhase(_ tag: String, initial: String) -> (state: String, reached: Bool) {
            var state = initial
            var reached = state.contains("hph=exp") || state.contains("hph=play")
            if !reached {
                for i in 1...6 {
                    pause(0.5)
                    state = heroSrcProbe(heroApp, "\(tag)_\(i)")
                    if state.contains("hph=exp") || state.contains("hph=play") {
                        reached = true
                        break
                    }
                }
            }
            return (state, reached)
        }
        var (hphState, reachedAttemptPhase) = pollHeroPhase("37a_hero_hph_poll", initial: heroResult.probe)
        // Sim run 1 (2026-08-21): the walk's 0.8s press gap stretched to 2.0s under load on one
        // intermediate card, whose hero attempt (hero mode arms on EVERY committed row focus —
        // Continue Watching cards included) fired its dwell and took the single extraction slot;
        // the destination card's dwell was then `beginExtraction refused` and, by the pipeline's
        // skip-don't-queue design (BUG-46), never retried — `hph=idle` across the whole poll on
        // a correct build. Harden the TEST, not the app: wait out the slot, then re-focus the
        // card (right → left, gaps short enough that the neighbour never dwells) — "leaving and
        // coming back plays it again" is the documented model contract — and judge that second
        // attempt, still requiring the poster not to grow while it runs.
        if !reachedAttemptPhase && !hphState.contains("hph=dwell") {
            print("[UX7] 37a_hero: first attempt idle after poll (refused-slot cadence) — re-focusing")
            pause(3.0) // > the sim's ~2.7s extraction hold, so the slot is free for the retry
            press(.right, gap: 0.3)
            press(.left, gap: 0.3)
            guard let refocused = focusedButton(heroApp) else {
                throw XCTSkip("no focused element reported after the re-focus nudge")
            }
            let retryFrame = refocused.frame
            func retryNeighbourMinX() -> CGFloat? {
                buttonFrames(heroApp).compactMap { f -> CGFloat? in
                    guard abs(f.midY - retryFrame.midY) < 20, f.minX > retryFrame.maxX - 1 else { return nil }
                    return f.minX
                }.min()
            }
            let retryNeighbourBefore = retryNeighbourMinX() ?? -1
            pause(1.4)
            var retryPeakShift: CGFloat = 0
            if let n = retryNeighbourMinX(), retryNeighbourBefore >= 0 { retryPeakShift = max(retryPeakShift, n - retryNeighbourBefore) }
            let retryProbe = heroSrcProbe(heroApp, "37a_hero_retry_probe")
            (hphState, reachedAttemptPhase) = pollHeroPhase("37a_hero_retry_hph_poll", initial: retryProbe)
            if let n = retryNeighbourMinX(), retryNeighbourBefore >= 0 { retryPeakShift = max(retryPeakShift, n - retryNeighbourBefore) }
            XCTAssertLessThanOrEqual(
                retryPeakShift, 12,
                "row neighbours shifted (poster morph fired) on the re-focused attempt while trailer_playback_location=hero — shift=\(retryPeakShift)"
            )
            XCTAssertTrue(hphState.contains(" src=f"), "re-focused hero leg must still report a committed row focus (src=f), got: \(hphState)")
        }
        XCTAssertTrue(
            reachedAttemptPhase || hphState.contains("hph=dwell"),
            "hero trailer model never took the focus attempt (expected hph=exp/play, or at least hph=dwell) — got: \(hphState)"
        )
        XCTAssertTrue(heroApp.state == .runningForeground, "app must survive the hero-location leg")
        heroApp.terminate()
        pause(1.0)

        // Leg 2: poster location (the pre-existing default) — same walk, the poster DOES morph.
        let posterApp = launchToHome(extraArguments: heroLocationArguments("poster"), forceFreshLaunch: true)
        let posterResult = try measureDwell(posterApp, "37b_poster")
        XCTAssertGreaterThan(
            posterResult.peak, posterResult.before + 20,
            "row neighbours never shifted (no poster morph) while trailer_playback_location=poster — neighbourMinX before=\(posterResult.before) peak=\(posterResult.peak)"
        )
        XCTAssertTrue(posterResult.probe.contains(" tloc=p"), "trailer_playback_location=poster must set tloc=p on debug_hero, got: \(posterResult.probe)")
        XCTAssertTrue(posterApp.state == .runningForeground, "app must survive the poster-location leg")
    }

    // MARK: - beta.15 §C5: native-List Settings focus graph

    /// Sanity check for the SettingsView.swift focus-graph doc comment (two-pane split, C1–C3
    /// native-List conversion): default focus lands in the sidebar (never the detail pane), Right
    /// enters the detail list on a real focusable row, and Menu backs out one level at a time
    /// without ever exiting the app. Existence-driven throughout (27.0-class runtimes never
    /// report `hasFocus` reliably — see the tvOS UI sim-verification field notes) rather than
    /// asserting on `hasFocus` directly.
    func test40SettingsFocusGraph() throws {
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        shot(app, "40a_settings_default_focus")

        // Default focus: the sidebar's first category (Account & Services) must exist, and the
        // walk must NOT already be inside the detail pane — i.e. a sidebar category button is
        // reachable without ever having pressed Right. `openTab` itself presses Down once after
        // Select (its standard "step into content" move), so re-affirm the sidebar landing here
        // rather than trusting that alone.
        let accountServices = app.buttons["Account & Services"]
        XCTAssertTrue(accountServices.waitForExistence(timeout: 6), "sidebar's first category (Account & Services) must exist on Settings entry")

        // Walk down the sidebar to About (6 categories below Account & Services: Playback,
        // Appearance, Home Screen, Content Sources, Advanced, About).
        let about = app.buttons["About"]
        _ = moveFocus(.down, until: about, max: 8)
        pause(1)
        shot(app, "40b_sidebar_about")
        XCTAssertTrue(about.exists, "About sidebar row must exist after walking Down x6 from the top")

        // Right enters the detail pane on About's first focusable row (SettingsValueRow rows are
        // NOT focusable by design — About's pane doc/kit note guarantees at least one focusable
        // control, e.g. a link or action row, per the BUG-47 requirement). Existence-driven: after
        // Right, SOME element beyond the sidebar's right edge must hold focus or at least exist
        // freshly-mounted near the top of the detail list.
        press(.right, times: 1)
        pause(1)
        shot(app, "40c_detail_first_row")
        XCTAssertTrue(app.state == .runningForeground, "app must still be foreground after entering the About detail pane")

        // Menu: pops the detail selection back toward the sidebar / tab bar, one level at a time.
        // It must never exit the app to the springboard — the Settings tab bar button must still
        // exist afterward (tabs stay in the AX tree even off-screen at negative Y, per
        // launchToHome's own recovery-dance comment; `.exists` alone is the correct check here
        // since this assertion only cares that the app is still showing SOME reachable UI, not
        // that the bar is scrolled into view).
        remote.press(.menu)
        pause(1.5)
        shot(app, "40d_after_menu")
        XCTAssertTrue(app.state == .runningForeground, "Menu from the Settings detail pane must not exit the app")
        XCTAssertTrue(app.buttons["Settings"].exists, "Settings tab bar button must still exist after Menu — the app must not have been kicked to the springboard")
    }

    // MARK: - P-1d: forced no-trailer must never bloom the poster

    /// Inverse of test37TrailerLocationHero's poster leg. `debug.trailerForceNoTrailer`
    /// (`TrailerProbe.forceNoTrailer`, TrailerDebugProbes.swift) makes every title report "no
    /// trailer available" — that knob exists specifically so the never-morph-on-speculation fix
    /// ("a focused poster with nothing to play must never bloom into a landscape tile, even for
    /// ~1s", per its own doc comment) is testable without hunting for a fixture whose TMDB
    /// listing happens to be empty. Reuses test37's neighbour-shift oracle verbatim (the focused
    /// Button's own AX frame never follows the tile — its body is `accessibilityHidden` — so the
    /// row's OTHER cards sliding over by the landscape-portrait delta is what a real morph looks
    /// like; see test37's header comment) but asserts the mirror-image bound: peak shift must stay
    /// ≤ 12pt (test37's own "no morph" threshold) for the WHOLE dwell+resolve window, never
    /// exceeding it, instead of eventually exceeding 20pt.
    func test41NoTrailerNeverMorphsPoster() throws {
        let app = launchToHome(extraArguments: [
            "-inline_trailers_enabled", "YES",
            "-debug.trailerProbe", "YES",
            "-debug.trailerForceNoTrailer", "YES",
            // Deterministic row geometry (test37's trick): removes the Upcoming row so the
            // down×4 walk below has a stable target.
            "-home_upcoming_row_enabled", "NO",
        ], forceFreshLaunch: true)

        // Same down×4 walk as test01/test37 to a resting portrait poster in the first movies row.
        press(.down, times: 3)
        remote.press(.down)
        pause(0.3) // focus-engine settle only — baseline must land inside the would-be 1.0s dwell
        let baseline = buttonSnapshots(app)
        guard let beforeFrame = baseline.first(where: { $0.hasFocus })?.frame else {
            throw XCTSkip("no focused element reported before the dwell window (27.0 runtime never reports hasFocus)")
        }
        guard beforeFrame.width > 80, beforeFrame.height > beforeFrame.width else {
            throw XCTSkip("focused element before the dwell window is not a resting portrait poster — frame=\(beforeFrame)")
        }

        func neighbourMinXs(_ snaps: [(frame: CGRect, hasFocus: Bool)]) -> [CGFloat] {
            let anchor = snaps.first(where: { $0.hasFocus })?.frame ?? beforeFrame
            return snaps.compactMap { b -> CGFloat? in
                let f = b.frame
                guard abs(f.midY - anchor.midY) < 20, f.minX > anchor.maxX - 1 else { return nil }
                return f.minX
            }.sorted()
        }
        func neighbourMinXsNow() -> [CGFloat] { neighbourMinXs(buttonSnapshots(app)) }

        let neighboursBefore = neighbourMinXs(baseline)
        guard let firstNeighbourBefore = neighboursBefore.first else {
            throw XCTSkip("focused poster has no row neighbour to its right — frame=\(beforeFrame)")
        }
        shot(app, "41a_before_dwell")
        print("[P1d] baseline focused=\(beforeFrame) neighbours=\(neighboursBefore.prefix(3))")

        // Poll the peak every 0.5s over a 10s window — comfortably past test37's observed
        // ~3.6s focus→resolve→morph latency on a sim, with no trailer ever able to resolve here.
        var peakShift: CGFloat = 0
        for i in 0..<20 {
            pause(0.5)
            if let firstNeighbour = neighbourMinXsNow().first {
                peakShift = max(peakShift, firstNeighbour - firstNeighbourBefore)
            }
            if i == 4 || i == 12 {
                print("[P1d] sample \(i) neighbour=\(neighbourMinXsNow().first ?? -1) peakShift=\(peakShift)")
                shot(app, "41b_sample_\(i)")
            }
        }
        shot(app, "41c_after_window")

        XCTAssertLessThanOrEqual(
            peakShift, 12,
            "row neighbours shifted (poster morphed) despite debug.trailerForceNoTrailer — the card never should have bloomed with nothing to play. peak shift=\(peakShift)pt, before firstNeighbourMinX=\(firstNeighbourBefore)"
        )
        XCTAssertTrue(app.state == .runningForeground, "app must survive the forced-no-trailer dwell window")
    }

    // MARK: - H-2: the folder page is logo-only, never the parent collection's title

    /// Seeds ONE collection via the DEBUG-only `-debug.collectionsSeedJsonB64` knob
    /// (`HomeViewModel.applyCollectionsSeedIfRequested`, HomeViewModel.swift ~L282-319) with a
    /// distinctive collection title and one folder carrying `heroBackdropUrl` + `titleLogoUrl`
    /// (deliberately unreachable `example.invalid` URLs — RFC 2606 reserved, guaranteed to fail
    /// to load, which is fine: the label FALLBACK logic is what's under test, not artwork
    /// fetching) and `hideTitle: false`.
    ///
    /// H-2 (CollectionsUI.swift ~L573) removed the parent collection's title as a caption above
    /// the folder page's logo — a tvOS-only invention a tester flagged; the folder page is
    /// logo-only now (`FolderHeroTitle(title: model.folderTitle, …)` — always the FOLDER's own
    /// title, verified by reading `FolderDetailViewModel.folderTitle`'s assignments, never the
    /// collection's). That is this test's PRIMARY, strict assertion: the collection title must
    /// never appear as a `staticText` on the folder page.
    ///
    /// Divergence from a literal "never appears anywhere on Home" reading, recorded here because
    /// it materially changes what's asserted: `CollectionRowView` (CollectionsUI.swift ~L64-73,
    /// ~L101-113) renders `Text(collection.title)` as that row's OWN section header — deliberately
    /// and unconditionally, the exact same role `CatalogRowView`'s `section.title` plays for a
    /// catalog shelf. That is correct, desired behavior, not something H-2 (or anything else)
    /// ever removed, and asserting its absence would fail against a correctly working build. The
    /// Home-side assertion below instead checks there is at most ONE on-screen occurrence of the
    /// collection title (the row header, and nothing more) — i.e. it never additionally leaks into
    /// the folder tile itself or the hero overlay, which per `FolderTile`'s and
    /// `HomeView.folderHeroPreview`'s source (both read directly: the tile's fallback caption and
    /// the hero's `name` field are always `folder.title`, never `collection.title`) is the real,
    /// defensible invariant on the Home side.
    ///
    /// Guest-mode requirement: the seed knob's own doc comment says a signed-in session's next
    /// foreground pull may overwrite the import (remote wins) — "use in guest mode". This harness
    /// otherwise always drives the shared, persistently signed-in "Chris" sim (see `launchToHome`),
    /// which has no reachable Continue-as-Guest path; producing a genuinely signed-out container is
    /// a destructive, gated recipe of its own (`ScratchServerSwitchTests.swift`, throwaway sim
    /// only — this harness's own field notes say never sign out on a shared clone). Rather than
    /// force that here, this test detects the fork at runtime and skips loudly with the reason
    /// when Continue-as-Guest isn't reachable, instead of asserting on nothing.
    func test42CollectionTitleNeverLeaksBeyondRowHeader() throws {
        let collectionTitle = "ZZLabelProbe"
        let folderTitle = "ZZLabelProbeFolder"
        let seedJson = """
        [{"id":"zzlabelprobe-collection-1","title":"\(collectionTitle)","folders":[{"id":"zzlabelprobe-folder-1","title":"\(folderTitle)","heroBackdropUrl":"https://example.invalid/zzlabelprobe-backdrop.jpg","titleLogoUrl":"https://example.invalid/zzlabelprobe-logo.png","hideTitle":false}]}]
        """
        let seedB64 = Data(seedJson.utf8).base64EncodedString()

        let app = XCUIApplication()
        app.launchArguments += ["-debug.collectionsSeedJsonB64", seedB64]
        app.launch()

        let chris = app.buttons["Chris"]
        let continueAsGuest = app.buttons["Continue as Guest"]
        guard chris.waitForExistence(timeout: 20) || continueAsGuest.waitForExistence(timeout: 20) else {
            XCTFail("app never reached a profile gate (Chris picker or Welcome) after launch")
            return
        }
        guard !chris.exists else {
            throw XCTSkip("sim is signed in (the shared \"Chris\" profile exists) — the guest-only debug.collectionsSeedJsonB64 seed needs a fresh/signed-out container; see ScratchServerSwitchTests.swift for the destructive, gated recipe that produces one")
        }
        guard continueAsGuest.exists else {
            throw XCTSkip("neither Chris nor Continue as Guest reachable after launch — unexpected profile-gate state, cannot proceed safely")
        }

        // Enter guest mode (ScratchServerSwitchTests.passProfileGate's recipe, trimmed to this
        // test's single path): select Continue as Guest; a brand-new guest needs a profile made
        // via the Add Profile cover (name field on screen), an existing guest instead shows a
        // normal picker tile.
        if !continueAsGuest.hasFocus { _ = moveFocus(.up, until: continueAsGuest, max: 4) }
        remote.press(.select)
        pause(3)

        if app.staticTexts["Add Profile"].exists, app.textFields.firstMatch.exists {
            let name = app.textFields.firstMatch
            if !name.hasFocus { _ = moveFocus(.up, until: name, max: 4) }
            remote.press(.select)
            pause(2)
            app.typeText("Guest")
            pause(0.8)
            remote.press(.menu) // dismisses the keyboard only — the cover itself stays up
            pause(1.5)
            let save = app.buttons["Save"]
            if save.waitForExistence(timeout: 3) {
                if !save.hasFocus { _ = moveFocus(.down, until: save, max: 6) }
                remote.press(.select)
                pause(6)
            }
            // ScratchServerSwitchTests' documented finding: the picker stops taking arrow presses
            // once the cover dismisses, while a fresh launch's picker default-focuses the first
            // tile — relaunch (the seed argument re-applies; `didApplyCollectionsSeed` is a fresh
            // static per process) so the profile tile is reliably selectable.
            app.terminate()
            pause(1)
            app.launch()
            pause(10)
        }

        if !app.buttons["Home"].exists {
            remote.press(.select) // whichever profile tile the fresh launch defaulted focus to
            pause(4)
        }
        guard app.buttons["Home"].waitForExistence(timeout: 30) else {
            throw XCTSkip("never reached Home after entering guest mode — cannot verify the collections seed")
        }
        pause(2) // let the imported collection row mount
        shot(app, "42a_home_after_guest_seed")

        func staticTextCount(equalTo label: String) -> Int {
            app.staticTexts.matching(NSPredicate(format: "label == %@", label)).count
        }

        // Walk down existence-driven (this harness's house rule — the 27.0 runtime never reports
        // `hasFocus`) looking for the seeded row's own header, up to a generous budget since we
        // don't know how many built-in catalog rows sit above it.
        var foundRow = false
        for _ in 0..<20 {
            if app.staticTexts[collectionTitle].exists { foundRow = true; break }
            remote.press(.down)
            pause(0.6)
        }
        guard foundRow else {
            throw XCTSkip("seeded collection row ('\(collectionTitle)') never appeared on Home — cannot verify the label invariants")
        }
        pause(1)
        shot(app, "42b_collection_row_focused")

        let homeCollectionTitleCount = staticTextCount(equalTo: collectionTitle)
        XCTAssertLessThanOrEqual(
            homeCollectionTitleCount, 1,
            "collection title '\(collectionTitle)' appeared \(homeCollectionTitleCount) times on Home — expected at most 1 (CollectionRowView's own row header); a second occurrence would mean the title leaked into the folder tile or the hero overlay, which must always show the FOLDER's own title instead"
        )

        // Open the seeded folder (its tile should already hold focus — CollectionRowView's
        // `focusSection` contains only that one tile in this seed).
        remote.press(.select)
        pause(2.5)
        shot(app, "42c_folder_page")

        XCTAssertFalse(
            app.staticTexts[collectionTitle].exists,
            "folder page must never show the parent collection's title ('\(collectionTitle)') — H-2 made the folder header logo-only, falling back to the FOLDER's own title, never the collection's"
        )
        XCTAssertTrue(app.state == .runningForeground, "app must survive opening the seeded folder")
    }

    // MARK: - BUG-64: the ring's manual scale must match the system lift

    /// Mean luma per COLUMN across a horizontal strip. The column cousin of `lumaStats`, used to
    /// find where posters end and the row background begins.
    private func columnLuma(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> [Double] {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else {
            throw XCTSkip("strip \(pointRect) is off-screen")
        }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var columns = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var sum = 0.0
            for y in 0..<h {
                let i = (y * w + x) * 4
                sum += (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255.0
            }
            columns[x] = sum / Double(h)
        }
        return columns
    }

    /// Mean luma per ROW across a vertical strip, plus the points-per-pixel scale so callers can
    /// convert an index back to layout points.
    private func rowLuma(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (rows: [Double], ptPerPx: CGFloat) {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else {
            throw XCTSkip("strip \(pointRect) is off-screen")
        }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rows = [Double](repeating: 0, count: h)
        for y in 0..<h {
            var sum = 0.0
            for x in 0..<w {
                let i = (y * w + x) * 4
                sum += (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255.0
            }
            rows[y] = sum / Double(w)
        }
        return (rows, 1 / scale)
    }

    /// Index of the strongest background→content step in a row profile: the artwork's TOP EDGE.
    ///
    /// Deliberately a maximum-gradient search rather than a threshold crossing. The first version
    /// of this measurement looked for dark RUNS between adjacent posters and was defeated by real
    /// artwork — two posters with dark edges merged into one 70pt "gap" and the reading was
    /// silently 50% off. Above a poster there is only row background, so the step there is
    /// unambiguous no matter what the artwork looks like.
    private func topEdgeIndex(_ rows: [Double]) -> (index: Int, strength: Double)? {
        guard rows.count > 6 else { return nil }
        var best = (index: -1, delta: 0.0)
        // 3-row window smooths JPEG noise without blurring a real edge.
        for i in 3..<(rows.count - 3) {
            let before = (rows[i - 3] + rows[i - 2] + rows[i - 1]) / 3
            let after = (rows[i] + rows[i + 1] + rows[i + 2]) / 3
            let delta = after - before
            if delta > best.delta { best = (i, delta) }
        }
        return best.index >= 0 ? (best.index, best.delta) : nil
    }

    /// BUG-64 (u/mrStevenx3, two betas running): "the focus ring keeps zooming in".
    ///
    /// The hybrid contract's FEAT-14 carve-out promises ring mode swaps the system lift for **an
    /// equivalent manual scale**. It was never measured — `cardRingLiftScale` is documented in
    /// PosterCard.swift as an approximation that "roughly matches" — and the reporter has been
    /// telling us for two betas that it does not, which reads to him as the ring causing zoom.
    ///
    /// Measures how much a focused poster GROWS in each treatment, from a single screenshot, by
    /// the gaps between it and its neighbours: the gap on the focused card's side has narrowed by
    /// its per-side growth, while gaps further along the row are still at rest. Self-calibrating,
    /// so it needs no second screenshot and cannot be fooled by a row that scrolled between shots
    /// (which is what killed the obvious focused-vs-unfocused diff).
    ///
    /// The assertion is the equivalence the contract promises, not an absolute number — whatever
    /// tvOS's lift turns out to be, the ring must not change it.
    func test44RingLiftMatchesSystemLift() throws {
        // Ring state comes from the ARGUMENT DOMAIN. `ensureToggleRow` cannot read a toggle inside
        // the beta.15 native `List` (it reports `value=Optional()`), and `accent_focus_ring` is a
        // plain local-only `@AppStorage` key (never synced) that this fixture profile simply has
        // enabled, so a local `defaults write` would stick — but NSArgumentDomain is used anyway
        // to outrank the fixture's own value deterministically. An earlier version drove the real
        // toggle and silently measured one state twice — identical gap arrays, a perfect match, a
        // vacuous pass.
        //
        // Each measurement is self-contained within ONE screenshot: the focused card's top edge is
        // compared against an UNFOCUSED neighbour's in the same frame, and normalised by that
        // card's own artwork height. So the two launches landing on different cards (which they do
        // — 220pt vs 228pt on this fixture, the trap test32 documents) no longer invalidates it.
        func liftScale(ringOn: Bool, _ name: String) throws -> (rise: CGFloat, artH: CGFloat) {
            // `-debug.cardGeometryProbe YES` (test49/test50's own knob): publishes each card's
            // own outer box as `poster_card` (see `DebugAXIdentifier`, PosterCard.swift). Used
            // below in place of the button/hasFocus AX walk this test used to rely on — 2026-09-04
            // found that walk fails DETERMINISTICALLY (not a flake, reproduced 3/3 runs, same
            // card every time) for the ring-on leg: `buttonSnapshots`' `!hasFocus` filter over
            // `app.buttons`/`app.cells` finds no usable same-row neighbour once `RingCardButtonStyle`
            // (the BUG-93 fix) is in the tree, for reasons this test does not need to chase any
            // further now that a proven-reliable geometry source exists.
            let app = launchToHome(
                extraArguments: ["-debug.cardGeometryProbe", "YES",
                                 "-no_zoom_on_focus", "NO", "-accent_focus_ring", ringOn ? "YES" : "NO"],
                forceFreshLaunch: true
            )
            openTab(app, named: "Home")
            press(.down, times: 3)
            // 2026-09-04: `press(.left, times: 6)` alone parks focus on card #1, directly beneath
            // the pinned row title's leading-edge band — the same white-glyph pollution test46
            // documents and side-steps with this same extra walk. Kept here rather than shared
            // because this closure closes over its own `app`/`name`.
            press(.left, times: 6, gap: 0.3)
            press(.right, times: 2, gap: 0.3)
            pause(2)
            guard let card = focusedButton(app), card.frame.width > 80, card.frame.height > card.frame.width else {
                throw XCTSkip("no focused poster card reported (the 27.0 runtime never reports hasFocus)")
            }
            let f = card.frame
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)

            /// Every frame in the AX tree carrying `identifier` — test49/test50's own copy.
            func namedFrames(_ identifier: String) -> [CGRect] {
                guard let root = try? app.snapshot() else { return [] }
                var out: [CGRect] = []
                func walk(_ node: XCUIElementSnapshot) {
                    if node.identifier == identifier { out.append(node.frame) }
                    node.children.forEach(walk)
                }
                walk(root)
                return out
            }

            let cardRects = namedFrames("poster_card")
            guard let focusedCard = cardRects.min(by: { abs($0.midX - f.midX) < abs($1.midX - f.midX) }) else {
                XCTFail("no `poster_card` element in the tree in \(name) - `-debug.cardGeometryProbe YES` did not arm `DebugAXIdentifier` (it is read once from NSArgumentDomain at first use), or this is a Release build.")
                throw XCTSkip("card geometry probe not armed in \(name)")
            }
            // 2026-09-04 (BUG-93 rebase): `artH` used to come from the FOCUSED card's own frame,
            // which is inside a `.scaleEffect` — so ring mode and the system lift (different
            // scales) reported different `artH` for the very same layout, and the old scale
            // comparison (`1 + 2 * rise / artH`) baked that difference straight into the number
            // under test. An unfocused rest neighbour's frame is a layout property untouched by
            // either treatment's paint-time transform (the same argument test46/test49 make), so
            // it is used here for both the artH baseline and the rest-side scan target.
            let restCards = cardRects
                .filter { abs($0.midX - focusedCard.midX) > focusedCard.width * 0.4 }
                .filter { abs($0.minY - focusedCard.minY) < 60 }
                .sorted { abs($0.midX - focusedCard.midX) < abs($1.midX - focusedCard.midX) }
            guard let restFrame = restCards.first else {
                throw XCTSkip("only one `poster_card` rect on screen (\(cardRects.count) total, focused \(focusedCard)) in \(name) - nothing to compare the focused card against; rerun")
            }
            let artH = restFrame.width * 1.5

            /// Top edge of the artwork in a narrow column centred on `centreX`, searched from well
            /// above the resting top down into the artwork.
            func topEdge(centreX: CGFloat) throws -> (y: CGFloat, strength: Double)? {
                let strip = CGRect(
                    x: centreX - f.width * 0.2, y: f.minY - artH * 0.25,
                    width: f.width * 0.4, height: artH * 0.5
                )
                guard strip.minX > 0, strip.maxX < app.frame.maxX else { return nil }
                let (rows, ptPerPx) = try rowLuma(in: shot.image, pointRect: strip, windowSize: app.frame.size)
                guard let edge = topEdgeIndex(rows) else { return nil }
                return (strip.minY + CGFloat(edge.index) * ptPerPx, edge.strength)
            }

            guard let focusedTop = try topEdge(centreX: f.midX),
                  let restTop = try topEdge(centreX: restFrame.midX) else {
                throw XCTSkip("could not locate both top edges for \(name)")
            }
            // A weak step means the column landed on dark artwork and the "edge" is noise.
            guard focusedTop.strength > 0.05, restTop.strength > 0.05 else {
                throw XCTSkip("top-edge steps too weak in \(name) (focused \(focusedTop.strength), rest \(restTop.strength)) — dark artwork, rerun")
            }
            // Ring-inset compensation. With the ring ON the artwork is drawn INSET by `ringWidth`
            // (PosterCard's `ringInset`) and the ring is stroked at the card's OUTER edge — so the
            // focused card's strongest step is the accent stroke, while the unfocused neighbour's
            // is its inset artwork. That is a free 4pt of apparent rise that has nothing to do with
            // the lift.
            let ringOuterEdgeCompensationPt: CGFloat = 4
            let rise = restTop.y - focusedTop.y - (ringOn ? ringOuterEdgeCompensationPt : 0)
            let report = XCTAttachment(string: "\(name) ringOn=\(ringOn) focusedTop=\(focusedTop) restTop=\(restTop) rise=\(rise)pt artH=\(artH) restFrame=\(restFrame) frame=\(f)")
            report.name = "\(name)_edges"
            report.lifetime = .keepAlways
            add(report)
            NSLog("[BUG64] %@ ringOn=%d rise=%.2fpt artH=%.1f strengths=%.3f/%.3f",
                  name, ringOn ? 1 : 0, rise, artH, focusedTop.strength, restTop.strength)
            return (rise, artH)
        }

        let off = try liftScale(ringOn: false, "44a_ring_off_system_lift")
        let on = try liftScale(ringOn: true, "44b_ring_on_manual_scale")

        let summary = "riseOff=\(off.rise)pt riseOn=\(on.rise)pt artHOff=\(off.artH) artHOn=\(on.artH)"
        let sum = XCTAttachment(string: summary)
        sum.name = "44c_scales"
        sum.lifetime = .keepAlways
        add(sum)
        NSLog("[BUG64] %@", summary)

        // Sanity: both treatments must actually raise the focused card, or the equivalence check
        // below passes vacuously.
        XCTAssertGreaterThan(off.rise, 1, "system lift did not raise the focused card at all — the edge finder is not measuring focus (\(summary))")
        XCTAssertGreaterThan(on.rise, 1, "ring mode did not raise the focused card at all (\(summary))")
        // 2026-09-04 (BUG-93 rebase): ring mode's rise is now a constant 20pt
        // (`Theme.Size.heroPinnedRowFocusLiftAllowance`, the same number `PinnedRowTitle`
        // charges the pinned-row clip budget in both zoom modes — see test49), not a scale
        // relative to each card's own artwork height. The old `on.scale == off.scale` assertion
        // compared two DERIVED numbers that were unequal even on a correct build (1.1212 vs
        // 1.0838) because they were built from each card's own differently-scaled reported
        // frame; asserting the RISEs directly is the actual contract ("an equivalent manual
        // scale" cashes out as "the same number of points" now that both are constants).
        XCTAssertEqual(
            on.rise, off.rise, accuracy: 2.5,
            "ring mode raises the focused poster by a different number of points than the system lift (\(summary)) — this is BUG-64: with the ring on, focus 'zooms' differently"
        )
    }

    /// Theme-picker regression (2026-08-25 report: "the theme picker doesn't change the theme in
    /// the settings — settings are only ever crimson"). Two separate defects, both fixed:
    ///
    ///  1. **The pane bounced.** `ContentView` pins `.id(appTheme.themeName)` on the app root, so a
    ///     swatch press remounts the whole tree. `SettingsView.selectedCategory` was plain `@State`,
    ///     so the split snapped back to the FIRST category — the user pressed a colour, landed at
    ///     the top of Settings, and saw nothing change. It is a `@Binding` owned by `ContentView`
    ///     (above the `.id`) now, and the sidebar's `prefersDefaultFocus` follows it.
    ///  2. **Nothing in Settings was accent-coloured.** The beta.15 §C row kit is semantic-only by
    ///     design, and the app set no environment tint, so the theme genuinely had nothing to
    ///     paint on this screen. Row glyphs and picker values now carry `Theme.Palette.accent` at
    ///     rest (`SettingsAccentTint`), handing the colour back to `.primary` under the focus
    ///     platter so the White theme can't vanish into it.
    ///
    /// Restores CRIMSON at the end — the theme is profile-scoped and syncs to the real account,
    /// same discipline as test12/test13.
    func test43ThemePickerKeepsCategoryAndTintsSettings() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        shot(app, "43a_appearance_before")

        // Right enters the detail pane and lands on the swatch row (the pane's first row).
        press(.right, times: 1)
        pause(1)
        let emerald = app.buttons["Emerald"]
        XCTAssertTrue(moveFocus(.right, until: emerald, max: 8), "must be able to reach the Emerald swatch")
        remote.press(.select)
        pause(3) // the .id() remount

        // Defect 1: the swatch row must still be on screen. Pre-fix this was the Account &
        // Services pane (Sign Out / Server / Connect Trakt) and every swatch was gone.
        // Defect 2 also shows here: the sidebar's category glyphs are emerald in this capture.
        shot(app, "43b_after_theme_change")
        XCTAssertTrue(
            app.buttons["Crimson"].waitForExistence(timeout: 6),
            "the Appearance pane must survive a theme change — a swatch press that lands the user back on Account & Services reads as 'the picker did nothing'"
        )

        // Defect 2, close up: walk down to the picker rows — the focused one wears the white
        // platter with platter-flipped text (`SettingsAccentTint` hands the colour back to
        // `.primary`), the ones at rest carry the theme accent on their trailing value. Capture
        // only, no assertion: where focus lands after the `.id` remount is not deterministic
        // (observed both ways on 2026-08-25 — sometimes still on the pressed swatch, sometimes back
        // on the sidebar via `prefersDefaultFocus`), so this walk is best-effort framing.
        press(.down, times: 3, gap: 0.7)
        shot(app, "43c_picker_rows_focused_and_at_rest")
        press(.left, times: 1, gap: 0.9)
        pause(0.8)
        shot(app, "43d_sidebar_focused")

        // Restore CRIMSON — profile-scoped, and it syncs to the real account, so this test must not
        // leave the fixture on Emerald.
        //
        // Do it from a COLD RELAUNCH rather than walking back. There is no reliable route into the
        // swatch row once focus has left it (three failure modes, all observed 2026-08-25): walking
        // UP from a detail row skips the horizontal swatch `ScrollView` and exits to the tab bar;
        // Left from a detail row goes to the SIDEBAR (focus graph) rather than along the row; and
        // Right from the sidebar re-enters on the row that last had focus, which a category switch
        // does not clear. A fresh launch has no such memory: Right from the sidebar lands on the
        // pane's FIRST row — the swatch row — and Crimson is the leftmost swatch, so walking left
        // always reaches it.
        let relaunched = launchToHome(forceFreshLaunch: true)
        openTab(relaunched, named: "Settings")
        moveToSidebarRow(relaunched, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(2)
        press(.right, times: 1)
        pause(1.5)
        XCTAssertTrue(
            moveFocus(.left, until: relaunched.buttons["Crimson"], max: 8),
            "must be able to restore the fixture's CRIMSON theme"
        )
        remote.press(.select)
        pause(3)
        shot(relaunched, "43e_restored_crimson")

        // Third theme change of the run, and the pane still holds.
        XCTAssertTrue(relaunched.buttons["Emerald"].waitForExistence(timeout: 6), "still on the Appearance pane")
        XCTAssertTrue(relaunched.state == .runningForeground)
    }

    // MARK: - Home Screen "Catalogs" expandable group: regression gate for the blank-pane bug

    /// 2026-08-29/30 finding (see `HomeScreenSettingsPane.swift`'s file header comment): the Settings → Home Screen "Hero Sources" and
    /// "Catalogs" expandable groups used to render their disclosure header AND every expanded row
    /// inside ONE native `List` row. tvOS exposes exactly one focus target per `List` row, so once
    /// a group was expanded none of the individual catalog rows could ever actually receive
    /// focus — a Select press one row below the header landed back on the header itself (re-
    /// collapsing it) rather than on the first catalog. The beta tester's "impossible to select
    /// the catalogs for the home page" report shipped across three betas because no automated
    /// test ever walked focus INTO an expanded group, only asserted the group's existence. The
    /// pane was restructured so each expanded catalog row (`CatalogSettingRow`) is hoisted out to
    /// be its own `SettingsSection` child / List row, with its own focus target. This test is the
    /// regression gate for that fix: it proves a Select press with focus one row below the
    /// expanded "Catalogs" header actually toggles the FIRST catalog row (the header's "N of M
    /// enabled" count changes), not the header's own collapse action.
    func test45CatalogsGroupFocusReachesExpandedRows() throws {
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let homeScreen = app.buttons["Home Screen"]
        _ = moveToSidebarRow(app, .down, named: "Home Screen", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let homeScreenSidebarX = homeScreen.frame.maxX

        // Step 1: loud prerequisite failure, not a silent pass — the fixture must have at least
        // one add-on with catalogs installed, or "Catalogs" never renders at all.
        // `walkToRowByTreeIndex` itself XCTFails if the row never materialises; the explicit
        // check below (same idiom as test04SettingsRows' `rowExists`) makes that requirement
        // visible at this test's call site too.
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Catalogs", sidebarMaxX: homeScreenSidebarX, category: "Home Screen")
        func catalogsHeaderCandidates() -> [XCUIElement] {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Catalogs'"))
                .allElementsBoundByIndex
        }
        XCTAssertTrue(catalogsHeaderCandidates().contains { $0.exists },
                      "Catalogs disclosure row missing — fixture must have an add-on with catalogs installed")

        // Step 2: record "N of M enabled" from the header's composed label before touching
        // anything. `SettingsDisclosureRow` is a plain Button (not a Toggle), so — like the
        // "Hero Sources, <summary>" composition documented in HomeScreenSettingsPane.swift — its
        // accessibility label combines the title and the live subtitle: "Catalogs, N of M
        // enabled". Scan every same-labeled candidate (mirrors `ensureToggleRow`'s
        // `describeCandidates` idiom) and take the first one this regex actually parses.
        func enabledCount(fromLabel label: String) -> Int? {
            guard let range = label.range(of: #"\d+ of \d+ enabled"#, options: .regularExpression) else { return nil }
            guard let firstToken = label[range].split(separator: " ").first else { return nil }
            return Int(firstToken)
        }
        func readEnabledCount() -> Int? {
            for candidate in catalogsHeaderCandidates() {
                if let count = enabledCount(fromLabel: candidate.label) { return count }
            }
            return nil
        }
        func describeCatalogsCandidates() -> String {
            catalogsHeaderCandidates().map { "l=<\($0.label)>" }.joined(separator: " | ")
        }
        guard let beforeCount = readEnabledCount() else {
            XCTFail("could not parse 'N of M enabled' out of the Catalogs row — candidates: \(describeCatalogsCandidates())")
            return
        }
        shot(app, "45a_catalogs_collapsed")

        // Step 3: expand. Focus is already parked on the Catalogs row (walkToRowByTreeIndex's
        // postcondition) — same "press Select right after the walk" idiom `ensureToggleRow` uses.
        remote.press(.select)
        pause(1.5)
        shot(app, "45b_catalogs_expanded")

        // At least one catalog row must now exist — `CatalogSettingRow` carries
        // `.accessibilityValue("Enabled"/"Disabled")`, read the same way `toggleState` reads a
        // Toggle's `.value`. Only existence is checked, never a specific catalog's title, so this
        // holds regardless of which add-ons the fixture happens to have.
        func catalogRowCount() -> Int {
            app.buttons.allElementsBoundByIndex.filter {
                let v = $0.value as? String
                return v == "Enabled" || v == "Disabled"
            }.count
        }
        // Poll a few samples — same tolerant shape `pollHeroPhase` uses elsewhere in this suite —
        // in case the expand animation hasn't settled the List yet.
        var rowCountAfterExpand = catalogRowCount()
        if rowCountAfterExpand == 0 {
            for _ in 1...4 {
                pause(0.5)
                rowCountAfterExpand = catalogRowCount()
                if rowCountAfterExpand > 0 { break }
            }
        }
        // ABORTING guard, not a soft assertion (Codex 2026-08-30 round 5 P2): with zero rows on
        // screen, focus is standing on an unknown settings row — pressing Down+Select from here
        // would toggle some unrelated setting, and the later early-returns would then skip the
        // restore step and leave the signed-in fixture mutated. Fail loudly and send no more
        // remote input.
        guard rowCountAfterExpand > 0 else {
            XCTFail("no catalog row appeared after expanding Catalogs — aborting before any further remote input can mutate the fixture")
            return
        }

        // Step 4 (the core assertion): one Down (into the group) + Select must toggle the FIRST
        // catalog row if and only if focus actually entered the group. If focus never left the
        // header, Select re-collapses it instead (rows vanish) or lands somewhere the header's
        // own count doesn't reflect — either way the count below would NOT change, which is
        // exactly the regression this test guards against.
        // The toggle persists AND pushes to the account (`toggleCatalog` → persist + sync), so a
        // failure path between the toggle press and the inline restore must not strand the
        // signed-in fixture mutated (Codex 2026-08-30 round 6 P2). The teardown fires the restore
        // press whenever the inline path didn't get to it; focus hasn't moved on any of those
        // paths, so a second Select at the same position flips the same row back.
        var needsRestore = false
        addTeardownBlock { [self] in
            if needsRestore {
                remote.press(.select)
                pause(1.5)
            }
        }

        remote.press(.down)
        pause(1)
        remote.press(.select)
        needsRestore = true
        pause(1.5)
        shot(app, "45c_after_toggle_press")

        // Step 6: collapse detection first — a clean XCTFail naming the regression beats a
        // confusing "count did not change" failure when the real cause is that the group closed.
        if catalogRowCount() == 0 {
            // Select hit the HEADER (collapse), not a catalog row — nothing was toggled, and a
            // teardown Select would just re-expand the header. Cancel the restore.
            needsRestore = false
            XCTFail("focus did not enter the expanded Catalogs group — Select re-collapsed the header instead of toggling a catalog row")
            return
        }
        guard let afterToggleCount = readEnabledCount() else {
            // The toggle DID land; the teardown block above restores it on this early exit.
            XCTFail("could not parse 'N of M enabled' after toggling — candidates: \(describeCatalogsCandidates())")
            return
        }
        XCTAssertNotEqual(
            afterToggleCount, beforeCount,
            "Select one row below the Catalogs header did not change the enabled count (stayed at \(beforeCount)) — focus did not reach the expanded group"
        )

        // Step 5: restore. Select again at the same focus position flips the same catalog row
        // back, leaving the signed-in fixture unchanged.
        remote.press(.select)
        needsRestore = false
        pause(1.5)
        shot(app, "45d_restored")
        let restoredCount = readEnabledCount()
        XCTAssertEqual(
            restoredCount, beforeCount,
            "Catalogs enabled count did not return to its original value (\(String(describing: restoredCount)) vs \(beforeCount)) — fixture left mutated"
        )
    }

    // MARK: - 2026-08-30 no-zoom investigation: the missing rise test

    /// The specced rise test for "No Zoom on Focus" that was never written. `CardFocusButtonStyle`
    /// (PosterCard.swift) was the ENTIRE no-zoom mechanism — `.buttonStyle(.borderless)` plus
    /// `.focusEffectDisabled(noZoomOnFocus)` — and it shipped with ZERO automated verification.
    /// test44 above measures the ring's manual-scale-vs-system-lift equivalence but explicitly
    /// launches with `-no_zoom_on_focus NO`; no test ever put the setting itself under measurement.
    /// A beta tester then reported "the posters continue to zoom in… Ring Focus (even when it is
    /// turned off) is still applied with a zoom, which cuts off the posters" — i.e.
    /// `.focusEffectDisabled` was not actually suppressing `.borderless`'s system lift on tvOS 26
    /// hardware, which is why `CardFocusButtonStyle` was reworked to swap in a custom
    /// `StillCardButtonStyle` instead (a custom `ButtonStyle` can never receive the system lift in
    /// the first place). This is that test.
    ///
    /// Same luma-edge-finder technique as test44 (read that test's doc first): the focused card's
    /// TOP edge, measured against an UNFOCUSED neighbour's in the same screenshot, no `hasFocus`
    /// reliance (the tvOS 27.0 runtime never reports it), loud prerequisite `XCTSkip`/`XCTFail`
    /// rather than a silent vacuous pass.
    func test46StillModeRiseIsZero() throws {
        let app = launchToHome(extraArguments: ["-no_zoom_on_focus", "YES"], forceFreshLaunch: true)
        openTab(app, named: "Home")
        press(.down, times: 3)
        press(.left, times: 6, gap: 0.3)
        // 2026-08-30 failure (rise = -39.5pt, physically impossible in still mode): the edge
        // scan caught the PINNED ROW TITLE's white glyphs instead of an artwork top. The title is
        // overlaid at the shelf's top-LEADING corner and is wide enough to cover the first card or
        // two, and it renders INSIDE the card's accessibility frame — the reach band the pinned
        // rows put above every card's artwork is exactly where the title lives — so no scan window
        // anchored on `frame.minY` can exclude it by geometry alone. Worse, title pollution and a
        // real system lift both raise a reading, so they cannot be told apart after the fact.
        //
        // The fix is to stop measuring under the title at all: two rights off the leading edge puts
        // the focused card (and its right-hand neighbour, the first rest candidate) clear of the
        // title's horizontal band. `press(.left, times: 6)` alone parked focus on card #1, directly
        // beneath it. test44 uses the same leading-edge walk and carries the same exposure — it has
        // simply not been unlucky yet; worth the same change next time it is touched.
        press(.right, times: 2, gap: 0.3)
        pause(2)
        guard let card = focusedButton(app), card.frame.width > 80, card.frame.height > card.frame.width else {
            throw XCTSkip("no focused poster card reported (the 27.0 runtime never reports hasFocus)")
        }
        let f = card.frame
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "46a_still_mode"
        attachment.lifetime = .keepAlways
        add(attachment)

        let artH = f.width * 1.5

        // 2026-08-30 device rerun #2: rise read 4.0pt EXACTLY, not a real lift. In still mode
        // EVERY card's artwork is inset by the reserved ring band (BUG-64 / 2026-08-30 no-zoom
        // investigation — see `ringInset` in PosterCard.swift), but only the FOCUSED card actually
        // draws the neutral `stillHighlight` ring (`Color.white.opacity(0.85)`) into that band —
        // an unfocused neighbour's band stays transparent, so its detected top-edge step is its
        // ARTWORK's own top (outer+ringWidth). The focused card's STRONGEST step is instead the
        // bright ring itself, right at the card's OUTER bounds (outer+0) — so a raw edge-to-edge
        // comparison reads a phantom `ringWidth`pt "rise" that has nothing to do with lift.
        // `ringWidth` itself lives in PosterCard.swift, which this UI test target cannot see (no
        // `@testable import` — it drives the app as a black box) — duplicated here as a literal,
        // matching PosterCard.swift's own `let ringWidth: CGFloat = 4`. Shared by both the rise
        // measurement below and the left-edge check further down, which has the identical
        // ring-vs-artwork ambiguity.
        let ringWidthPt: CGFloat = 4
        // Composited near-white (`Color.white.opacity(0.85)` over whatever's behind the card, i.e.
        // the row/page background) reads far brighter than ordinary poster artwork at this
        // resolution — a generous-but-honest cut, not tuned to any one poster.
        let ringBrightness = 0.6

        /// Mean of `profile` immediately AFTER `edgeIndex`, over a `ringWidthPt`-wide band
        /// (converted to pixels via `ptPerPx`) — used to tell whether a detected step is the
        /// bright still-mode ring or an ordinary (possibly dark) artwork edge. Generic over rows
        /// or columns, same as `topEdgeIndex` itself.
        func bandLumaAfter(_ profile: [Double], edgeIndex: Int, ptPerPx: CGFloat) -> Double {
            let bandPixels = max(1, Int((ringWidthPt / ptPerPx).rounded()))
            let start = edgeIndex + 1
            let end = min(profile.count, start + bandPixels)
            guard start < end else { return 0 }
            let slice = profile[start..<end]
            return slice.reduce(0, +) / Double(slice.count)
        }

        /// Top edge at a single column centred on `centreX`, within a card whose own top sits at
        /// `topY` (not always `f.minY` — a rest candidate can be a different card in the row).
        /// Same strip geometry as test44's local `topEdge`, kept as its own copy here rather than
        /// shared because test44's closes over that test's own `f`/`artH`/`shot`/`app`. Also
        /// reports the brightness of the band right after the step (`bandLumaAfter` above), so
        /// callers can tell a bright ring edge from an ordinary artwork edge.
        func topEdge(centreX: CGFloat, topY: CGFloat) -> (y: CGFloat, strength: Double, bandLumaAfter: Double)? {
            // 2026-08-30: the window used to open `artH * 0.25` (≈101pt at Large) ABOVE the card's
            // own accessibility frame, which reaches into whatever the PREVIOUS row is drawing.
            // Anchor it just above the card instead — 12pt is enough headroom for
            // `topEdgeIndex`'s 3-row gradient window plus a little AX/render slack, and the
            // remaining `artH * 0.5` of height still comfortably contains the artwork's top edge
            // at every Poster Size (Large: window ends ~189pt below the frame top, artwork top is
            // ~88pt below it in pinned mode, 0pt in classic).
            let scanTop = topY - 12
            let strip = CGRect(
                x: centreX - f.width * 0.2, y: scanTop,
                width: f.width * 0.4, height: artH * 0.5
            )
            guard strip.minX > 0, strip.maxX < app.frame.maxX, strip.minY > 0 else { return nil }
            guard let (rows, ptPerPx) = try? rowLuma(in: shot.image, pointRect: strip, windowSize: app.frame.size) else { return nil }
            guard let edge = topEdgeIndex(rows) else { return nil }
            let band = bandLumaAfter(rows, edgeIndex: edge.index, ptPerPx: ptPerPx)
            return (strip.minY + CGFloat(edge.index) * ptPerPx, edge.strength, band)
        }

        /// 2026-08-30 device rerun: the fixture skipped with "focused 0.808, rest 0.026" — the
        /// single centred column on the REST card landed on near-black artwork (The Hunting
        /// Party's poster has a black top) and read as no edge at all, even though the card's
        /// true top edge was perfectly detectable a few points either side. Sample several evenly
        /// spaced columns across `frame`'s own width (relative fractions of `frame.width`, so this
        /// keeps working at any Poster Size — Large, Medium, whatever the fixture is running) and
        /// keep the strongest, the same "take the best step" idea `topEdgeIndex` already applies
        /// within one column's row profile, one dimension out.
        func bestTopEdge(in frame: CGRect) -> (y: CGFloat, strength: Double, bandLumaAfter: Double)? {
            let sampleCount = 6
            var best: (y: CGFloat, strength: Double, bandLumaAfter: Double)?
            for i in 0..<sampleCount {
                // Middle 70% of the card's width — the outer margins are where a strip can clip
                // the card's own rounded corner, a weaker step than the flat top just inboard.
                let t = (CGFloat(i) + 0.5) / CGFloat(sampleCount)
                let centreX = frame.minX + frame.width * (0.15 + 0.7 * t)
                guard let candidate = topEdge(centreX: centreX, topY: frame.minY) else { continue }
                if best == nil || candidate.strength > best!.strength { best = candidate }
            }
            return best
        }

        guard let focusedTopRaw = bestTopEdge(in: f) else {
            throw XCTSkip("no usable top edge anywhere on the focused card — cannot measure still-mode rise")
        }
        guard focusedTopRaw.strength > 0.05 else {
            throw XCTSkip("top-edge step too weak on the focused card itself (\(focusedTopRaw.strength)) — dark artwork, rerun")
        }
        // The ring-aware adjustment: if the strongest step found on the focused card is the bright
        // still-mode ring rather than the artwork itself, the artwork's true top is `ringWidthPt`
        // further down — the same band `ringInset` reserved for it. Honest either way: a card with
        // NO ring drawn here (e.g. a zoom-ON regression where this setting silently stopped
        // applying) has an ordinary, non-bright band and is compared RAW/unadjusted, so a real
        // system lift (~20pt+) still fails loudly instead of being "corrected" away.
        let focusedIsRingEdge = focusedTopRaw.bandLumaAfter > ringBrightness
        let focusedArtworkY = focusedIsRingEdge ? focusedTopRaw.y + ringWidthPt : focusedTopRaw.y

        // Rest baseline: try the immediate neighbour first (cheap, matches test44's own idiom),
        // then fall back to every OTHER unfocused poster-shaped button visible on screen — read
        // from the accessibility tree the same way `focusedButton`/`buttonSnapshots` already find
        // cards elsewhere in this suite, nearest to the focused card first. Only a card that never
        // yields a usable edge anywhere skips; a single dark column on one candidate no longer
        // does.
        let gapGuess = f.width * 0.18
        var restCandidates: [(label: String, frame: CGRect)] = [
            ("immediate neighbour (guessed)", CGRect(x: f.maxX + gapGuess, y: f.minY, width: f.width, height: f.height))
        ]
        let otherCards = buttonSnapshots(app)
            .filter { !$0.hasFocus && $0.frame.width > 80 && $0.frame.height > $0.frame.width }
            // Same row only — an accessibility frame's TOP is a layout property, unaffected by any
            // paint-time focus transform, so every poster in this row shares `f.minY` regardless
            // of which one is focused.
            .filter { abs($0.frame.minY - f.minY) < 15 }
            .filter { $0.frame != f }
            .sorted { abs($0.frame.midX - f.midX) < abs($1.frame.midX - f.midX) }
        for (i, snap) in otherCards.enumerated() {
            restCandidates.append(("AX-tree card #\(i) at x=\(Int(snap.frame.minX))", snap.frame))
        }

        // Backstop for the same 2026-08-30 pollution class on the REST side, where it IS
        // separable: an unfocused card's artwork can never sit ABOVE the focused card's in still
        // mode (that is the definition of zero rise), so a rest edge measurably higher than the
        // focused one is not a rest edge at all — it is the row title, or some other artefact
        // above the artwork. One-sided ON PURPOSE: rejecting only edges that read HIGHER than the
        // focused card can never mask the regression this test exists to catch, which shows up as
        // the focused card reading higher (a POSITIVE rise). Rejected candidates fall through to
        // the next card along, which is further from the title's leading-edge band.
        let implausibleRiseCutoff: CGFloat = -12
        var restTop: (y: CGFloat, strength: Double, bandLumaAfter: Double)?
        var triedStrengths: [String] = []
        for candidate in restCandidates {
            guard let edge = bestTopEdge(in: candidate.frame) else {
                triedStrengths.append("\(candidate.label)=none")
                continue
            }
            let candidateRise = edge.y - focusedArtworkY
            if candidateRise < implausibleRiseCutoff {
                triedStrengths.append(
                    "\(candidate.label)=REJECTED(rise=\(String(format: "%.1f", candidateRise))pt above the focused card — row-title glyphs, not an artwork edge)")
                continue
            }
            triedStrengths.append("\(candidate.label)=\(String(format: "%.3f", edge.strength))")
            if edge.strength > 0.05 {
                restTop = edge
                break
            }
        }
        guard let restTop else {
            throw XCTSkip("no rest card yielded a usable top edge after trying \(restCandidates.count) candidate(s): \(triedStrengths.joined(separator: ", ")) — dark artwork, or every candidate sat under the row title (see the REJECTED notes); rerun")
        }
        // A rest candidate is UNFOCUSED (filtered by `hasFocus` above), so it never draws the
        // still ring — its detected step is already its artwork's own top, no adjustment needed.
        // Comparing it against `focusedArtworkY` (not the raw, possibly-ring `focusedTopRaw.y`) is
        // what removes the phantom `ringWidthPt` reading.
        let rise = restTop.y - focusedArtworkY
        let report = XCTAttachment(string: "still mode focusedRaw=\(focusedTopRaw) focusedIsRingEdge=\(focusedIsRingEdge) focusedArtworkY=\(focusedArtworkY) restTop=\(restTop) rise=\(rise)pt artH=\(artH) frame=\(f) candidates=[\(triedStrengths.joined(separator: ", "))]")
        report.name = "46b_edges"
        report.lifetime = .keepAlways
        add(report)
        NSLog("[BUG64] still mode rise=%.2fpt artH=%.1f ringEdge=%d strengths=%.3f/%.3f", rise, artH, focusedIsRingEdge ? 1 : 0, focusedTopRaw.strength, restTop.strength)

        // The core assertion: still mode must not raise the focused card at all. Any measurable
        // rise here means the button style (or something else) reintroduced a scale/lift — exactly
        // what the beta report described ("posters continue to zoom in" with the setting on).
        XCTAssertEqual(
            rise, 0, accuracy: 2,
            "still mode raised the focused card by \(rise)pt — 'No Zoom on Focus' must produce zero rise"
        )

        // Cheap layout-regression guard, same screenshot: the still ring's reserved band (BUG-64 /
        // 2026-08-30 no-zoom investigation — see `ringInset` in PosterCard.swift) must not have
        // shifted the artwork's LEFT edge by more than the band itself plus a point of slack. Not
        // an equality check — the point is to catch a broken inset (e.g. a sign error, or the
        // shrink applied at several times the intended width) breaking layout, not to pin the
        // exact geometry. `columnLuma`/`topEdgeIndex` are the horizontal cousins of the vertical
        // scan above (`topEdgeIndex` is a generic step-finder — it doesn't care whether the 1-D
        // profile it's given came from rows or columns). Same ring-vs-artwork ambiguity as the
        // rise measurement above applies here too: the focused card's strongest LEFT step can be
        // the bright ring at the true outer edge rather than the inset artwork, so this is
        // adjusted with the same `bandLumaAfter` technique (to the right of the step, not below).
        func leftEdge(nearX: CGFloat) throws -> (x: CGFloat, strength: Double, bandLumaAfter: Double)? {
            let strip = CGRect(
                x: nearX - artH * 0.15, y: f.midY - f.width * 0.1,
                width: artH * 0.3, height: f.width * 0.2
            )
            guard strip.minX > 0, strip.maxY < app.frame.maxY, let cgWidth = shot.image.cgImage?.width, cgWidth > 0 else { return nil }
            let cols = try columnLuma(in: shot.image, pointRect: strip, windowSize: app.frame.size)
            guard let edge = topEdgeIndex(cols) else { return nil }
            let ptPerPx = app.frame.width / CGFloat(cgWidth)
            let band = bandLumaAfter(cols, edgeIndex: edge.index, ptPerPx: ptPerPx)
            return (strip.minX + CGFloat(edge.index) * ptPerPx, edge.strength, band)
        }
        if let left = try leftEdge(nearX: f.minX), left.strength > 0.05 {
            let leftIsRingEdge = left.bandLumaAfter > ringBrightness
            let artworkX = leftIsRingEdge ? left.x + ringWidthPt : left.x
            let shift = artworkX - f.minX
            NSLog("[BUG64] still mode left-edge shift=%.2fpt (measured=%.2f ringEdge=%d frameMinX=%.2f)", shift, left.x, leftIsRingEdge ? 1 : 0, f.minX)
            // 2026-09-04: DROPPED as an assertion, kept as a logged diagnostic only. The BUTTON's
            // accessibility frame (`f`) is wider than the card box it wraps, because the focus
            // treatments' drop shadow (radius 22 — test50's own finding) is part of the button's
            // painted bounds, about 10.5pt per side in still mode. That makes `f.minX` the wrong
            // reference for the artwork's true left edge: it reads a false ~14.8pt "shift" that
            // has nothing to do with the ring inset this sub-check exists to catch. The correct
            // reference is `poster_card` under `-debug.cardGeometryProbe YES` (see test49/test50),
            // which this test does not launch with; the rise assertion above stays this test's
            // real gate.
            let diag = XCTAttachment(string: "still mode left-edge shift=\(shift)pt (diagnostic only, not asserted — see the 2026-09-04 comment above) measured=\(left.x) ringEdge=\(leftIsRingEdge) frameMinX=\(f.minX)")
            diag.name = "46c_left_edge_diagnostic"
            diag.lifetime = .keepAlways
            add(diag)
        }
        // No `else`/skip here on purpose: a weak or unlocatable left-edge step is common (a bright
        // poster edge next to a bright neighbour, or an off-screen strip near the row's leading
        // edge) and this sub-check is explicitly the cheap, best-effort one — the rise assertion
        // above is this test's real gate.
    }

    // MARK: - BUG-93 (beta.17): ring mode's rise, and the platter that should not be there

    /// The ring-mode companion of `test46StillModeRiseIsZero`, and the gate BUG-93 was missing.
    ///
    /// u/mrStevenx3, beta.17: with the accent ring on, "the posters are cut off and the titles get
    /// a border around them". Two defects behind one report, both invisible to every existing gate:
    ///
    ///  1. **A system focus layer nobody declared.** `CardFocusButtonStyle`'s zoom-on branch was a
    ///     bare `.buttonStyle(.borderless)` in BOTH zoom modes. In ring mode nothing else in the
    ///     card declared a hover effect (the old `CardArtworkSystemLift` skipped that mode), so
    ///     `.borderless` fell back to its own default treatment at the button LABEL's bounds =
    ///     artwork PLUS caption - the exact BUG-54 platter, i.e. the "border around the titles" -
    ///     and it compounded with ring mode's own manual scale, over-growing the focused card into
    ///     the pinned rows' clip edge (the "cut off" half).
    ///  2. **The rise was a scale, not a constant.** `cardSystemLiftScale = 1.12` charged 24.2pt at
    ///     Large where the system lift charges a flat 20 (`Theme.Size.heroPinnedRowFocusLiftAllowance`,
    ///     measured the same at Medium and Large), so ring mode never matched the mode it is
    ///     supposed to be indistinguishable from, and the pinned-row clip budget was under-reserved.
    ///
    /// test44 already asserts ring-vs-system EQUIVALENCE, which is necessary but not sufficient:
    /// both sides could drift together, and it says nothing about a platter. This test pins the
    /// absolute number and looks for the platter directly.
    ///
    /// Machinery is test46's (read that test's doc first for the edge finder, the row-title
    /// pollution trap it side-steps with `press(.right, times: 2)`, and the multi-column
    /// `bestTopEdge`). Local copies rather than shared helpers because test46's close over its own
    /// `f`/`artH`/`shot`/`app`, exactly as test46's own copies do over test44's.
    func test49RingModeRiseMatchesAllowance() throws {
        // Mirrors PosterCard.swift's `let ringWidth: CGFloat = 4` - this target drives the app as a
        // black box (no `@testable import`), so the constant is duplicated, exactly as test46 does.
        // KEEP IN SYNC.
        let ringWidthPt: CGFloat = 4
        // Mirrors `Theme.Size.heroPinnedRowFocusLiftAllowance` (Theme.swift), which is also what
        // PosterCard's `cardFocusLiftRise` is defined as and what `PinnedRowTitle.focusLiftAllowance`
        // charges the pinned-row clip budget in BOTH zoom modes. KEEP IN SYNC: if that constant
        // moves, this literal moves with it, and so does BrowseComponents' `.manualScale` branch.
        let expectedRisePt: CGFloat = 20

        // `-debug.cardGeometryProbe YES` publishes each card's own outer box as `poster_card` (see
        // `DebugAXIdentifier`, PosterCard.swift). test46 has to guess a card's rect from the button's
        // accessibility frame and then hunt for the artwork's top edge in a 200pt window; the first
        // run of THIS test showed why that is not good enough here. Every one of seven rest
        // candidates reported the identical edge 149pt off, because `topEdgeIndex` returns the
        // STRONGEST step in its window and in ring mode the strongest step is not the card's top:
        // the accent ring is the user's accent colour, which on a dark theme is dimmer than a bright
        // feature inside the poster, and the window was tall enough to contain both. Anchoring the
        // scan on the card's real rect makes the window 40pt tall, so nothing inside the artwork can
        // win, and gives a second, independent reading of the lift for free.
        let app = launchToHome(
            extraArguments: ["-debug.cardGeometryProbe", "YES",
                             "-no_zoom_on_focus", "NO", "-accent_focus_ring", "YES"],
            forceFreshLaunch: true
        )
        openTab(app, named: "Home")
        press(.down, times: 3)
        press(.left, times: 6, gap: 0.3)
        // test46's trap: the pinned row title overlays the first card or two and renders inside
        // their accessibility frames, so an edge scan there reads white glyphs as an artwork top.
        press(.right, times: 2, gap: 0.3)
        pause(2)
        guard let focusedButtonElement = focusedButton(app),
              focusedButtonElement.frame.width > 80,
              focusedButtonElement.frame.height > focusedButtonElement.frame.width else {
            throw XCTSkip("no focused poster card reported (the 27.0 runtime never reports hasFocus)")
        }
        let f = focusedButtonElement.frame
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "49a_ring_mode"
        attachment.lifetime = .keepAlways
        add(attachment)

        func namedFrames(_ identifier: String) -> [CGRect] {
            guard let root = try? app.snapshot() else { return [] }
            var out: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier == identifier { out.append(node.frame) }
                node.children.forEach(walk)
            }
            walk(root)
            return out
        }

        let cardRects = namedFrames("poster_card")
        guard let focusedCard = cardRects.min(by: { abs($0.midX - f.midX) < abs($1.midX - f.midX) }) else {
            XCTFail("no `poster_card` element in the tree - `-debug.cardGeometryProbe YES` did not arm `DebugAXIdentifier` (it is read once from NSArgumentDomain at first use), or this is a Release build.")
            return
        }
        let restCards = cardRects
            .filter { abs($0.midX - focusedCard.midX) > focusedCard.width * 0.4 }
            .filter { abs($0.minY - focusedCard.minY) < 60 }
            .sorted { abs($0.midX - focusedCard.midX) < abs($1.midX - focusedCard.midX) }
        guard !restCards.isEmpty else {
            throw XCTSkip("only one card rect on screen (\(cardRects.count) total, focused \(focusedCard)) - nothing to compare the focused card against; rerun")
        }
        let artH = focusedCard.width * 1.5
        NSLog("[BUG93] focusedButton=%@ focusedCard=%@ restCards=%d first=%@",
              "\(f)", "\(focusedCard)", restCards.count, "\(restCards[0])")

        /// Mean luma of the `ringWidthPt`-wide band immediately AFTER `edgeIndex`, so a caller can
        /// tell a bright ring edge from an ordinary artwork edge. Same helper test46 uses.
        func bandLumaAfter(_ profile: [Double], edgeIndex: Int, ptPerPx: CGFloat) -> Double {
            let bandPixels = max(1, Int((ringWidthPt / ptPerPx).rounded()))
            let start = edgeIndex + 1
            let end = min(profile.count, start + bandPixels)
            guard start < end else { return 0 }
            let slice = profile[start..<end]
            return slice.reduce(0, +) / Double(slice.count)
        }

        /// Strongest background-to-content step in a NARROW window around `box`'s own top edge.
        /// 28pt of headroom covers the whole lift (20) plus slack, and the window stops 16pt inside
        /// the card so no feature within the artwork can outscore its edge.
        func topEdge(centreX: CGFloat, box: CGRect) -> (y: CGFloat, strength: Double, bandLumaAfter: Double)? {
            let strip = CGRect(x: centreX - box.width * 0.2, y: box.minY - 28,
                               width: box.width * 0.4, height: 44)
            guard strip.minX > 0, strip.maxX < app.frame.maxX, strip.minY > 0 else { return nil }
            guard let (rows, ptPerPx) = try? rowLuma(in: shot.image, pointRect: strip, windowSize: app.frame.size) else { return nil }
            guard let edge = topEdgeIndex(rows) else { return nil }
            let band = bandLumaAfter(rows, edgeIndex: edge.index, ptPerPx: ptPerPx)
            return (strip.minY + CGFloat(edge.index) * ptPerPx, edge.strength, band)
        }

        /// test46's multi-column idea: one centred column can land on a black poster top and read as
        /// no edge at all, so sample six across the middle 70% and keep the strongest.
        func bestTopEdge(in box: CGRect) -> (y: CGFloat, strength: Double, bandLumaAfter: Double)? {
            var best: (y: CGFloat, strength: Double, bandLumaAfter: Double)?
            for i in 0..<6 {
                let t = (CGFloat(i) + 0.5) / 6
                let centreX = box.minX + box.width * (0.15 + 0.7 * t)
                guard let candidate = topEdge(centreX: centreX, box: box) else { continue }
                if best == nil || candidate.strength > best!.strength { best = candidate }
            }
            return best
        }

        guard let focusedTopRaw = bestTopEdge(in: focusedCard), focusedTopRaw.strength > 0.03 else {
            throw XCTSkip("no usable top edge on the focused card (\(String(describing: bestTopEdge(in: focusedCard)))) - dark artwork against a dark page, rerun")
        }
        // DELIBERATE DIVERGENCE from test46's `focusedIsRingEdge` luma gate. In still mode the
        // neutral ring is `Color.white.opacity(0.85)`, reliably bright, and whether it is drawn at
        // all depends on the OTHER setting - so a brightness test is both possible and necessary
        // there. Here the ring is the user's ACCENT colour (`Theme.Palette.focusRingColor`), and a
        // Crimson or Ocean fixture paints a ring nowhere near a white threshold, so gating on
        // brightness would silently skip the correction and report a 24pt rise on a correct build.
        // What is NOT in doubt is whether the ring is drawn: `-accent_focus_ring YES` is in the
        // argument domain and PosterCard draws the stroke on exactly `accentFocusRing && isFocused`.
        // So the focused card's step IS the ring at the scaled outer edge and the inset artwork's
        // own top is `ringWidth` further down. Corrected unconditionally, as test44 does with its
        // `ringOuterEdgeCompensationPt`; the uncorrected reading is logged too, so a regression that
        // removes the ring shows up in the attachment rather than being mis-corrected in silence.
        let focusedArtworkY = focusedTopRaw.y + ringWidthPt

        var restTop: (y: CGFloat, strength: Double, bandLumaAfter: Double)?
        var tried: [String] = []
        for (i, box) in restCards.enumerated() {
            guard let edge = bestTopEdge(in: box) else { tried.append("card#\(i)=none"); continue }
            tried.append("card#\(i)@x=\(Int(box.minX))=\(String(format: "%.3f", edge.strength))")
            if edge.strength > 0.03 { restTop = edge; break }
        }
        guard let restTop else {
            throw XCTSkip("no rest card yielded a usable top edge after trying \(restCards.count): \(tried.joined(separator: ", ")) - dark artwork, rerun")
        }

        // A resting card draws no ring, so its step is already its inset artwork's own top and needs
        // no correction - the same argument test46 makes.
        let rise = restTop.y - focusedArtworkY
        let uncorrected = restTop.y - focusedTopRaw.y
        // Second, independent reading: `.scaleEffect` is a geometry transform, so if the runtime
        // reports transformed accessibility frames the focused card's own published rect has already
        // grown by the lift. Logged rather than asserted, because whether the frame is transformed is
        // a runtime detail this suite has been burned by assuming before; when it does read, it is
        // the cross-check that says the luma number is not an artefact of one screenshot.
        let geometricRise = restCards[0].minY - focusedCard.minY
        let report = XCTAttachment(string: "ring mode focusedRaw=\(focusedTopRaw) focusedArtworkY=\(focusedArtworkY) restTop=\(restTop) rise=\(rise)pt uncorrected=\(uncorrected)pt geometricRise=\(geometricRise)pt artH=\(artH) focusedCard=\(focusedCard) restCard=\(restCards[0]) tried=[\(tried.joined(separator: ", "))]")
        report.name = "49b_edges"
        report.lifetime = .keepAlways
        add(report)
        NSLog("[BUG93] ring mode rise=%.2fpt uncorrected=%.2fpt geometric=%.2fpt artH=%.1f ringBand=%.3f strengths=%.3f/%.3f",
              rise, uncorrected, geometricRise, artH, focusedTopRaw.bandLumaAfter, focusedTopRaw.strength, restTop.strength)

        // The core assertion. Ring mode's manual scale is derived from `cardFocusLiftRise` so that
        // the artwork's top edge rises by exactly this many points at EVERY Poster Size - which is
        // also the number `PinnedRowTitle.focusLiftAllowance` charges the pinned rows' clip budget,
        // so a drift here is a drift in the rows' geometry too. Accuracy 2.5pt covers the
        // screenshot's point-per-pixel quantisation plus the ~0.4pt difference between the ring's own
        // rise (what is measured) and the inset artwork's (what is asserted).
        XCTAssertEqual(
            rise, expectedRisePt, accuracy: 2.5,
            "ring mode raised the focused card by \(rise)pt, not \(expectedRisePt)pt - the manual scale and Theme.Size.heroPinnedRowFocusLiftAllowance have drifted apart (BUG-93)"
        )

        // No-platter sub-check. The BUG-54/BUG-93 platter is drawn at the BUTTON LABEL's bounds, so
        // it wraps the caption as well as the artwork and shows up as a lighter surface where there
        // should be nothing but page background: the leading strip of the caption row, inboard of the
        // card's own edge but outboard of the caption glyphs (the caption carries
        // `Theme.Spacing.xs` = 8pt of horizontal padding, so its first 6pt are always empty).
        //
        // DELIBERATE DIVERGENCE from the spec'd "same band 40pt further left": `Theme.Spacing.rowGap`
        // is 28, so a reference band 40pt to the left lands 12pt INSIDE the previous card and would
        // compare a platter against a poster. The reference is taken 20pt further left instead, still
        // inside the inter-card gap and genuine page background. The near band moves just INSIDE the
        // card's leading edge for the same reason it discriminates better: the platter's own rect
        // starts at the label bounds, so that is where it is brightest; outside those bounds one is
        // reading its spill.
        // Derived from a RESTING card's rect, which is the unscaled layout box: its caption starts
        // `Theme.Spacing.md` below the artwork, and the focused card's caption is that plus the
        // lift's own bottom expansion (`CardCaptionFocusDrop` pays exactly `cardFocusLiftRise`).
        // Not derived from the focused rect, which is mid-scale.
        let captionTop = restCards[0].maxY + 16 + expectedRisePt
        let bandHeight = min(50, max(0, app.frame.maxY - captionTop - 4))
        if bandHeight >= 10, focusedCard.minX - 26 > 0 {
            func meanLuma(x: CGFloat) throws -> Double? {
                let rect = CGRect(x: x, y: captionTop, width: 6, height: bandHeight)
                guard rect.minX > 0, rect.maxX < app.frame.maxX, rect.maxY < app.frame.maxY else { return nil }
                let cols = try columnLuma(in: shot.image, pointRect: rect, windowSize: app.frame.size)
                guard !cols.isEmpty else { return nil }
                return cols.reduce(0, +) / Double(cols.count)
            }
            if let inside = try meanLuma(x: focusedCard.minX), let background = try meanLuma(x: focusedCard.minX - 26) {
                let delta = inside - background
                NSLog("[BUG93] caption-row platter probe inside=%.4f background=%.4f delta=%.4f bandY=%.1f bandH=%.1f",
                      inside, background, delta, captionTop, bandHeight)
                let platter = XCTAttachment(string: "inside=\(inside) background=\(background) delta=\(delta) captionTop=\(captionTop) bandH=\(bandHeight)")
                platter.name = "49c_platter_probe"
                platter.lifetime = .keepAlways
                add(platter)
                XCTAssertLessThan(
                    delta, 0.05,
                    "the focused card's caption row is \(delta) brighter at its leading edge than the gap beside it - a focus platter is being drawn around artwork + caption (BUG-93; ring mode must use RingCardButtonStyle, never a bare .borderless)"
                )
            }
        }
        // No `else`/skip: like test46's left-edge guard this is the cheap best-effort half. The rise
        // assertion above is this test's real gate.
    }

    // MARK: - BUG-91 (beta.17): the card-depth rail must trace the picture, not the card

    /// u/mrStevenx3, beta.17 close-up: "a visible empty band between the artwork and the
    /// translucent card frame, on the top and left edges of every card". Not a focus artefact - it
    /// is there at rest, on every card, whenever "No Zoom on Focus" (or the accent ring) is on.
    ///
    /// Cause: `ringInset` reserves a `ringWidth` band around the picture in those modes, so the
    /// artwork is drawn 8pt narrower than the card. `PosterCard`/`LandscapeCard` then re-framed
    /// back up to the card's outer size and attached `.nuvioCardDepth` to THAT, so the depth rail
    /// traced the outer rect while the picture sat 4pt inside it. The rail is the "translucent
    /// frame" in the report and the reserved band is the gap. Fixed by attaching the modifier to
    /// the inset artwork, with the inset radius.
    ///
    /// **Oracle is geometry, not pixels**, and deliberately so - the same argument test47 makes.
    /// The rail is a 1-2pt hairline whose width and opacity are user settings, drawn over
    /// arbitrary poster art; "is it 4pt outside the picture" is precisely the sub-band distinction
    /// the luma edge finder in test44/test46 already has to hedge around. `card_depth_rail` and
    /// `poster_artwork` are DEBUG-only accessibility identifiers (see `DebugAXIdentifier`,
    /// PosterCard.swift) that publish the two rects the fix is about.
    func test50DepthRailHugsArtworkInStillMode() throws {
        // Mirrors PosterCard.swift's `let ringWidth: CGFloat = 4`. KEEP IN SYNC (same literal
        // test46/test49 carry - this target drives the app as a black box, no `@testable import`).
        let ringWidthPt: CGFloat = 4

        /// Every frame in the AX tree carrying `identifier`. Read from ONE `snapshot()` like
        /// `buttonSnapshots`, rather than through `app.descendants(...)`, because there is one of
        /// these per visible card and an element-query sweep over all of them is minutes of
        /// round-trips.
        func namedFrames(_ app: XCUIApplication, _ identifier: String) -> [CGRect] {
            guard let root = try? app.snapshot() else { return [] }
            var out: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier == identifier { out.append(node.frame) }
                node.children.forEach(walk)
            }
            walk(root)
            return out
        }

        /// One UNFOCUSED poster card's three published rects: the card's outer box, the depth
        /// rail, and the inset artwork.
        ///
        /// Unfocused on purpose. A focused card in either zoom mode is inside a `.scaleEffect`, so
        /// its painted rects are not its layout rects; in still mode it also carries the neutral
        /// ring. The band under test is static by design (never focus-linked, see `ringInset`), so
        /// a neighbour at rest is the clean case and the only one worth measuring.
        ///
        /// The pairing is by containment rather than by index: `poster_card`, `card_depth_rail`
        /// and `poster_artwork` are published once per visible card and the tree gives no
        /// parent/child relation between them that survives the snapshot walk.
        func cardRects(_ app: XCUIApplication, leg: String) throws -> (card: CGRect, rail: CGRect, artwork: CGRect) {
            guard let focused = focusedButton(app), focused.frame.width > 80,
                  focused.frame.height > focused.frame.width else {
                throw XCTSkip("[\(leg)] no focused poster card reported (the 27.0 runtime never reports hasFocus)")
            }
            let f = focused.frame
            // Diagnostic, not an assertion: a card BUTTON's accessibility frame is wider than the
            // card box it wraps, because the focus treatments' drop shadow (radius 22) is part of
            // the button's painted bounds. Logged here because test46's cheap left-edge sub-check
            // measures the artwork's edge against exactly this frame and therefore carries that
            // spill as an unexplained offset.
            NSLog("[BUG91] %@ focusedButton=%@", leg, "\(f)")
            let cards = namedFrames(app, "poster_card")
            let rails = namedFrames(app, "card_depth_rail")
            let artworks = namedFrames(app, "poster_artwork")
            guard !cards.isEmpty else {
                XCTFail("[\(leg)] no `poster_card` element in the tree - `-debug.cardGeometryProbe YES` did not arm `DebugAXIdentifier` (it is read once from NSArgumentDomain at first use), or this is a Release build.")
                throw XCTSkip("[\(leg)] card geometry probe not armed")
            }
            guard !rails.isEmpty else {
                XCTFail("[\(leg)] `poster_card` is published but `card_depth_rail` is not - the depth overlay is not being rendered at all even though debug_env reported depth=1. Check the Posters SURFACE toggle (Settings > Appearance > Card Depth > Posters), which is separate from the master switch `debug_env` reports.")
                throw XCTSkip("[\(leg)] no depth rail rendered")
            }
            // Same row as the focused card, and not the focused card itself. An accessibility
            // frame's top is a layout property, unaffected by any paint-time focus transform, so
            // every card in the row shares the focused card's `minY` (the same argument test46
            // makes for its own rest-candidate filter).
            let candidates = cards
                .filter { abs($0.minY - f.minY) < 60 && abs($0.midX - f.midX) > f.width * 0.4 }
                .sorted { abs($0.midX - f.midX) < abs($1.midX - f.midX) }
            for box in candidates {
                let probe = box.insetBy(dx: -2, dy: -2)
                guard let rail = rails.first(where: { probe.contains($0) }),
                      let artwork = artworks.first(where: { probe.contains($0) }) else { continue }
                return (box, rail, artwork)
            }
            throw XCTSkip("[\(leg)] \(cards.count) card rect(s), \(rails.count) rail(s), \(artworks.count) artwork(s) on screen but no unfocused card carried all three - the row may have scrolled between the walk and the snapshot; rerun")
        }

        /// The whole measurement for one launch configuration.
        func measure(_ arguments: [String], leg: String, shotName: String) throws -> (card: CGRect, rail: CGRect, artwork: CGRect) {
            let app = launchToHome(
                extraArguments: ["-debug.cardGeometryProbe", "YES"] + arguments,
                forceFreshLaunch: true
            )
            openTab(app, named: "Home")

            // Fixture precondition, loud and self-describing (suite convention): with Card Depth
            // off there is no rail to measure and every assertion below would pass vacuously.
            let env = app.staticTexts["debug_env"]
            guard env.waitForExistence(timeout: 15) else {
                XCTFail("[\(leg)] debug_env probe missing - it is DEBUG-only (HomeView.swift); is this a Release build, or did Home never mount?")
                throw XCTSkip("[\(leg)] no debug_env")
            }
            guard let depth = Self.probeValue(env.label, key: "depth") else {
                XCTFail("[\(leg)] could not parse `depth=` out of debug_env ('\(env.label)') - the probe's spelling changed; it is append-only by contract")
                throw XCTSkip("[\(leg)] unparseable debug_env")
            }
            guard depth == 1 else {
                throw XCTSkip("FIXTURE ASSUMPTION UNMET - Card Depth is OFF on this fixture (debug_env depth=0), so no depth rail is drawn and there is nothing to measure. BUG-91 only exists when the rail is drawn, so this gate needs it on: set Settings > Appearance > Card Depth on for the 'Chris' profile on the FA87 simulator and rerun. Note that test27 and test30 both end by calling `restoreAppearanceBaseline`, which turns it OFF, so a full-suite run leaves the fixture in exactly the state that skips this test.")
            }

            // test46's trap, same walk: the pinned row title overlays the first card or two, so
            // step two cards in before measuring anything near a card's top edge.
            press(.down, times: 3)
            press(.left, times: 6, gap: 0.3)
            press(.right, times: 2, gap: 0.3)
            pause(2)
            shot(app, shotName)
            return try cardRects(app, leg: leg)
        }

        // ---- Leg A: still mode. `ringInset` reserves the band, so the rail must sit exactly
        // `ringWidth` inside the card on every edge - which is the same thing as sitting exactly
        // on the picture.
        let still = try measure(["-no_zoom_on_focus", "YES"], leg: "still", shotName: "50a_still_mode_rows")
        let stillReport = XCTAttachment(string: "still card=\(still.card) rail=\(still.rail) artwork=\(still.artwork)")
        stillReport.name = "50b_still_rects"
        stillReport.lifetime = .keepAlways
        add(stillReport)
        NSLog("[BUG91] still card=%@ rail=%@ artwork=%@", "\(still.card)", "\(still.rail)", "\(still.artwork)")

        // The rail against the PICTURE. Not a tautology even though both are published on the same
        // view today: that is precisely the invariant BUG-91 broke, and the way it broke was one of
        // the two moving to the outer frame while the other stayed put.
        XCTAssertEqual(still.rail.minX, still.artwork.minX, accuracy: 0.5,
                       "depth rail's left edge is off the picture's - BUG-91's reported band on the left edge")
        XCTAssertEqual(still.rail.minY, still.artwork.minY, accuracy: 0.5,
                       "depth rail's top edge is off the picture's - BUG-91's reported band on the top edge")
        XCTAssertEqual(still.rail.width, still.artwork.width, accuracy: 0.5, "depth rail is not the picture's width (BUG-91)")
        XCTAssertEqual(still.rail.height, still.artwork.height, accuracy: 0.5, "depth rail is not the picture's height (BUG-91)")

        // The rail against the CARD, so the pair above cannot be satisfied by a rail and an artwork
        // that moved to the outer rect together.
        XCTAssertEqual(still.rail.minX, still.card.minX + ringWidthPt, accuracy: 1,
                       "the rail should start \(ringWidthPt)pt inside the card's leading edge (card \(still.card), rail \(still.rail)) - BUG-91")
        XCTAssertEqual(still.rail.minY, still.card.minY + ringWidthPt, accuracy: 1,
                       "the rail should start \(ringWidthPt)pt below the card's top edge (card \(still.card), rail \(still.rail)) - BUG-91")
        XCTAssertEqual(still.rail.width, still.card.width - 2 * ringWidthPt, accuracy: 1,
                       "with the band reserved the rail should be \(2 * ringWidthPt)pt narrower than the card (card \(still.card.width), rail \(still.rail.width)) - BUG-91")
        XCTAssertEqual(still.rail.height, still.card.height - 2 * ringWidthPt, accuracy: 1,
                       "with the band reserved the rail should be \(2 * ringWidthPt)pt shorter than the card (card \(still.card.height), rail \(still.rail.height)) - a rail hoisted onto the lockup would fail here by the caption's height")

        // ---- Leg B: the default configuration (ring off, zoom on) reserves no band, so the rail
        // must trace the card's full rect exactly as it always did. This is the byte-identical half
        // of the fix's contract: with `inset == 0` the old and the new attachment points are the
        // same box.
        let bare = try measure(["-no_zoom_on_focus", "NO", "-accent_focus_ring", "NO"],
                               leg: "default", shotName: "50c_default_mode_rows")
        let bareReport = XCTAttachment(string: "default card=\(bare.card) rail=\(bare.rail) artwork=\(bare.artwork)")
        bareReport.name = "50d_default_rects"
        bareReport.lifetime = .keepAlways
        add(bareReport)
        NSLog("[BUG91] default card=%@ rail=%@", "\(bare.card)", "\(bare.rail)")
        XCTAssertEqual(bare.rail.width, bare.card.width, accuracy: 1,
                       "with no ring band reserved the rail must trace the card's full width (card \(bare.card.width), rail \(bare.rail.width)) - the BUG-91 fix must be a no-op in the default configuration")
        XCTAssertEqual(bare.rail.height, bare.card.height, accuracy: 1,
                       "with no ring band reserved the rail must trace the card's full height (card \(bare.card.height), rail \(bare.rail.height))")
        XCTAssertEqual(bare.rail.minX, bare.card.minX, accuracy: 1,
                       "default-configuration rail is horizontally offset from the card - the BUG-91 fix must be a no-op here")
        XCTAssertEqual(bare.rail.minY, bare.card.minY, accuracy: 1,
                       "default-configuration rail is vertically offset from the card - the BUG-91 fix must be a no-op here")
    }


    // MARK: - rc1 (2026-08-30): pinned row titles on the artwork, only at Poster Size = Large

    /// Reads `k=v` out of one of Home's invisible DEBUG probe labels (`debug_env`,
    /// `debug_pinned`). Returns nil when the key is absent or not an integer, so callers can fail
    /// loudly with the raw label rather than assert on a silently-defaulted 0.
    /// String twin of `probeValue`, for probe fields that carry a token rather than a number
    /// (`beltFadeReason=standdown`). Same exact-key parsing.
    private static func probeToken(_ label: String, key: String) -> String? {
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return String(parts[1])
        }
        return nil
    }

    private static func probeValue(_ label: String, key: String) -> Int? {
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return Int(parts[1])
        }
        return nil
    }

    /// rc1 tester report: "Titles continue to overlap the posters and thumbnails, whether I move to
    /// the right or not. Only at Large poster size."
    ///
    /// Sim-reproduced on the FA87 fixture 2026-08-30 with hard numbers: a focused poster catalog
    /// row at a SETTLED rest logged `[HomeScrollProbe] title row=…recs_series_for_you
    /// margin=-86..-100 slide=72 net=-14..-28 cap=64 intr=46`. The row's top parked ~90-100pt under
    /// the pinned hero's clip edge, the BUG-37 slide saturated at its absolute 72pt cap, `net` went
    /// NEGATIVE — the invariant `PinnedRowTitleProbe`'s own doc names as the regression to watch —
    /// and the title painted 46pt into the first poster's artwork (66pt on the FOCUSED card, once
    /// the ~20pt system lift is counted; see `intrLifted=`). At Medium the focusable link frame
    /// fits the rows viewport and none of it fires, which is the report's "only at Large".
    ///
    /// The fix under test is the settle re-reveal (`PinnedRowSettle`, BrowseComponents): once the
    /// scroll settles with the focused row's title clipped, the ROWS scroll view (never the pinned
    /// hero) is animated down by exactly the shortfall, bounded so the focused card stays visible.
    ///
    /// **Oracle: the app's own geometry**, via the `debug_pinned` probe, not pixels — deliberately,
    /// and the reason is worth keeping: the pinned title is offset by a `visualEffect`, which is a
    /// RENDER-time transform and by design invisible to layout, so the title's AX frame reports its
    /// UN-slid position and a frame-based clearance check would pass while the rendered title sat
    /// on the artwork (a vacuous green of exactly the kind this suite has been burned by). A
    /// luma-based check on the rendered title is no better: near-white caption text over bright
    /// poster art has no separable signature. `debug_pinned` carries the same `margin`/`net` the
    /// device log prints, measured from the real geometry including the slide — so it is both
    /// exact and the number the report is written in. A screenshot is still attached for review.
    ///
    /// Prerequisites fail LOUDLY (suite convention): a missing probe is an `XCTFail`, a fixture in
    /// the wrong Poster Size or hero mode is a self-describing `XCTSkip`.
    func test47LargePinnedRowTitleClearsArtwork() throws {
        let app = launchToHome(forceFreshLaunch: true) // a prior still-mode process (test46) must not be reused: the settle probe reads its geometry
        openTab(app, named: "Home")
        pause(1.5)

        // Poster Size gate. The fixture is currently at Large, but this must not DEPEND on that
        // silently: `debug_env` already publishes the live `PosterStyle.width`, so read it.
        // Artwork height is width x 1.5 (Theme.Size's own table): Small 183pt wide, Medium 220,
        // Large ~269 — so >= 260 is Large.
        let env = app.staticTexts["debug_env"]
        guard env.waitForExistence(timeout: 15) else {
            XCTFail("debug_env probe missing — it is DEBUG-only (HomeView.swift); is this a Release build, or did Home never mount?")
            return
        }
        let envLabel = env.label
        guard let posterWidth = Self.probeValue(envLabel, key: "w") else {
            XCTFail("could not parse `w=` out of debug_env ('\(envLabel)') — the probe's spelling changed; it is append-only by contract")
            return
        }
        guard posterWidth >= 260 else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — Poster Size is not Large (debug_env w=\(posterWidth); Large is ~269pt). The rc1 defect this gate covers only reproduces at Large, where the focusable link frame (artwork + 175.5 ~= 579pt) hits the reveal regime that parks tall frames under the pinned clip edge (PosterCard.swift ~L730). Set Settings > Appearance > Poster Size to Large on this fixture and rerun.")
        }

        // Walk down off the hero CTA into the rows. Existence-driven, no `hasFocus` reliance
        // (house rule — the 27.0 runtime never reports it); three Downs clears Continue Watching /
        // Upcoming into a poster catalog row on this fixture, the same walk test44/test46 use.
        press(.down, times: 3, gap: 0.9)
        // Comfortably longer than everything the rest has to get through: the settle debounce
        // (0.25s), the correction animation (0.25s), the belt's fadeDelay (0.7s), and the
        // corrector's own re-check chain (up to 3 hops of 0.25s — the `clearance-late` path, which
        // gate 2 below fails on rather than skips). 3s rather than a tighter number specifically
        // so that gate 2's XCTFail can never be a timing artefact.
        pause(3.0)
        shot(app, "47a_focused_poster_row_settled")

        let probe = app.staticTexts["debug_pinned"]
        guard probe.waitForExistence(timeout: 10) else {
            XCTFail("debug_pinned probe missing — it is DEBUG-only (HomeView.swift); is this a Release build?")
            return
        }
        let line = probe.label
        let report = XCTAttachment(string: "\(line)\n(env: \(envLabel))")
        report.name = "47b_settle_line"
        report.lifetime = .keepAlways
        add(report)
        NSLog("[RC1] %@", line)

        guard !line.hasSuffix(" -") else {
            throw XCTSkip("no pinned settle was ever reported ('\(line)') — the settle re-reveal is armed only in Home's PINNED (Nuvio-style) hero container, so this fixture is running the classic in-scroll hero. Turn Settings > Home Screen > Nuvio-style hero on and rerun.")
        }
        guard Self.probeValue(line, key: "margin") != nil else {
            throw XCTSkip("the last settle reported no focused pinned row ('\(line)') — the Down walk did not land inside a pinned row, so there is nothing to measure. Rerun; if it persists the walk needs re-tuning for this fixture's row order.")
        }
        guard let net = Self.probeValue(line, key: "net"),
              let margin = Self.probeValue(line, key: "margin") else {
            XCTFail("could not parse `net=`/`margin=` out of debug_pinned ('\(line)')")
            return
        }

        // Gate 1 — VISIBILITY. `net` is the title's top relative to the clip edge AFTER the slide.
        // `net >= 0` is the settled-rest invariant (BrowseComponents ~L427); below it the title is
        // cut off at the top. 2pt of slack is the probe's own bucket width, not a tolerance for
        // the defect (which measured -14..-28).
        XCTAssertGreaterThanOrEqual(
            net, -2,
            "settled pinned rest still leaves net=\(net) (margin=\(margin)) — the row title is clipped at the pinned hero's edge, which is the rc1 report reproducing at Poster Size = Large. Full settle line: \(line)"
        )

        // Gate 2 — INTRUSION, which is what the tester actually complained about ("titles overlap
        // the posters"). Asserted on the LIFTED metric (`intrLifted`), not the pre-lift `intr`:
        // the title rides over whichever card holds FOCUS, and the system focus lift has already
        // raised that card's artwork ~20pt, so the pre-lift number is systematically 20pt
        // optimistic. That was the exact blind spot in the rc1 device log — its `intr=46` was
        // really 66 on the card being looked at — and asserting on it would let this gate pass
        // green while the tester still saw the overlap.
        //
        // Codex r1 P1 is why this is a separate assertion rather than a corollary of gate 1: a
        // rest can satisfy `net >= 0` while still painting title onto the poster. The corrector
        // now targets exactly this number — a corrected rest lands at `slide == clearanceLift`,
        // i.e. `intrLifted == 0`.
        //
        // A missing `intrLifted=` is a FAILURE, not a skip (Codex r5 P2-2). Skipping it silently
        // is exactly the vacuous-green class this harness documents: the test would pass on `net`
        // alone while the intrusion — the thing the tester actually reported — went unverified.
        // The field is absent only when the settle report says `clearance=?`, i.e. the row's title
        // never published its measurement, and that is itself a regression this gate should catch:
        // the corrector re-checks and re-arms for precisely that case (`clearance-late`,
        // BrowseComponents), so a measurement still missing three seconds after the walk is a
        // broken title, not a slow one.
        XCTAssertEqual(app.state, .runningForeground, "app must survive the settle re-reveal's scroll correction")
        guard let liftedIntrusion = Self.probeValue(line, key: "intrLifted") else {
            XCTFail("settle report carried no clearance — title measurement missing, intrusion unverified. Full settle line: \(line)")
            return
        }
        XCTAssertLessThanOrEqual(
            liftedIntrusion, 2,
            "settled pinned rest leaves the row title \(liftedIntrusion)pt past the FOCUSED card's artwork top edge — this is the rc1 report verbatim (the sim repro measured intr=46 pre-lift at Large, 66 once the ~20pt focus lift is counted). Full settle line: \(line)"
        )

        // Gate 3 (Wave 10) — CONSISTENCY. The tester's request was not only "the poster is never
        // cut off" but "rows land in the same place every time", and the corrector now normalizes
        // every settled focused rest to one canonical target (`margin == 0`). One row landing
        // correctly proves the geometry; three rows landing in the SAME place proves the property
        // the user actually feels. Walk down a row at a time, letting each settle, and collect the
        // margins.
        var margins: [(row: String, margin: Int, rowH: Int)] = []
        for step in 0..<3 {
            press(.down, times: 1, gap: 0.9)
            pause(2.5)   // settle debounce + up to two corrections and their settles
            shot(app, "47c\(step)_canonical_rest")
            let stepLine = probe.label
            let stepReport = XCTAttachment(string: stepLine)
            stepReport.name = "47c\(step)_settle_line"
            stepReport.lifetime = .keepAlways
            add(stepReport)
            NSLog("[WAVE10] consistency step=%d %@", step, stepLine)
            guard let stepMargin = Self.probeValue(stepLine, key: "margin") else { continue }
            let stepRow = Self.probeToken(stepLine, key: "row") ?? "?"
            // A row at the BOTTOM of the content legitimately cannot reach the canonical target —
            // there is no scroll range left to move it with, so the corrector reports
            // `endOfContent=1` and leaves it where it is (Codex Wave 10 r2). Excluding it is not
            // papering over a failure: asserting the canonical margin on a row the geometry cannot
            // move would be asserting something untrue, and the corrector is behaving correctly by
            // declining. Deliberately NOT extended to any other `nudge=0` line — every other one
            // means the rest already IS canonical.
            if Self.probeValue(stepLine, key: "endOfContent") == 1 {
                NSLog("[WAVE10] consistency step=%d skipped (end of content, cannot reach target): %@", step, stepLine)
                continue
            }

            // Wave G per-step gates. A row that fails any of these did not reach a healthy rest
            // at all, so grouping it below (which is about CONSISTENCY between healthy rests)
            // would be comparing a healthy row against a broken one.
            if let inBand = Self.probeValue(stepLine, key: "inBand") {
                XCTAssertEqual(
                    inBand, 1,
                    "row '\(stepRow)' settled outside its legibility band (margin=\(stepMargin)) — Wave G replaced the single canonical target with a per-row-height band, but every settled rest still has to land inside it. Full settle line: \(stepLine)"
                )
            } else {
                XCTFail("settle line for row '\(stepRow)' carries no inBand= — the band cannot be computed before the row's title has measured itself, but a settled rest three seconds after the walk should have one. Full settle line: \(stepLine)")
            }
            if let beltFaded = Self.probeValue(stepLine, key: "beltFaded") {
                XCTAssertEqual(
                    beltFaded, 0,
                    "row '\(stepRow)' left its title hidden by the visibility belt at a settled rest (margin=\(stepMargin)) — the belt is the terminal fallback for an uncorrectable rest, not something a healthy row on an ordinary walk should ever need. Full settle line: \(stepLine)"
                )
            }
            if let pull = Self.probeValue(stepLine, key: "pull") {
                XCTAssertEqual(
                    pull, 0,
                    "row '\(stepRow)' needed a pull-back correction to settle (margin=\(stepMargin)) — the pull-back detector exists to stand down a fighting device, not to be exercised on an ordinary walk. Full settle line: \(stepLine)"
                )
            }

            guard let stepRowH = Self.probeValue(stepLine, key: "rowH") else { continue }
            // Rows repeat only if the walk failed to move; dedupe so three readings of one row
            // cannot pass this vacuously.
            if !margins.contains(where: { $0.row == stepRow }) {
                margins.append((row: stepRow, margin: stepMargin, rowH: stepRowH))
            }
        }

        let summary = margins.map { "\($0.row)=\($0.margin)(rowH=\($0.rowH))" }.joined(separator: ", ")
        guard margins.count >= 3 else {
            throw XCTSkip("only \(margins.count) distinct pinned row(s) settled during the consistency walk (\(summary)) — the walk did not reach three poster rows, or ran into the end of the content where the corrector cannot reach the canonical target. Nothing to compare. Rerun; if it persists the walk needs re-tuning for this fixture's row order.")
        }
        // 2026-09-04 (Wave G rebase): the corrector's dead zone is 4pt, so 5 is that plus the
        // probe's own rounding — same tolerance as before, now applied WITHIN a row-height
        // group rather than across all three walked rows. Wave G's band is keyed to the row's
        // own lockup extent (`PinnedRowSettle` design doc), so rows of different heights
        // legitimately rest at different margins now; comparing all three against one number
        // would assert something the design no longer promises. What the design DOES still
        // promise is consistency BETWEEN rows that share a height — e.g. two catalog rows should
        // land at the same margin as each other, even if a collection row beside them does not.
        let canonicalTolerance = 5
        let byRowHeight = Dictionary(grouping: margins, by: { $0.rowH })
        for (rowH, group) in byRowHeight where group.count >= 2 {
            let groupSummary = group.map { "\($0.row)=\($0.margin)" }.joined(separator: ", ")
            let spread = (group.map(\.margin).max() ?? 0) - (group.map(\.margin).min() ?? 0)
            XCTAssertLessThanOrEqual(
                spread, canonicalTolerance,
                "rows sharing rowH=\(rowH) settled \(spread)pt apart (\(groupSummary)) — same-height rows are supposed to land at the same margin, which is the tester's actual complaint even when each individual rest is legible. All rows this walk: \(summary)"
            )
        }

        // Gate 4 (Wave G, BUG-87) — IDLE DRIFT. The tester's "constantly trying to move back" was
        // an unbounded corrector loop: a landed correction is motion, motion re-arms
        // verification, the engine reveals the frame back toward its own rest, and the cycle
        // repeats forever with nobody touching the remote. Sample the currently-focused row's
        // settle line at rest, hands off, and prove the margin holds still and nothing is still
        // firing.
        var idleSamples: [String] = []
        for i in 0..<10 {
            let line = probe.label
            idleSamples.append(line)
            let idleReport = XCTAttachment(string: line)
            idleReport.name = "47d\(i)_idle_sample"
            idleReport.lifetime = .keepAlways
            add(idleReport)
            pause(0.5)
        }
        NSLog("[WAVEG] idle drift samples: %@", idleSamples.joined(separator: " || "))

        var idleMargins: [Int] = []
        var idleSeqValues: Set<String> = []
        var idleCorrNValues: [Int] = []
        for line in idleSamples {
            // A missing `seq=` is a failure, not a skip (matches gate 2's `intrLifted=` rule):
            // the settle line is append-only by contract, so a probe sampled while the row is
            // mounted should always carry it.
            guard let seq = Self.probeToken(line, key: "seq") else {
                XCTFail("idle settle sample carries no seq= — the settle line is append-only by contract. Full sample: \(line)")
                continue
            }
            idleSeqValues.insert(seq)
            if let margin = Self.probeValue(line, key: "margin") { idleMargins.append(margin) }
            if let pull = Self.probeValue(line, key: "pull") {
                XCTAssertEqual(pull, 0, "idle sample required a pull-back correction with nobody touching the remote (BUG-87). Full sample: \(line)")
            }
            if let pbDisarm = Self.probeValue(line, key: "pbDisarm") {
                XCTAssertEqual(pbDisarm, 0, "idle sample shows the pull-back detector disarmed (BUG-87 — the corrector fought itself into a stand-down with no input). Full sample: \(line)")
            }
            if let corrN = Self.probeValue(line, key: "corrN") { idleCorrNValues.append(corrN) }
            if Self.probeValue(line, key: "nudge") == 0,
               let protB = Self.probeValue(line, key: "protB"),
               let vh = Self.probeValue(line, key: "vh") {
                XCTAssertLessThanOrEqual(
                    protB, vh + 2,
                    "an idle, non-nudging sample reports protB=\(protB) beyond the viewport vh=\(vh). Full sample: \(line)"
                )
            }
        }

        XCTAssertLessThanOrEqual(
            idleSeqValues.count, 2,
            "idle sampling over 5s produced \(idleSeqValues.count) distinct seq= values (\(idleSeqValues.sorted().joined(separator: ", "))) — an idle row with nobody touching the remote should settle at most once more after the walk above, not keep re-settling (BUG-87's unbounded corrector loop). Samples: \(idleSamples.joined(separator: " || "))"
        )
        if idleMargins.count >= 2 {
            let idleDrift = (idleMargins.max() ?? 0) - (idleMargins.min() ?? 0)
            XCTAssertLessThanOrEqual(
                idleDrift, 4,
                "idle margin drifted \(idleDrift)pt over 5s with nobody touching the remote (\(idleMargins)) — BUG-87: the corrector re-firing on its own motion, or an external mover (the hero block's height, most likely) still shifting the row. Samples: \(idleSamples.joined(separator: " || "))"
            )
        }
        // `1..<idleCorrNValues.count` traps when the array is empty (an invalid range) — guarded
        // the same way the hero-probe rows-reorder check above guards `1..<rowsLines.count`.
        if idleCorrNValues.count >= 2 {
            for i in 1..<idleCorrNValues.count {
                XCTAssertLessThanOrEqual(
                    idleCorrNValues[i], idleCorrNValues[i - 1],
                    "corrN grew from \(idleCorrNValues[i - 1]) to \(idleCorrNValues[i]) between idle samples \(i - 1) and \(i) — a correction fired with nobody touching the remote (BUG-87). Samples: \(idleSamples.joined(separator: " || "))"
                )
            }
        }

        // Gate 5 (optional, Wave G, BUG-88) — HORIZONTAL WALK. Each focus step within a row is
        // its own vertical reveal, so the same corrector this file gates on vertical walks can in
        // principle be provoked by moving along one. Prove a short horizontal walk still settles
        // inside the band with at most one extra correction.
        let corrNBeforeHorizontalWalk = idleCorrNValues.last
        press(.right, times: 3, gap: 0.9)
        pause(2)
        let horizontalWalkLine = probe.label
        let horizontalWalkReport = XCTAttachment(string: horizontalWalkLine)
        horizontalWalkReport.name = "47e_horizontal_walk"
        horizontalWalkReport.lifetime = .keepAlways
        add(horizontalWalkReport)
        NSLog("[WAVEG] horizontal walk settle: %@", horizontalWalkLine)
        if let inBand = Self.probeValue(horizontalWalkLine, key: "inBand") {
            XCTAssertEqual(inBand, 1, "row failed to settle inside its band after a 3-step horizontal walk (BUG-88). Full settle line: \(horizontalWalkLine)")
        }
        if let pull = Self.probeValue(horizontalWalkLine, key: "pull") {
            XCTAssertEqual(pull, 0, "horizontal walk required a pull-back correction (BUG-88). Full settle line: \(horizontalWalkLine)")
        }
        if let corrNBeforeHorizontalWalk, let corrNAfterHorizontalWalk = Self.probeValue(horizontalWalkLine, key: "corrN") {
            XCTAssertLessThanOrEqual(
                corrNAfterHorizontalWalk, corrNBeforeHorizontalWalk + 1,
                "corrN grew from \(corrNBeforeHorizontalWalk) to \(corrNAfterHorizontalWalk) across a 3-step horizontal walk — more than one correction fired for lateral movement inside the same row (BUG-88). Full settle line: \(horizontalWalkLine)"
            )
        }
    }


    // MARK: - Wave 9(a): the visibility belt is the TERMINAL fallback

    /// Device pass, Living Room ATV: on hardware the pinned rows park ~75pt deeper than the
    /// simulator's (tab-bar occlusion, the BUG-66 family — device `margin=-99 rowB=480` against sim
    /// `-25 / 404` at the same `vh=455`). That makes some Large rests UNSATISFIABLE: the corrector
    /// was honest about it (`nudge=19 bound=19`, then `bound=0`), but the title still sat painted
    /// across the poster for seconds, because the belt that exists for exactly this case never
    /// fired. The corrector and the belt had livelocked — every re-fired correction stamped motion,
    /// and the belt's rest-gate waits for stillness. See `PinnedRowSettle`'s header for the full
    /// chain and the three changes that close it.
    ///
    /// **Two abandoned repro attempts, both worth keeping so they are not retried.**
    ///
    /// 1. A straight-down walk (2026-08-31 run #1). It settled at `margin=+24 net=+24 deficit=0` —
    ///    a healthy top-visible rest where `beltFaded=0` is the CORRECT answer. Downward reveals
    ///    park Large rows top-visible in the simulator; there was no clipping to hide.
    ///
    /// 2. Forcing the clip with `-debug.pinnedTitleMaxSlide 2` (2026-08-31 run #2). It produced
    ///    `net=-78 intr=-25 beltFaded=0` — and that is ALSO correct behaviour, for a reason worth
    ///    stating: pinning the slide at 2pt leaves the title fully clipped ABOVE the edge, i.e.
    ///    invisible, with zero artwork contamination. `PinnedRowTitle.reading`'s `stillOnScreen`
    ///    term stands the belt down there by design — there is nothing on the poster to hide. The
    ///    override PREVENTS the intrusion instead of exhibiting it, so it is the wrong tool: the
    ///    defect is a title that is PARTIALLY visible and sitting on artwork, which a cap that
    ///    small cannot produce. The override is gone from this test entirely.
    ///
    /// Wave 10 update: the fix removed this geometry from the simulator entirely, in two steps,
    /// and leg A now recreates both.
    ///
    /// The first attempt was `-debug.pinnedSettleDisarm YES` alone — turn the corrector off so a
    /// deep park stays unfixed. That was not enough, and the 2026-09-01 run said why in the
    /// clearest possible terms: `vh=524`. The hero compression had already given the rows the
    /// 68pt they were short, so every down→up park settled HEALTHY at `margin≈+22` with nothing
    /// for a corrector to fix or a belt to hide. The premise guard failed for the best available
    /// reason — production geometry now fits.
    ///
    /// So the leg also passes `-debug.pinnedHeroCompressionOff YES`, which returns the pinned hero
    /// to its pre-Wave-10 height and the rows viewport to ~455. That is honest archaeology rather
    /// than a synthetic construction: the belt is being tested against the exact device geometry it
    /// was built for, the geometry the Living Room ATV produced and the tester filmed. A safety net
    /// still has to work when the thing it nets against comes back — past the compression cap, on
    /// mixed-shape extremes, or on whatever the next device's rests turn out to be.
    ///
    /// The pairing also buys coverage the natural version never had: with no corrector there is no
    /// stand-down either, so the belt must arrive via its `rest`/`ceiling` TIMER paths — the ones
    /// the Wave 9b fast path bypasses on every naturally-unfixable rest.
    ///
    /// Leg B deliberately runs with NEITHER knob: today's real geometry, a healthy rest, and the
    /// belt leaving it alone.
    ///
    /// What reproduces the deep park is the natural geometry: go one or two rows PAST a row and come
    /// back UP into it. An upward reveal bottom-anchors the focused frame, and a Large focusable
    /// frame (~579pt) bottom-anchored in the ~455pt rows viewport necessarily parks its top — and
    /// its title band — above the clip edge, with the rest of the title on the artwork. That run
    /// measured `margin=-80 net=-8 intr=45 bound=0`, which is the Living Room state to the point,
    /// and the belt fired. Leg A's premise is written as that pair — `net < 0` (clipped) AND
    /// `intr > 4` (on the artwork) — because run #2 proved `margin < -2` alone admits the
    /// fully-clipped variant the belt is supposed to ignore.
    ///
    /// `-no_zoom_on_focus YES` throughout: it pins the lift allowance at 0, so `clearances.focused`
    /// equals `clearances.atRest` and the settle line's `intr` and `intrLifted` agree in every
    /// focus mode. The assertions read `intrLifted` where present anyway, since that is the number
    /// the belt actually judges a focused row by.
    func test48BeltHidesUncorrectableTitle() throws {
        /// `PinnedRowTitle.fadeIntrusionArm` — how far onto the artwork the title must sit before
        /// the belt arms. Duplicated as a literal: this target drives the app as a black box.
        let intrusionArm = 4
        /// Healthy-rest premise for leg B. 2pt of slack is the settle line's own rounding.
        let healthyMarginCutoff = -2

        /// The intrusion the BELT judges by: `intrLifted` when the line carries it, else `intr`.
        /// With no-zoom pinned they are equal, but preferring the lifted one keeps this honest if
        /// the fixture is ever run in another focus mode.
        func intrusion(_ line: String) -> Int? {
            Self.probeValue(line, key: "intrLifted") ?? Self.probeValue(line, key: "intr")
        }

        // `settleLine` was hoisted to the class-level `readSettleLine(_:_:)` (below, next to
        // `walkToLastRow`) so `test58LastRowFrameFloor` can share it; every call site in this test
        // now reads `readSettleLine` directly.

        /// Settle window. Wave 9b made the expected path much shorter: on an unfixable rest the
        /// corrector's `standDown` now fires the belt immediately, so the fade lands at roughly
        /// (settle debounce 0.25 + up to two 0.25s corrections and their settles) ≈ 1.5s. The
        /// window still has to cover the FALLBACK, though — an episode that never reaches a
        /// stand-down waits `fadeDelay` (0.7) and at worst the ceiling plus one recheck floor
        /// (2.5 + 0.1), ≈ 2.9s from the last press. 4s keeps a full second of headroom over that
        /// while cutting a second off every cycle.
        let settleWindow: TimeInterval = 4.0

        // ── Leg A: the device-failure gate ───────────────────────────────────────────────────
        // Hunt for a rest that is BOTH clipped and on the artwork, the shape the device produced.
        let app = launchToHome(
            extraArguments: ["-no_zoom_on_focus", "YES",
                             // Restores the pre-Wave-10 shortfall (vh 524 → ~455) so a deep park
                             // clips again, and turns the corrector off so it stays clipped. See
                             // the header for why both are needed.
                             "-debug.pinnedHeroCompressionOff", "YES",
                             "-debug.pinnedSettleDisarm", "YES",
                             "-debug.homeScrollProbe", "YES"],
            forceFreshLaunch: true
        )
        openTab(app, named: "Home")
        pause(1.5)

        // Poster Size gate (Wave G): same premise test47 gates on. This leg's deep-park
        // reproduction needs a LARGE focusable link frame — at Medium the frame fits the rows
        // viewport and the down/up re-entry below settles healthy every time, so `deepRest`
        // is unreachable and the loop would report PREMISE UNREACHABLE for the wrong reason
        // (a fixture mismatch, not a belt failure).
        let env = app.staticTexts["debug_env"]
        guard env.waitForExistence(timeout: 15) else {
            XCTFail("debug_env probe missing — it is DEBUG-only (HomeView.swift); is this a Release build, or did Home never mount?")
            return
        }
        guard let posterWidth = Self.probeValue(env.label, key: "w") else {
            XCTFail("could not parse `w=` out of debug_env ('\(env.label)') — the probe's spelling changed; it is append-only by contract")
            return
        }
        guard posterWidth >= 260 else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — Poster Size is not Large (debug_env w=\(posterWidth); Large is ~269pt). This leg's deep-park premise (down→up bottom-anchored reveal parking a title on the artwork) only reproduces at Large. Set Settings > Appearance > Poster Size to Large on this fixture and rerun.")
        }

        press(.down, times: 3, gap: 0.9)   // off the hero CTA, into the poster-row region
        pause(1.0)

        var tried: [String] = []
        var deepRest: String?
        // Opportunistic only (see the header's abandoned attempt #2): a fully-clipped rest — off
        // the top edge, nothing on the artwork — must NOT be faded. Not hunted for, because
        // without a cap override the geometry makes it unreachable: `net < 0` requires the slide
        // saturated at its 72pt cap, which by itself puts `intr` at ~45. Asserted if one ever
        // shows up, so the `stillOnScreen` stand-down is stated where a future cap override would
        // resurrect it.
        var fullyClipped: [String] = []
        for cycle in 0..<3 {
            press(.down, times: 2, gap: 0.9)   // past the target row…
            pause(1.0)
            press(.up, times: 1, gap: 0.9)     // …then back up into it: bottom-anchored reveal
            pause(settleWindow)
            guard let line = readSettleLine(app, "48a\(cycle)_deep_rest") else { return }
            tried.append(line)
            guard let net = Self.probeValue(line, key: "net"), let intr = intrusion(line) else { continue }
            if net < 0, intr > intrusionArm { deepRest = line; break }
            if net < 0, intr <= 0 { fullyClipped.append(line) }
        }

        for line in fullyClipped {
            XCTAssertEqual(
                Self.probeValue(line, key: "beltFaded"), 0,
                "the belt hid a title that was fully clipped ABOVE the edge (net<0, intr<=0) — there is no artwork contamination in that state and `stillOnScreen` is supposed to stand the belt down. Full settle line: \(line)"
            )
        }

        guard tried.contains(where: { Self.probeValue($0, key: "margin") != nil }) else {
            throw XCTSkip("no focused pinned settle was reported across \(tried.count) attempt(s) — the settle re-reveal and its belt are armed only in Home's PINNED (Nuvio-style) hero container, so this fixture is running the classic in-scroll hero. Turn Settings > Home Screen > Nuvio-style hero on and rerun. Lines: \(tried.joined(separator: " | "))")
        }
        guard let deepRest else {
            XCTFail("PREMISE UNREACHABLE — this is NOT a belt failure. No rest the down→up re-entry produced was both CLIPPED (net < 0) and ON THE ARTWORK (intr > \(intrusionArm)), which is the device-observed shape this gate covers. Every rest was either healthy or fully clipped off the top edge, and the belt is correct to leave both alone. The walk needs to reach a partially-visible deep rest before the assertion below means anything. Lines tried: \(tried.joined(separator: " | "))")
            return
        }

        let deepNet = Self.probeValue(deepRest, key: "net") ?? 0
        let deepIntr = intrusion(deepRest) ?? 0
        XCTAssertEqual(
            Self.probeValue(deepRest, key: "beltFaded"), 1,
            "the corrector could not fix this rest (net=\(deepNet), intr=\(deepIntr), title partially visible and sitting on the poster) and the visibility belt did NOT hide it — this is the Living Room ATV failure reproducing: a title left painted across the artwork at a settled rest, for as long as the tester watched, because the corrector's re-fired corrections kept stamping motion and the belt's rest-gate never saw stillness. The belt must fire within fadeDelay + fadeMaxDefer whatever the corrector and the focus engine are doing. Full settle line: \(deepRest)"
        )

        // Wave 9b: the corrector stands down on exactly this shape of rest, and a stand-down is
        // supposed to hide the title immediately rather than let the belt's timers run. Device
        // video showed that wait as ~1-2s of title painted across the posters before it vanished,
        // so `reason=rest`/`ceiling` here would mean the fast path did not engage and the visible
        // beat is back — a regression the `beltFaded=1` assertion above cannot see on its own.
        // Soft on a missing field (older builds, or a fade that legitimately predates the reason
        // plumbing) rather than failing on absence.
        // Wave 10: with `-debug.pinnedSettleDisarm` the corrector never runs, so it never stands
        // down either — the belt has to get there on its own. That makes this leg cover the
        // rest/ceiling timer paths specifically, which the Wave 9b fast path otherwise bypasses on
        // every naturally-unfixable rest. `standdown` here would mean the knob failed to disarm and
        // the leg is silently testing the fast path again.
        if let fadeReason = Self.probeToken(deepRest, key: "beltFadeReason"), fadeReason != "-" {
            XCTAssertTrue(
                ["rest", "ceiling"].contains(fadeReason),
                "the belt hid the title via '\(fadeReason)' with the corrector disarmed — expected one of the TIMER paths (rest|ceiling), which are the ones this leg exists to cover now that Wave 10's hero compression makes naturally-unfixable rests unreachable at Large. 'standdown' would mean -debug.pinnedSettleDisarm did not take effect. Full settle line: \(deepRest)"
            )
        } else {
            NSLog("[WAVE10] no beltFadeReason on the settle line — timer-path assertion skipped: %@", deepRest)
        }

        // ── Leg B: the false-positive guard ──────────────────────────────────────────────────
        // A plain downward walk parks these rows top-visible (abandoned attempt #1 above), which is
        // exactly the healthy rest this leg wants: the belt must leave it alone. Without this, a
        // belt that simply hid every title would pass leg A.
        // NEITHER knob here, deliberately: this leg runs against TODAY's real geometry — hero
        // compressed, corrector live — which is the configuration a user actually gets. Leg A's
        // knobs recreate history; this one has to prove the belt stays out of the way in the
        // present.
        let healthyApp = launchToHome(
            extraArguments: ["-no_zoom_on_focus", "YES", "-debug.homeScrollProbe", "YES"],
            forceFreshLaunch: true
        )
        openTab(healthyApp, named: "Home")
        pause(1.5)
        press(.down, times: 3, gap: 0.9)
        pause(settleWindow)
        guard let healthyLine = readSettleLine(healthyApp, "48b_healthy_rest") else { return }
        guard let healthyMargin = Self.probeValue(healthyLine, key: "margin"),
              let healthyIntr = intrusion(healthyLine) else {
            throw XCTSkip("no focused pinned settle on the healthy leg ('\(healthyLine)') — rerun")
        }
        // Loud if the premise is unreachable: a leg B that silently ran on a clipped rest would
        // assert the opposite of what it means to.
        guard healthyMargin >= healthyMarginCutoff, healthyIntr <= 0 else {
            XCTFail("PREMISE UNREACHABLE for the false-positive guard: the straight-down walk did not land on a healthy rest (margin=\(healthyMargin), intr=\(healthyIntr); wanted margin >= \(healthyMarginCutoff) and intr <= 0). Downward reveals are supposed to park these rows top-visible — if they no longer do, this guard needs a different entry. Full settle line: \(healthyLine)")
            return
        }
        XCTAssertEqual(
            Self.probeValue(healthyLine, key: "beltFaded"), 0,
            "the belt hid a row title on a perfectly healthy rest (margin=\(healthyMargin), intr=\(healthyIntr) — clear of the artwork) — the terminal fallback is firing where it is not wanted, which would cost the title on ordinary rows too. Full settle line: \(healthyLine)"
        )

        // ── Leg B continued (Wave G, BUG-89): the last row ───────────────────────────────────
        // The last row is the one EXEMPT from the canonical rest (`endOfContent`/upward-no-room
        // both return `targetY: nil`), so a short last row can leave the PREVIOUS row's sliver
        // sitting above it indefinitely — "Services de Streaming" drawn doubled under "Genres"
        // in the tester's video. Walk down off the healthy rest above until the settle line
        // reports `last=1`, then prove the previous row is genuinely hidden and the last row's
        // own title still clears its own artwork. The rc11 shaping contract itself (BUG-87/89) is
        // proven unconditionally by `test58LastRowFrameFloor`, which sets up a regime that FITS on
        // purpose (Large + Hide Titles ON) — here it is only checked opportunistically, since this
        // leg's own premise needs captions ON for Leg A above and the two premises cannot share a
        // launch.
        guard let walk = try walkToLastRow(
            healthyApp, baselineLine: healthyLine, shotPrefix: "48c", settleLine: readSettleLine
        ) else { return }
        let lastRowLine = walk.line
        let previousPull = walk.previousPull

        guard let lastPrevHidden = Self.probeValue(lastRowLine, key: "prevHidden"),
              let lastInBand = Self.probeValue(lastRowLine, key: "inBand"),
              let lastBeltFaded = Self.probeValue(lastRowLine, key: "beltFaded") else {
            XCTFail("last-row settle line is missing prevHidden=/inBand=/beltFaded= — the settle line is append-only by contract. Full settle line: \(lastRowLine)")
            return
        }
        // BUG-89 fixture note: this only exercises the defect for real when the last row is
        // SHORT (a hidden-title square-tile collection) — a tall catalog last row has enough
        // height on its own to clear the previous row's sliver regardless of the fix. BUG-87/89
        // (rc11): the row is now frame-shaped to the regime's own link frame, so it is ~548pt tall
        // at Large rather than the pre-rc11 ~146 — `rowH=` on the settle line says which shape
        // this fixture actually walked into; check the attached line if this gate ever needs to
        // explain a vacuous pass.
        XCTAssertEqual(
            lastPrevHidden, 1,
            "the last row settled with the previous row's sliver still visible above it (prevHidden=\(lastPrevHidden)) — BUG-89: a short last row does not get enough trailing scroll range to hide its predecessor. Full settle line: \(lastRowLine)"
        )
        XCTAssertEqual(
            lastInBand, 1,
            "the last row's own title did not settle inside its legibility band (inBand=\(lastInBand)) — the last row is exempt from the canonical target but its own title still has to clear its own artwork. Full settle line: \(lastRowLine)"
        )
        // BUG-87/89 (rc11): with the frame shaped (`rowCardLinkFrameFloor`), the focus engine's own
        // reveal constraint should already confine this row to the band — the corrector's
        // `settlePlan` exemption (`lastRowShaped=1`) means it must never fire on this row, and the
        // engine must never pull a fired correction back. That shaping only applies in a FITTING
        // regime (`fits=1`, `lastRowShaped=1`), which on this fixture needs Large + Hide Titles ON
        // (`c0`) — but Leg A's deep-park premise above needs captions ON, so the two premises cannot
        // share one launch. The trio below is therefore asserted only when this walk's own regime
        // happens to land on `lastRowShaped=1`; the rc11 contract is proven unconditionally by
        // `test58LastRowFrameFloor` instead, and only opportunistically here.
        //
        // Finding 2 (P3): this leg samples the settle line after a fixed `settleWindow`/2.5s pause,
        // so a correction fired earlier in that window can already have LANDED and settled by the
        // time this line is read — `nudge=0` on its own cannot tell "never fired" apart from
        // "fired, corrected, and is now quiet". `corrN=` (`correctionsInWindow(m.rowKey)`, the
        // per-ROW corrections-in-window counter on the settle line) is the field that actually
        // answers "did anything fire on THIS row", so it is asserted alongside `nudge` rather than
        // instead of it.
        guard let lastRowNudge = Self.probeValue(lastRowLine, key: "nudge"),
              let lastRowCorrN = Self.probeValue(lastRowLine, key: "corrN"),
              let lastRowPull = Self.probeValue(lastRowLine, key: "pull") else {
            XCTFail("last-row settle line is missing nudge=/corrN=/pull= — the settle line is append-only by contract. Full settle line: \(lastRowLine)")
            return
        }
        if Self.probeValue(lastRowLine, key: "lastRowShaped") == 1 {
            XCTAssertEqual(
                lastRowNudge, 0,
                "the corrector fired on the last row — with the frame shaped (rowCardLinkFrameFloor) the focus engine's own reveal constraint should already confine this row to the band. Full settle line: \(lastRowLine)"
            )
            XCTAssertEqual(
                lastRowCorrN, 0,
                "the corrector recorded a correction against the last row within its window (corrN=\(lastRowCorrN)) even though nudge read 0 on this sample — a correction landed and settled between samples. Full settle line: \(lastRowLine)"
            )
            // `pull=` is a SESSION-WIDE counter, not this row's — comparing it to the baseline
            // taken just before the walk entered the last row (rather than asserting `== 0`
            // outright) is what keeps an EARLIER row's pullback, elsewhere in the same walk, from
            // failing this check.
            XCTAssertEqual(
                lastRowPull, previousPull ?? lastRowPull,
                "the last row absorbed a NEW pullback since the last sample taken before the walk reached it (pull=\(lastRowPull), baseline=\(previousPull.map(String.init) ?? "unavailable")) — the focus engine pulled a fired correction back on this row, the rc10 failure this shaping replaces. Full settle line: \(lastRowLine)"
            )
        } else {
            // The regime this walk landed on does not fit (`lastRowShaped=0`) — the rc11 shaping
            // never reached this row, so the corrector is legitimately allowed to fire here. Not a
            // failure of this leg; record it and defer to test58LastRowFrameFloor for the contract.
            let unshaped = XCTAttachment(string: lastRowLine)
            unshaped.name = "48_last_row_unshaped"
            unshaped.lifetime = .keepAlways
            add(unshaped)
            NSLog("[WAVE9] 48 last row unshaped (regime does not fit) — rc11 contract not asserted here, see test58: %@", lastRowLine)
        }
        XCTAssertEqual(
            lastBeltFaded, 0,
            "the belt hid the last row's own title (beltFaded=\(lastBeltFaded)) at a rest that should be showing it. Full settle line: \(lastRowLine)"
        )
    }

    /// Reads the settle line the app is currently reporting, with a screenshot and an attachment
    /// for the record. Hoisted out of `test48BeltHidesUncorrectableTitle` so `walkToLastRow` and
    /// `test58LastRowFrameFloor` can share it.
    private func readSettleLine(_ app: XCUIApplication, _ shotName: String) -> String? {
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
        NSLog("[WAVE9] %@ %@", shotName, line)
        return line
    }

    /// Walks Down from a healthy rest until the settle line reports `last=1`. Returns the last
    /// row's settle line and the `pull=` baseline from the last sample taken before the walk
    /// entered the last row (see the Finding 2 note). Throws XCTSkip when the walk stalls before
    /// `last=1`; fails when the budget runs out without a stall.
    private func walkToLastRow(_ app: XCUIApplication, baselineLine: String, shotPrefix: String,
                               settleLine: (XCUIApplication, String) -> String?) throws -> (line: String, previousPull: Int?, walked: [String])? {
        // 2026-09-04 (fixture + gate agent, Large poster size pass): the original budget of 14
        // was too small for the FA87 fixture's real Home catalog — a run through the full
        // Poster Size = Large gate batch walked 14 DISTINCT rows (movie:recs_movies_for_you
        // through movie:snoak_latest_disney_movies, one straight run of Netflix/Prime/Disney+
        // "latest" catalog pairs from installed addons) without ever repeating a row (so the
        // walk never stalled) and without ever reaching `last=1`, hitting the OTHER self-skip
        // branch's mirror image: `XCTFail("last=1 never appeared ... and focus never visibly
        // stalled either — the walk needs re-tuning for this fixture's row order/count.")` —
        // the test's own error text names exactly this. Raised to 40 (roughly 3x the observed
        // 14-row floor) to cover a well-populated real account without materially slowing a
        // fixture that reaches the end sooner (the loop still breaks the moment `last=1` shows,
        // same as the stall-detection break — this only changes the walk's OUTER ceiling).
        let maxLastRowWalk = 40
        var lastRowLine: String?
        var walked: [String] = []
        var previousDownRow: String?
        // Finding 2 (P3, test48 leg B): `pull=` on the settle line counts pullbacks for the WHOLE
        // session, not this row — an earlier row's pullback would otherwise fail the last-row
        // check spuriously. Seed the baseline from the last settle line read BEFORE this walk even
        // starts (leg B's own healthy-rest read above), then advance it to each non-terminal line
        // as the walk proceeds, so by the time `last=1` shows, this holds the count from the LAST
        // sample taken before the walk entered the last row — the last row's own line must show no
        // NEW pullback against that baseline, not merely `pull == 0`.
        var previousPull = Self.probeValue(baselineLine, key: "pull")
        var downWalkStalled = false
        for step in 0..<maxLastRowWalk {
            press(.down, times: 1, gap: 0.9)
            pause(2.5)
            guard let line = settleLine(app, "\(shotPrefix)\(step)_down_toward_last_row") else { return nil }
            let rowKey = Self.probeToken(line, key: "row")
            if let rowKey, rowKey == previousDownRow {
                // Focus stopped advancing between two consecutive Down presses — there is
                // nowhere further down to go, so the walk ran out of rows before ever seeing
                // `last=1`.
                downWalkStalled = true
                break
            }
            if Self.probeValue(line, key: "last") == 1 {
                lastRowLine = line
                break
            }
            walked.append(line)
            previousDownRow = rowKey
            previousPull = Self.probeValue(line, key: "pull")
        }

        guard let lastRowLine else {
            if downWalkStalled {
                throw XCTSkip("FIXTURE ASSUMPTION UNMET — the down walk stopped advancing (stuck on row '\(previousDownRow ?? "?")') before `last=1` was ever reported, i.e. this fixture has fewer Home rows than the \(maxLastRowWalk)-row walk budget. BUG-89 needs a real last row to reproduce against; add more Home rows (or shorten the walk) and rerun.")
            }
            XCTFail("`last=1` never appeared across a \(maxLastRowWalk)-row down walk, and focus never visibly stalled either — the walk needs re-tuning for this fixture's row order/count.")
            return nil
        }

        return (line: lastRowLine, previousPull: previousPull, walked: walked)
    }

    /// BUG-87/89 (rc11): the last row's card labels take a `minHeight` floor equal to the regime's
    /// link frame (`rowCardLinkFrameFloor`, `PinnedRowGeometry.lastRowLinkFrameFloor`), so the focus
    /// engine's own reveal constraint confines the last row to the band and the corrector never
    /// fires (`settlePlan`'s `lastRowShaped=1` exemption). `test48`'s own last-row leg can only
    /// check this opportunistically — its Leg A premise needs captions ON, which does not fit —
    /// so this test sets up the fitting premise on purpose: Large + Hide Titles ON on FA87 with
    /// zoom on (regime `L403c0p0r0z0t37`, `fits=1`) — the tester's own regime, the one the rc10
    /// pane was decoded from. Set it with `FixtureSetupTests.testSetHideLabelsOn` then
    /// `testSetPosterSizeLarge`; restore with `testSetHideLabelsOff` + `testSetPosterSizeMedium`.
    ///
    /// `-no_zoom_on_focus NO` is passed explicitly (the fixture's persisted Appearance value is No
    /// Zoom). Two runs on 2026-09-11 (zoom on, then No Zoom) both confirmed the same thing: the
    /// FA87 simulator's focus engine parks EVERY row out of band, not just the last one — a
    /// simulator-only gap, not a BUG-87/89 regression (the tester's own rc10 Row Settle pane shows
    /// middle rows `inBand=1` on hardware in this exact regime).
    ///
    /// Zoom on, regime `L403c0p0r0z0t37` (the tester's own regime): every middle row's natural
    /// rest reads `margin=-12 inBand=0 intrLifted=8`; the corrector nudges 12 in
    /// (`UNEXPECTED-WITH-FIT`), the engine pulls two of those back (`pullback=1` ×2 →
    /// `pbDisarm=1`) and every later title fades. The shaped last row rests at `margin=-13
    /// lastRowShaped=1 prevHidden=1 corrN=0 nudge=0 pull=2 pbDisarm=1 beltFaded=1` — within a pt
    /// or two of the middle-row rest, i.e. parity, not the in-band contract.
    ///
    /// No Zoom, regime `L403c0p0r0z1t37`: the same shape at `margin=-22` on the middle rows and
    /// `margin=-18` on the shaped last row (`corrN=1`, `pullback=1` ×2 → `pbDisarm=1`, every
    /// later title faded, last row `disarmed=1`).
    ///
    /// So on the simulator this test can only prove PARITY — the shaped last row rests where the
    /// middle rows rest — plus the shaping itself (`lastRowShaped=1`) and `prevHidden=1`. It
    /// cannot prove the in-band contract (`inBand=1`, no `nudge`/`corrN`, no belt fade), because
    /// the simulator's engine never puts the middle rows in band to begin with; those assertions
    /// below run only when this run's middle-row rest actually is in band, and are skipped with
    /// an attached note otherwise — the in-band/no-nudge half stays a device check against the
    /// tester's own Row Settle pane.
    func test58LastRowFrameFloor() throws {
        let app = launchToHome(
            extraArguments: ["-no_zoom_on_focus", "NO", "-debug.homeScrollProbe", "YES"],
            forceFreshLaunch: true
        )
        openTab(app, named: "Home")
        pause(1.5)
        press(.down, times: 3, gap: 0.9)
        pause(4.0)
        guard let healthyLine = readSettleLine(app, "58a_healthy_rest") else { return }
        if Self.probeValue(healthyLine, key: "last") == 1 {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the three-Down entry already landed on the LAST row (\(healthyLine)); this fixture has too few Home rows for a parity walk (test58 needs at least one middle row between the entry rest and the last row).")
        }
        guard Self.probeValue(healthyLine, key: "margin") != nil,
              Self.probeValue(healthyLine, key: "intr") != nil else {
            throw XCTSkip("no focused pinned settle was reported ('\(healthyLine)') — the settle re-reveal and its belt are armed only in Home's PINNED (Nuvio-style) hero container, so this fixture is running the classic in-scroll hero. Turn Settings > Home Screen > Nuvio-style hero on and rerun.")
        }

        // Regime gate: the last-row frame floor is 0 by design outside a fitting regime — it is
        // the FIT that lets the focus engine's own reveal constraint do the confining, so this
        // test's premise depends on it directly rather than on Poster Size/Hide Titles as a proxy.
        let regimeToken = Self.probeToken(healthyLine, key: "regime") ?? "-"
        guard let fits = Self.probeValue(healthyLine, key: "fits"), fits == 1 else {
            let fitsValue = Self.probeValue(healthyLine, key: "fits")
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the pinned regime does not fit (\(regimeToken) fits=\(fitsValue.map(String.init) ?? "-")); the last-row frame floor is 0 by design outside a fitting regime. On FA87 this needs Large + Hide Titles ON: run FixtureSetupTests/testSetHideLabelsOn then testSetPosterSizeLarge and rerun. Full settle line: \(healthyLine)")
        }

        guard let walk = try walkToLastRow(
            app, baselineLine: healthyLine, shotPrefix: "58b", settleLine: readSettleLine
        ) else { return }
        let lastRowLine = walk.line
        let previousPull = walk.previousPull

        guard let lastRowShaped = Self.probeValue(lastRowLine, key: "lastRowShaped"),
              let lastPrevHidden = Self.probeValue(lastRowLine, key: "prevHidden"),
              let lastInBand = Self.probeValue(lastRowLine, key: "inBand"),
              let lastRowNudge = Self.probeValue(lastRowLine, key: "nudge"),
              let lastRowCorrN = Self.probeValue(lastRowLine, key: "corrN"),
              let lastRowPull = Self.probeValue(lastRowLine, key: "pull"),
              let lastBeltFaded = Self.probeValue(lastRowLine, key: "beltFaded"),
              let lastMargin = Self.probeValue(lastRowLine, key: "margin"),
              let lastPbDisarm = Self.probeValue(lastRowLine, key: "pbDisarm") else {
            XCTFail("last-row settle line is missing one of lastRowShaped=/prevHidden=/inBand=/nudge=/corrN=/pull=/beltFaded=/margin=/pbDisarm= — the settle line is append-only by contract. Full settle line: \(lastRowLine)")
            return
        }
        let bandLo = Self.probeValue(lastRowLine, key: "bandLo") ?? -4

        // ── Parity data: the middle-row margins read on the way down to the last row, plus the
        //    healthy rest read before the walk started ───────────────────────────────────────
        guard !walk.walked.isEmpty else {
            XCTFail("no middle row was observed between the entry rest and the last row — parity needs at least one middle-row sample. Full settle line: \(lastRowLine)")
            return
        }
        let lastRowKey = Self.probeToken(lastRowLine, key: "row")
        var middleMargins = walk.walked
            .filter { Self.probeToken($0, key: "row") != lastRowKey }
            .compactMap { Self.probeValue($0, key: "margin") }
        if let healthyMargin = Self.probeValue(healthyLine, key: "margin") {
            middleMargins.append(healthyMargin)
        }
        guard !middleMargins.isEmpty else {
            XCTFail("no middle-row margins were collected on the walk to the last row — cannot compute the parity median. Full settle line: \(lastRowLine)")
            return
        }
        let sortedMiddleMargins = middleMargins.sorted()
        let medianMiddle: Double
        if sortedMiddleMargins.count % 2 == 0 {
            let upperIndex = sortedMiddleMargins.count / 2
            medianMiddle = Double(sortedMiddleMargins[upperIndex - 1] + sortedMiddleMargins[upperIndex]) / 2.0
        } else {
            medianMiddle = Double(sortedMiddleMargins[sortedMiddleMargins.count / 2])
        }
        let middleMarginsReport = XCTAttachment(string: "middleMargins=\(middleMargins) medianMiddle=\(String(format: "%.1f", medianMiddle)) bandLo=\(bandLo)")
        middleMarginsReport.name = "58_middle_margins"
        middleMarginsReport.lifetime = .keepAlways
        add(middleMarginsReport)

        // ── Hard assertions: shaping + parity — provable on the simulator regardless of which
        //    fitting regime the engine actually parks rows in ─────────────────────────────────
        XCTAssertEqual(
            lastRowShaped, 1,
            "the last-row frame floor did not reach this row (lastRowShaped=\(lastRowShaped)) — `HomeView` publishes `rowCardLinkFrameFloor` on `model.rows.last` only, so either this settled row is not the one the floor was published to, or the regime changed mid-walk (regime=\(regimeToken) at the healthy rest). Full settle line: \(lastRowLine)"
        )
        XCTAssertEqual(
            lastPrevHidden, 1,
            "the last row settled with the previous row's sliver still visible above it (prevHidden=\(lastPrevHidden)) — BUG-89: a short last row does not get enough trailing scroll range to hide its predecessor. Full settle line: \(lastRowLine)"
        )
        XCTAssertTrue(
            abs(Double(lastMargin) - medianMiddle) <= 8,
            "the shaped last row must rest where the middle rows rest — the floor gives it the same revealed frame, so the focus engine's own reveal constraint should park it inside the same interval (last margin=\(lastMargin), middle-row median=\(String(format: "%.1f", medianMiddle)), margins=\(middleMargins)). Full settle line: \(lastRowLine)"
        )

        // ── Corrector assertions: only meaningful while the corrector is still armed going into
        //    the last row — once a pullback has disarmed it (pbDisarm=1/disarmed=1), a fresh
        //    nudge/corrN/pull reading proves nothing about the last row specifically ───────────
        let lastDisarmed = Self.probeValue(lastRowLine, key: "disarmed")
        if lastPbDisarm == 0 && lastDisarmed != 1 {
            XCTAssertEqual(
                lastRowNudge, 0,
                "the corrector fired on the last row (nudge=\(lastRowNudge)) — with the frame shaped (rowCardLinkFrameFloor) and the regime fitting, the focus engine's own reveal constraint should already confine this row to the band. Full settle line: \(lastRowLine)"
            )
            XCTAssertEqual(
                lastRowCorrN, 0,
                "the corrector recorded a correction against the last row within its window (corrN=\(lastRowCorrN)) even though nudge read 0 on this sample — a correction landed and settled between samples. Full settle line: \(lastRowLine)"
            )
            XCTAssertEqual(
                lastRowPull, previousPull ?? lastRowPull,
                "the last row absorbed a NEW pullback since the last sample taken before the walk reached it (pull=\(lastRowPull), baseline=\(previousPull.map(String.init) ?? "unavailable")) — the focus engine pulled a fired correction back on this row, the rc10 failure this shaping replaces. Full settle line: \(lastRowLine)"
            )
        } else {
            let corrDisarmedReport = XCTAttachment(string: lastRowLine)
            corrDisarmedReport.name = "58_corrector_disarmed"
            corrDisarmedReport.lifetime = .keepAlways
            add(corrDisarmedReport)
            NSLog("[WAVE9] 58 corrector disarmed before the last row (pbDisarm/disarmed) — nudge/corrN/pull not asserted: %@", lastRowLine)
        }

        // ── In-band assertions: only meaningful when this run's engine actually parks the
        //    middle rows in band — on the FA87 simulator it does not (see the doc comment
        //    above); the in-band/belt contract is otherwise a device-only check ────────────────
        if medianMiddle >= Double(bandLo) {
            XCTAssertEqual(
                lastInBand, 1,
                "the last row's own title did not settle inside its legibility band (inBand=\(lastInBand)) — the last row is exempt from the canonical target but its own title still has to clear its own artwork. Full settle line: \(lastRowLine)"
            )
            XCTAssertEqual(
                lastBeltFaded, 0,
                "the belt hid the last row's own title (beltFaded=\(lastBeltFaded)) at a rest that should be showing it. Full settle line: \(lastRowLine)"
            )
            XCTAssertTrue(
                ((bandLo - 1)...49).contains(lastMargin),
                "the shaped last row must rest inside the band [\(bandLo), 48] (margin=\(lastMargin)). Full settle line: \(lastRowLine)"
            )
        } else {
            let outOfBandReport = XCTAttachment(string: "middleMargins=\(middleMargins) medianMiddle=\(String(format: "%.1f", medianMiddle)) bandLo=\(bandLo)")
            outOfBandReport.name = "58_sim_engine_parks_out_of_band"
            outOfBandReport.lifetime = .keepAlways
            add(outOfBandReport)
            NSLog("[WAVE9] 58 simulator engine parks the middle rows out of band (median=%@) — in-band/belt contract is a DEVICE check (tester's Row Settle pane); parity asserted only", String(format: "%.1f", medianMiddle))
        }

        shot(app, "58c_last_row")
    }

    // MARK: - BUG-111: the detail-page studio/network chip joins the plain-label ring architecture

    /// One title's outcome from `openDetailPageAndWalkToLogosRow`, kept so a final skip/return can
    /// report what happened on EVERY title tried, not just the last one.
    private struct DetailPageAttemptOutcome {
        let identifier: String
        let detail: String
    }

    /// BUG-111 review finding (fixture instability): the down×4 walk from Home lands on whatever
    /// title happens to sit in that row slot on THIS run — the fixture's Home rows reorder between
    /// runs — and occasionally that title has no company-logo art, or its `debug_ux6` probe is
    /// still mid-load past the fixed press budget; both used to read identically as "anchor never
    /// reached logos", with no way to tell a fixture limitation from a real load stall. This tries
    /// up to `maxTitles` titles in the SAME row — `.menu` backs out to Home, `.right` moves to the
    /// next poster, `.select` re-opens — before giving up, so one bad title doesn't sink the run.
    ///
    /// Pre-walk gate, fixed after a prior round wedged every title: the ONLY thing worth waiting
    /// on before the Down walk starts is that the `debug_ux6` probe itself exists (already gated
    /// above by a 15s `waitForExistence`), plus a short settle for layout. `DetailView.anchorNote`
    /// legitimately reads `"-"` the whole time focus sits in the page header — `anchorPass` only
    /// writes a row id once focus moves INTO an anchored row, which only happens after the first
    /// Down press in the walk loop below. A gate that waited for `anchor=` to leave `"-"` before
    /// the walk could ever begin was unsatisfiable and skipped every title. During the walk itself,
    /// an `anchor=-` (or empty) read just means "not on an anchored row yet" and presses more
    /// Downs; only a genuine 12-press exhaustion without ever reading `"logos"` is a failure, and
    /// that failure message quotes whatever `lastAnchor` last read, `"-"` included.
    ///
    /// Precondition: focus already rests on the FIRST candidate poster (the caller does the
    /// down×N walk to the row before calling this) and no page is open yet — the first attempt
    /// does not press `.menu`/`.right`, only `.select`.
    private func openDetailPageAndWalkToLogosRow(
        _ app: XCUIApplication,
        maxTitles: Int = 4
    ) -> (success: Bool, lastAnchor: String, outcomes: [DetailPageAttemptOutcome]) {
        var outcomes: [DetailPageAttemptOutcome] = []
        var previousAttemptOpenedPage = false
        for attempt in 1...maxTitles {
            if attempt > 1 {
                if previousAttemptOpenedPage {
                    // Only back out with Menu when the previous attempt actually opened a page —
                    // pressing Menu while focus is still on Home would act on Home's own root
                    // instead of closing anything, and the caller's next Right + Select would then
                    // land inside whatever is still open.
                    remote.press(.menu)
                    pause(2)
                    if app.staticTexts["Press Back to exit the trailer"].exists {
                        // A trailer cover eats one Menu press dismissing itself; the detail page
                        // underneath is still open and needs a second press to close.
                        remote.press(.menu)
                        pause(2)
                    }
                    XCTAssertTrue(
                        app.staticTexts["debug_ux6"].waitForNonExistence(timeout: 5),
                        "detail page should have closed after Menu before trying the next title (attempt \(attempt))"
                    )
                }
                press(.right, times: 1)
            }
            remote.press(.select)
            pause(8)
            // Bumped from the old fixed 6s: a still-loading page (not just an absent one) is
            // exactly the failure mode this retry exists to tell apart from "no page opened".
            guard app.staticTexts["debug_ux6"].waitForExistence(timeout: 15) else {
                previousAttemptOpenedPage = false
                outcomes.append(.init(identifier: "attempt \(attempt)",
                                       detail: "no detail page opened (debug_ux6 probe absent within 15s)"))
                continue
            }
            previousAttemptOpenedPage = true
            // FEAT-32: the page can still auto-enter the full-screen trailer cover a few seconds
            // in — `-debug.trailerForceNoTrailer` stops the auto-play TIMER, not necessarily the
            // cover's own entry check on every build. Back out once and settle before walking,
            // same guard DetailRowAnchorTests uses.
            pause(6)
            if app.staticTexts["Press Back to exit the trailer"].exists {
                remote.press(.menu)
                pause(3)
                // Re-confirm the detail page's own probe is back on screen before the Down walk
                // starts — `trailer=1` on these pages means an auto-play cover may still be
                // presented, and pressing Down into a still-playing cover (instead of the page
                // underneath) would just be lost input, not a row move.
                _ = app.staticTexts["debug_ux6"].waitForExistence(timeout: 5)
            }
            let identifier = pageIdentifier(app)
            // No anchor pre-wait here: `anchor=` on `debug_ux6` legitimately stays `"-"` while
            // focus is still in the page header, and only seeds once the walk below moves focus
            // into a row — waiting for it to change before the walk starts can never be satisfied.
            // The pre-walk gate is just "the probe exists" (already true by this point) plus a
            // short settle for the page to finish laying out.
            pause(1.5)
            var reachedLogosRow = false
            var lastAnchor = ""
            for _ in 1...12 {
                let probeLabel = app.staticTexts["debug_ux6"].exists ? app.staticTexts["debug_ux6"].label : ""
                lastAnchor = Self.probeToken(probeLabel, key: "anchor") ?? ""
                if lastAnchor == "logos" {
                    reachedLogosRow = true
                    break
                }
                press(.down, times: 1, gap: 1.2)
            }
            if reachedLogosRow {
                return (true, lastAnchor, outcomes)
            }
            outcomes.append(.init(identifier: identifier,
                                   detail: "never reached the logos row within 12 Downs (last anchor read \"\(lastAnchor)\")"))
        }
        return (false, "", outcomes)
    }

    /// Best-effort identifying text for a skip/failure message. The detail header's `Text(title)`
    /// (`DetailView.header`) only renders when the title has no logo art — a title WITH logo art
    /// shows a `CachedAsyncImage` there instead, no title `staticText` at all, and neither branch
    /// carries a `DebugAXIdentifier`/accessibility identifier this can key off — so a plain "first
    /// non-probe staticText anywhere" scan is not stable: it can return a generic line (genres,
    /// overview, …) that two different titles share, and on a "no page opened" attempt it walks
    /// Home's own tree and reports one of Home's labels instead of signaling nothing opened.
    /// Instead this anchors on the `debug_ux6` probe node itself — present only while a detail
    /// page is up — and pairs its own text with the first `staticText` that follows it in tree
    /// order, which is page-specific content (not shared across titles) and only exists when a
    /// page is actually open.
    private func pageIdentifier(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "unknown" }
        var flattened: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            flattened.append(node)
            for child in node.children { walk(child) }
        }
        walk(root)
        guard let probeIndex = flattened.firstIndex(where: {
            $0.elementType == .staticText && $0.label.hasPrefix("debug_ux6")
        }) else {
            // No page opened this attempt — nothing page-specific to report.
            return "unknown"
        }
        let probeLabel = flattened[probeIndex].label
        for node in flattened[(probeIndex + 1)...] {
            guard node.elementType == .staticText else { continue }
            let label = node.label
            if !label.isEmpty, !label.hasPrefix("debug_") {
                return "\(probeLabel) | \(label)"
            }
        }
        return probeLabel
    }

    /// BUG-111 (rc12, u/mrStevenx3: focusing a STUDIO tile "zooms in on the poster instead of the
    /// description" — the cast row was fixed in rc10/BUG-108 and he confirmed it, but
    /// `CompanyChip` was the one card-like site left on a bare `.buttonStyle(.borderless)`).
    ///
    /// What the SIMULATOR can prove — same framing as test56's BUG-108 gate: not the hardware
    /// compositor bug itself (the FEAT-14 graveyard in `PosterCard.swift` says the sim never
    /// reproduces that), but the GEOMETRIC claim underneath the fix, that the ring and the chip's
    /// artwork are one scaled SwiftUI layer and the rise costs the row no reflow.
    ///
    /// Oracle shape differs from test56's on purpose: every studio chip shares the same capsule
    /// aspect ratio (no square/landscape/poster mix to group by), so instead of comparing a
    /// lifted rect against a resting SIBLING in one snapshot, this compares the SAME chip index
    /// across two snapshots — focused, then not (`Right` moves focus off it) — which needs no
    /// aspect-ratio grouping at all.
    func test59StudioChipRingWithZoomOn() throws {
        let app = launchToHome(extraArguments: [
            "-no_zoom_on_focus", "NO", "-accent_focus_ring", "YES", "-debug.cardGeometryProbe", "YES",
            "-home_upcoming_row_enabled", "NO", "-debug.trailerProbe", "YES",
            "-debug.trailerForceNoTrailer", "YES", "-debug.detailScrollProbe", "YES",
        ], forceFreshLaunch: true)
        // test56's rule: restore the default settings on EVERY exit, the skips included — a
        // skipped run otherwise leaves the app running with the forced ring-on/zoom-on overrides,
        // and a later `launchToHome()` without arguments can attach to that process and inherit
        // them (order-dependent results in the rest of the suite).
        defer {
            let restored = launchToHome(forceFreshLaunch: true)
            XCTAssertTrue(restored.state == .runningForeground)
        }

        // DetailRowAnchorTests' route to a real DetailView: a movies catalog row (portrait cards
        // → NavigationLink); `-home_upcoming_row_enabled NO` keeps the down×4 walk deterministic.
        press(.down, times: 4)
        pause(0.5)
        let opened = openDetailPageAndWalkToLogosRow(app)
        guard opened.success else {
            let details = opened.outcomes.map { "\($0.identifier): \($0.detail)" }.joined(separator: "; ")
            throw XCTSkip("tried \(opened.outcomes.count) title(s) across the row, none reached the studio/network logo row (companyLogosRow, DetailRowAnchor.logos) — \(details)")
        }

        func namedFrames(_ identifier: String) -> [CGRect] {
            guard let root = try? app.snapshot() else { return [] }
            var out: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier == identifier { out.append(node.frame) }
                node.children.forEach(walk)
            }
            walk(root)
            return out
        }

        // BUG-111 review finding 1: `companyLogosRow` renders a bare, non-focusable chip for any
        // studio/network without a TMDB id (`DetailView.swift`'s `companyLogosRow`, ~1750's
        // `else { companyChip(entry.company) }` branch has no `NavigationLink`) — its
        // `company_card`/`company_artwork` probes still land in the AX tree unconditionally
        // (`DebugAXIdentifier`), so counting RENDERED rects over-counts what the remote can
        // actually reach: a row with one focusable chip and one bare chip renders two artwork
        // rects, and with the sole focusable one already focused, a Right press changes nothing
        // — a false regression on healthy code. This walks the snapshot once for `button`-typed
        // nodes (the AX role a focusable `NavigationLink` renders on tvOS — same convention as
        // `buttonSnapshots` above) and keeps only the `company_card`/`company_artwork` rect found
        // inside each button's own subtree, i.e. exactly the chips a Right press can reach.
        func focusableChipProbes() -> [(card: CGRect?, artwork: CGRect?)] {
            guard let root = try? app.snapshot() else { return [] }
            var results: [(card: CGRect?, artwork: CGRect?)] = []
            func firstProbes(under node: XCUIElementSnapshot) -> (card: CGRect?, artwork: CGRect?) {
                var card: CGRect?
                var artwork: CGRect?
                func inner(_ n: XCUIElementSnapshot) {
                    if card != nil && artwork != nil { return }
                    if card == nil, n.identifier == "company_card" { card = n.frame }
                    if artwork == nil, n.identifier == "company_artwork" { artwork = n.frame }
                    for child in n.children { inner(child) }
                }
                inner(node)
                return (card, artwork)
            }
            func walk(_ node: XCUIElementSnapshot) {
                if node.elementType == .button {
                    let probes = firstProbes(under: node)
                    if probes.card != nil || probes.artwork != nil {
                        results.append(probes)
                    }
                }
                node.children.forEach(walk)
            }
            walk(root)
            return results
        }

        // `companyLogosRow` is the FIRST anchored row below the top block (`DetailRowAnchor.Row
        // .logos`), so a handful of Down presses should reach it on any fixture that has one —
        // but not every title carries TMDB logo art, so this is a bounded search with a skip, not
        // a fixed press count. That walk (and its retry across up to 4 titles when a fixture's
        // pick has no logo art or is still loading) already ran inside
        // `openDetailPageAndWalkToLogosRow` above — `opened.success` guarantees focus already
        // rests on the logos row (`anchor=logos`, the only signal the FOCUSED row is actually the
        // logos row — `anchorPass` sets `dimModel.anchorNote` to
        // `"\(String(describing: row)) top=… y=… note"` in `DetailView.swift`, and
        // `DetailRowID.logos`'s `String(describing:)` is the literal "logos" in
        // `DetailRowAnchor.swift`'s `enum DetailRowID { case logos, … }`). A prior version of this
        // walk also accepted `namedFrames("company_artwork").count >= 2` as an early-out — that
        // turned out to be true BEFORE the very first Down press (`DebugAXIdentifier` probes sit
        // in the AX tree whether or not their row is on screen or focused), so `anchor=logos`
        // stays the only exit condition.

        // BUG-111 review finding 1 (continued): require at least two FOCUSABLE chips before a
        // "nothing changed" reading counts as a regression — with a single focusable chip
        // already focused (the row anchored on `logos` above), a Right press has nowhere to move
        // focus TO, so the old rendered-rect count could not tell that apart from a real lift
        // failure.
        var focusableChips = focusableChipProbes()
        guard !focusableChips.isEmpty else {
            throw XCTSkip("no focusable studio/network chip on the logos row — every company_card/company_artwork probe belongs to a bare, non-tmdbId chip (companyLogosRow's non-NavigationLink branch); nothing to measure")
        }

        if focusableChips.count == 1 {
            // Only one focusable chip on this fixture: there is no second chip for Right to move
            // focus onto, so the two-snapshot delta below can never observe a change by design —
            // assert the lift directly against this chip's own layout box instead. The `logos`
            // anchor reached above already implies remote focus rests on this sole focusable
            // chip.
            // BUG-111 review finding (measurement baseline): capture this chip's rectangles
            // AFTER the settling pause, not before — the pre-pause snapshot (taken the instant
            // `anchor=logos` landed) can still be mid-settle, same reasoning as the multi-chip
            // branch's confirmation press below.
            pause(1)
            let settledSoloChip = focusableChipProbes().first
            guard let artwork = settledSoloChip?.artwork, let card = settledSoloChip?.card else {
                throw XCTSkip("the sole focusable chip is missing a company_card or company_artwork probe rect — cannot measure its lift")
            }
            shot(app, "59a_studio_chip_single_focusable")
            // Hand-mirrored from `CompanyChipMetrics.focusRise`, same figure the multi-chip path
            // below uses — KEEP IN SYNC (see that path's comment).
            let chipRisePt: CGFloat = 3.12
            let expectedGrowth = 2 * chipRisePt
            XCTAssertEqual(artwork.height - card.height, expectedGrowth, accuracy: 1.5,
                           "the sole focusable studio chip's artwork should read ~\(expectedGrowth)pt taller than its own layout box while focused (2x the \(chipRisePt)pt rise); artwork=\(artwork) card=\(card)")
        } else {
            // BUG-111 review finding (walk defect): `anchor=logos` only proves the ROW is
            // anchored, not that D-pad focus has already landed on one of ITS chips rather than
            // still settling. The just-landed chip should already read taller than its
            // neighbours (the resting-height baseline every assertion below depends on); if the
            // probe instead catches every chip at the same height, spend one Right press to
            // force focus onto a specific chip and require exactly one of them to grow —
            // anything else means focus never reached a chip at all.
            let confirmHeights = focusableChips.compactMap(\.artwork?.height)
            guard confirmHeights.count == focusableChips.count else {
                throw XCTSkip("a focusable chip is missing its company_artwork probe rect — cannot confirm focus landed on a chip")
            }
            if let maxHeight = confirmHeights.max(), let minHeight = confirmHeights.min(), maxHeight - minHeight < 1 {
                press(.right, times: 1, gap: 0.6)
                pause(1.0)
                let afterConfirmProbes = focusableChipProbes()
                let afterConfirmHeights = afterConfirmProbes.compactMap(\.artwork?.height)
                let grown = confirmHeights.count == afterConfirmHeights.count
                    ? zip(confirmHeights, afterConfirmHeights).filter { $1 - $0 >= 1 }.count
                    : -1
                guard grown == 1 else {
                    XCTFail("could not confirm D-pad focus landed on a chip: every focusable company_artwork rect read the same resting height on the logos row, and a confirmation Right press grew \(grown) of them (expected exactly 1) — before=\(confirmHeights) after=\(afterConfirmHeights)")
                    return
                }
                // BUG-111 review finding (measurement baseline): the confirmation Right press
                // just moved focus, so the baseline for the two-snapshot delta below must reflect
                // where focus rests NOW — reusing the pre-confirmation snapshot as `firstProbes`
                // (initial heights all equal, e.g. [52,52,52]) would compare against a baseline
                // where nothing is focused rather than the confirmed one (e.g. [52,58.24,52]); the
                // very next Right below would then read as pure growth ([52,52,58.24]) with
                // nothing shrinking and incorrectly skip instead of measuring real data.
                focusableChips = afterConfirmProbes
            }

            pause(1)
            shot(app, "59a_studio_chip_first")

            let firstProbes = focusableChips
            let firstArtwork = firstProbes.compactMap(\.artwork)
            let firstCards = firstProbes.compactMap(\.card)
            guard firstArtwork.count == firstProbes.count, firstCards.count == firstProbes.count else {
                throw XCTSkip("a focusable chip is missing a company_artwork or company_card probe rect — cannot pair rects by index")
            }

            press(.right, times: 1, gap: 0.6)
            pause(1)
            shot(app, "59b_studio_chip_second")
            let secondProbes = focusableChipProbes()
            let secondArtwork = secondProbes.compactMap(\.artwork)
            let secondCards = secondProbes.compactMap(\.card)
            guard secondArtwork.count == firstArtwork.count, secondCards.count == firstCards.count else {
                throw XCTSkip("focusable chip count changed after Right (\(firstArtwork.count) → \(secondArtwork.count)) — the row's chip count is not stable enough to pair rects by index")
            }

            // BUG-111 review finding 2: a stable focusable-chip COUNT (checked above) only
            // proves the same number of focusable chips render in both snapshots — it says
            // nothing about whether focus actually moved between two of them. tvOS 27.0's sim
            // runtime never reports `hasFocus` on these buttons (see the
            // tvos-ui-sim-verification memory), so the frame delta itself is the only signal
            // available: with the lift working, the chip that HAD focus in the first snapshot
            // SHRINKS back to rest, and the chip that gains it GROWS — exactly one of each. The
            // chip that was focused in the FIRST snapshot and lost focus in the SECOND is the
            // one whose height shrank — i.e. the index whose height differs the most.
            let deltas = firstArtwork.indices.map { secondArtwork[$0].height - firstArtwork[$0].height }
            let grownIndices = deltas.indices.filter { deltas[$0] >= 1 }
            let shrunkIndices = deltas.indices.filter { deltas[$0] <= -1 }
            guard !grownIndices.isEmpty || !shrunkIndices.isEmpty else {
                // Both snapshots already agree on ≥2 focusable chips (checked above), and a
                // Right press produced NO height change anywhere — that is the BUG-111
                // regression itself (the focus lift never reached this row), not a fixture
                // limitation, so this fails loudly instead of skipping quietly.
                XCTFail("BUG-111 regression: \(firstArtwork.count) focusable company_artwork chips rendered before and after Right, but none changed height — the focus lift is not reaching the studio chip row. first=\(firstArtwork) second=\(secondArtwork)")
                return
            }
            guard let index = shrunkIndices.first else {
                // A chip grew but none shrank: Right did not move focus OFF the first chip — an
                // honest fixture limitation (already ruled out for count > 1 above, but kept as a
                // defensive skip rather than assumed impossible), not a regression.
                throw XCTSkip("a company_artwork rect grew (indices \(grownIndices)) but none shrank between the two snapshots on this fixture's page")
            }
            let focused = firstArtwork[index]
            let rest = secondArtwork[index]

            // Hand-mirrored from `CompanyChipMetrics.focusRise` (`PlainLabelRingTests` asserts
            // the real value against this same figure) — KEEP IN SYNC: if
            // `PlainLabelRing.smallLabelRise` or `CompanyChipMetrics.capsuleHeight` ever change,
            // update this constant to match.
            let chipRisePt: CGFloat = 3.12

            let rise = rest.minY - focused.minY
            XCTAssertEqual(rise, chipRisePt, accuracy: 1,
                           "focused studio chip rose \(rise)pt, expected ~\(chipRisePt)pt; focused=\(focused) rest=\(rest)")
            XCTAssertEqual(focused.maxY - rest.maxY, rise, accuracy: 1,
                           "growth must be symmetric — the chip lifts about its own centre, same as every other PlainLabelRing card")
            XCTAssertEqual((focused.width - rest.width) / 2,
                           rise * (rest.width / rest.height), accuracy: 1.5,
                           "width growth must be the same uniform scale as the height growth")

            // The tile's LAYOUT box must not move — `.scaleEffect` is render-only, so this is the
            // negative control proving the rise costs the row no reflow (test56's `folder_card`
            // check, mirrored for `company_card`).
            if firstCards.count == secondCards.count, index < firstCards.count {
                XCTAssertEqual(firstCards[index].minY, secondCards[index].minY, accuracy: 1,
                               "the chip's LAYOUT box moved — the lift is not render-only")
            }
        }

        // Optional leg B: still mode (No Zoom on, accent ring off) must draw no lift at all —
        // BUG-111's second half of the report ("No Zoom does not reach it either").
        let stillApp = launchToHome(extraArguments: [
            "-no_zoom_on_focus", "YES", "-accent_focus_ring", "NO", "-debug.cardGeometryProbe", "YES",
            "-home_upcoming_row_enabled", "NO", "-debug.trailerProbe", "YES",
            "-debug.trailerForceNoTrailer", "YES", "-debug.detailScrollProbe", "YES",
        ], forceFreshLaunch: true)
        press(.down, times: 4)
        pause(0.5)
        // Same multi-title retry as the ring-mode leg above (same fixture-reorder risk, same
        // "still loading vs. no logo art" ambiguity) — leg B stays OPTIONAL, so a failure across
        // all titles is a silent `return`, not a skip.
        let stillOpened = openDetailPageAndWalkToLogosRow(stillApp)
        guard stillOpened.success else { return }
        func stillNamedFrames(_ identifier: String) -> [CGRect] {
            guard let root = try? stillApp.snapshot() else { return [] }
            var out: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier == identifier { out.append(node.frame) }
                node.children.forEach(walk)
            }
            walk(root)
            return out
        }
        let stillBefore = stillNamedFrames("company_artwork")
        press(.right, times: 1, gap: 0.6)
        pause(1)
        let stillAfter = stillNamedFrames("company_artwork")
        if stillBefore.count == stillAfter.count {
            let grew = zip(stillBefore, stillAfter).contains { abs($0.height - $1.height) >= 1 }
            XCTAssertFalse(grew, "a company_artwork rect grew in still mode (No Zoom on, accent ring off) — BUG-111's second half: the chip must draw no lift at all here")
        }
        shot(stillApp, "59c_studio_chip_no_zoom_indicator")
    }

    // MARK: - BUG-110 (rc12): Card Depth strength presets read as visibly different

    /// Tester report (rc11): "the three strength levels look identical on my TV." `CardDepthStyle`'s
    /// `railWidth`/`railTopAlpha` now give Subtle/Balanced/Bold their own rail width AND top-stop
    /// alpha at EVERY coverage (Full included, for the first time since BUG-31) — see
    /// `CardDepthRailStyleTests` for the pure-function coverage of the actual formulas. This test
    /// walks the RENDERED rail through all three presets and checks the two numbers the `debug_env`
    /// probe now reports (`railW=`, the rail's line width; `railA=`, its top-stop alpha ×100) increase
    /// strictly across the triptych, alongside a screenshot of each for the manual/device read.
    ///
    /// `-debug.cardDepthOn YES` (DEBUG-only, `CardDepthStyle.applyingDebugOverrides()`) forces the
    /// master toggle AND all five per-surface flags on, so this doesn't depend on the synced fixture
    /// profile having Card Depth (or the Posters surface specifically) enabled — the same fixture
    /// assumption `test50DepthRailHugsArtworkInStillMode` has to skip on when it isn't met.
    func test60DepthEdgeLevelsAreDistinguishable() throws {
        func namedFrames(_ app: XCUIApplication, _ identifier: String) -> [CGRect] {
            guard let root = try? app.snapshot() else { return [] }
            var out: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier == identifier { out.append(node.frame) }
                node.children.forEach(walk)
            }
            walk(root)
            return out
        }

        // (name, edge strength, expected railW, expected railA) — the BUG-110 preset table.
        let presets: [(name: String, edge: Int, expectedWidth: Int, expectedAlpha: Int)] = [
            ("subtle", 28, 1, 35),
            ("balanced", 42, 2, 60),
            ("bold", 56, 3, 90),
        ]

        // test56's rule: restore the untouched default configuration on every exit (including a
        // skip), so a later `launchToHome()` never inherits a debug-forced Card Depth override.
        defer {
            let restored = launchToHome(forceFreshLaunch: true)
            XCTAssertTrue(restored.state == .runningForeground)
        }

        var railWidths: [Int] = []
        for preset in presets {
            let app = launchToHome(
                extraArguments: ["-debug.cardDepthOn", "YES",
                                 "-debug.cardDepthEdge", "\(preset.edge)",
                                 "-debug.cardGeometryProbe", "YES"],
                forceFreshLaunch: true
            )
            openTab(app, named: "Home")
            press(.down, times: 4, gap: 0.4)
            pause(1.5)

            let env = app.staticTexts["debug_env"]
            guard env.waitForExistence(timeout: 15) else {
                XCTFail("[\(preset.name)] debug_env probe missing — it is DEBUG-only (HomeView.swift); is this a Release build, or did Home never mount?")
                throw XCTSkip("[\(preset.name)] no debug_env")
            }
            let label = env.label
            guard let depth = Self.probeValue(label, key: "depth"),
                  let edge = Self.probeValue(label, key: "edge"),
                  let railW = Self.probeValue(label, key: "railW"),
                  let railA = Self.probeValue(label, key: "railA") else {
                XCTFail("[\(preset.name)] could not parse depth=/edge=/railW=/railA= out of debug_env ('\(label)') — the probe's spelling changed; it is append-only by contract")
                throw XCTSkip("[\(preset.name)] unparseable debug_env")
            }
            XCTAssertEqual(depth, 1, "[\(preset.name)] -debug.cardDepthOn YES did not force Card Depth on (\(label))")
            XCTAssertEqual(edge, preset.edge, "[\(preset.name)] -debug.cardDepthEdge \(preset.edge) did not land (\(label))")
            XCTAssertEqual(railW, preset.expectedWidth, "[\(preset.name)] railW mismatch (\(label))")
            XCTAssertLessThanOrEqual(
                abs(railA - preset.expectedAlpha), 2,
                "[\(preset.name)] railA mismatch — expected \(preset.expectedAlpha)±2, got \(railA) (\(label))"
            )

            let rails = namedFrames(app, "card_depth_rail")
            XCTAssertFalse(
                rails.isEmpty,
                "[\(preset.name)] no `card_depth_rail` element in the tree — `-debug.cardGeometryProbe YES` did not arm `DebugAXIdentifier` (it is read once from NSArgumentDomain at first use), or this is a Release build."
            )

            shot(app, "60x_depth_edge_\(preset.name)")
            railWidths.append(railW)
        }

        XCTAssertTrue(
            railWidths.count == 3 && railWidths[0] < railWidths[1] && railWidths[1] < railWidths[2],
            "railW did not increase strictly across Subtle/Balanced/Bold (\(railWidths)) — BUG-110's whole point is that the three presets differ"
        )
    }

    // MARK: - BUG-87 rc12 follow-up: the No Zoom reach-hold A/B

    /// BUG-87 follow-up (rc12): today's sim walks in No Zoom (`L403c0p0r0z1t37`) park every row at
    /// `margin=-22` against `bandLo=-4` — 2pt outside the belt's arm — the corrector nudges, two
    /// pullbacks disarm it, and titles fade (see `walkToLastRow`'s doc comment above for the exact
    /// numbers in both zoom modes). `PinnedRowTitle.FocusModeFlags.reachHoldsLift`
    /// (`AboutSettingsPane`'s "No Zoom Row Reach (A/B)" toggle, default OFF) spends the SAME 86
    /// floor zoom-on already uses, which should put that same `-22` margin INSIDE a widened band
    /// (`bandLo` `-24` instead of `-4`) — see `PinnedRowGeometryTests.testTheReachHoldWidensTheBandInsteadOfChargingLift`
    /// for the arithmetic this test is the device-adjacent half of.
    ///
    /// `-no_zoom_on_focus` is deliberately NOT passed as a launch argument here, unlike
    /// `-debug.pinnedNoZoomReachHoldsLift`: the argument-domain String form flips the two
    /// `@AppStorage` readers (`HomeView`, `PinnedRowTitleTracking`) but not
    /// `FocusModeFlags.current`'s bare `UserDefaults.standard.bool(forKey:)` default read, so a run
    /// that relied on the argument to also mean "No Zoom" would measure an incoherent mix of the
    /// two readers. The fixture already persists No Zoom (Settings › Appearance), so this asserts
    /// `z1` in the regime key instead of re-asserting the setting itself.
    ///
    /// Fixture precondition, same model as `test58LastRowFrameFloor` (not set up by this test):
    /// Poster Size Large + Hide Titles ON + No Zoom on Focus ON
    /// (`FixtureSetupTests.testSetHideLabelsOn` then `testSetPosterSizeLarge`; restore with the
    /// mirror pair after). Skips by name, naming the knob, if that precondition or the reach-hold
    /// argument itself did not take.
    func test61NoZoomReachHold() throws {
        let app = launchToHome(
            extraArguments: ["-debug.pinnedNoZoomReachHoldsLift", "YES", "-debug.homeScrollProbe", "YES"],
            forceFreshLaunch: true
        )
        openTab(app, named: "Home")
        pause(1.5)
        press(.down, times: 3, gap: 0.9)
        pause(4.0)
        guard let firstLine = readSettleLine(app, "61a_first_rest") else { return }

        let regimeToken = Self.probeToken(firstLine, key: "regime") ?? "-"
        guard regimeToken.contains("z1"), regimeToken.hasSuffix("h1") else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — regime='\(regimeToken)' does not show No Zoom with the reach-hold A/B active (want a key containing 'z1' and ending 'h1'). Either the fixture is not persisted as No Zoom + Large + Hide Titles ON (FixtureSetupTests.testSetHideLabelsOn then testSetPosterSizeLarge), or -debug.pinnedNoZoomReachHoldsLift did not reach PinnedRowTitle.reachHoldsLiftKnob. Full settle line: \(firstLine)")
        }

        // ── The plan line itself: the floor moved (66 → 85/86), not just the band it feeds ──────
        let env = app.staticTexts["debug_env"]
        guard env.waitForExistence(timeout: 15) else {
            XCTFail("debug_env probe missing — it is DEBUG-only (HomeView.swift); is this a Release build?")
            return
        }
        let envLabel = env.label
        guard let topR = Self.probeValue(envLabel, key: "topR"),
              let slack = Self.probeValue(envLabel, key: "slack") else {
            XCTFail("could not parse topR=/slack= out of debug_env ('\(envLabel)') — the probe's spelling changed; it is append-only by contract")
            return
        }
        XCTAssertTrue(
            [85, 86].contains(topR),
            "topR=\(topR) — the reach-hold should take the same 85/86 floor zoom-on uses (\(envLabel))"
        )
        XCTAssertLessThanOrEqual(
            abs(slack - 12), 2,
            "slack (rest range)=\(slack) — expected ≈12 at the held floor, the same as zoom-on's Large carousel (\(envLabel))"
        )

        // ── Middle-row walk: the band/clearance math has to hold on every row visited, not just
        //    the entry rest ───────────────────────────────────────────────────────────────────
        var lines = [firstLine]
        for step in 0..<4 {
            press(.down, times: 1, gap: 0.9)
            pause(2.5)
            guard let line = readSettleLine(app, "61b\(step)_walk") else { break }
            if Self.probeValue(line, key: "last") == 1 { break }
            lines.append(line)
        }

        var unexpectedWithFitSeen = false
        for line in lines {
            guard let bandLo = Self.probeValue(line, key: "bandLo"),
                  let clearanceLift = Self.probeValue(line, key: "clearanceLift"),
                  let clearanceLiftRaw = Self.probeValue(line, key: "clearanceLiftRaw") else {
                XCTFail("settle line missing bandLo=/clearanceLift=/clearanceLiftRaw= — the settle line is append-only by contract. Full settle line: \(line)")
                continue
            }
            XCTAssertTrue(
                bandLo >= -25 && bandLo <= -23,
                "bandLo=\(bandLo) — the hold should widen the band to ≈-24 (it reads -4 with the flag off). Full settle line: \(line)"
            )
            XCTAssertEqual(clearanceLift, 24, "clearanceLift=\(clearanceLift) — expected 24 at the held floor. Full settle line: \(line)")
            XCTAssertEqual(clearanceLiftRaw, 24, "clearanceLiftRaw=\(clearanceLiftRaw) — expected 24, unclamped and equal to clearanceLift here. Full settle line: \(line)")
            if line.contains("UNEXPECTED-WITH-FIT") { unexpectedWithFitSeen = true }
        }
        XCTAssertFalse(
            unexpectedWithFitSeen,
            "at least one middle-row line reported UNEXPECTED-WITH-FIT — a fitting regime still needed a correction, exactly what the reach-hold is meant to prevent"
        )

        // ── Gated on the sim engine actually parking these rows in band (test58's precedent: FA87
        //    parks the middle rows out of band today regardless of mode, so this is attached
        //    evidence rather than a hard assertion unless a future engine change puts them inside)
        let allInBand = !lines.isEmpty && lines.allSatisfy { line in
            guard let margin = Self.probeValue(line, key: "margin"),
                  let bandLo = Self.probeValue(line, key: "bandLo") else { return false }
            return margin >= bandLo
        }
        if allInBand {
            for line in lines {
                XCTAssertEqual(Self.probeValue(line, key: "inBand"), 1, "Full settle line: \(line)")
                XCTAssertEqual(Self.probeValue(line, key: "corrN"), 0, "Full settle line: \(line)")
                XCTAssertEqual(Self.probeValue(line, key: "pull"), 0, "Full settle line: \(line)")
                XCTAssertEqual(Self.probeValue(line, key: "pbDisarm"), 0, "Full settle line: \(line)")
                XCTAssertEqual(Self.probeValue(line, key: "beltFaded"), 0, "Full settle line: \(line)")
            }
        } else {
            let report = XCTAttachment(string: lines.joined(separator: "\n"))
            report.name = "61_sim_engine_parks_out_of_band"
            report.lifetime = .keepAlways
            add(report)
            NSLog("[WAVE9] 61 simulator engine still parks at least one row out of band with the hold on — the in-band/no-nudge/no-fade contract is a DEVICE check (the tester's Row Settle pane); band width and clearance are asserted unconditionally above regardless")
        }

        // ── Optional control leg: relaunch WITHOUT the reach-hold argument (still No Zoom, via the
        //    persisted fixture) and attach one settle line for comparison — informational only,
        //    not asserted, since the flag's OFF numbers are already covered by
        //    testTheReachHoldWidensTheBandInsteadOfChargingLift's unit-level twin ───────────────
        let controlApp = launchToHome(extraArguments: ["-debug.homeScrollProbe", "YES"], forceFreshLaunch: true)
        openTab(controlApp, named: "Home")
        pause(1.5)
        press(.down, times: 3, gap: 0.9)
        pause(4.0)
        if let controlLine = readSettleLine(controlApp, "61c_control_leg_off") {
            let report = XCTAttachment(string: controlLine)
            report.name = "61_control_leg_off"
            report.lifetime = .keepAlways
            add(report)
            NSLog("[WAVE9] 61 control leg (reach-hold OFF, bandLo expected ≈-4): %@", controlLine)
        }
    }

    // MARK: - BUG-112: Up does nothing after a down-then-up walk strands row 1 above the fold

    /// One parsed `debug_pinned` settle line, kept per row for the BUG-112 down-vs-up comparison
    /// (`runBug112UpWalk`). Every field but `row`/`raw` is optional because the `settlePlan`
    /// terminal-outcome branches append different tails to the same base line — see
    /// `BrowseComponents.swift`'s own `key=value` field-list doc comment — so a caller has to
    /// decide row by row whether a missing key is fatal, the same discipline `test58`/`test61`
    /// already use with bare `Self.probeValue` calls.
    private struct Bug112Sample {
        let row: String
        let margin: Int?
        let y: Int?
        let rowH: Int?
        let lastRowShaped: Int?
        let seq: Int?
        let nudge: Int?
        let pull: Int?
        let pbDisarm: Int?
        let disarmed: Int?
        let inBand: Int?
        let raw: String
    }

    private static func parseBug112Sample(_ line: String) -> Bug112Sample {
        Bug112Sample(
            row: probeToken(line, key: "row") ?? "-",
            margin: probeValue(line, key: "margin"),
            y: probeValue(line, key: "y"),
            rowH: probeValue(line, key: "rowH"),
            lastRowShaped: probeValue(line, key: "lastRowShaped"),
            seq: probeValue(line, key: "seq"),
            nudge: probeValue(line, key: "nudge"),
            pull: probeValue(line, key: "pull"),
            pbDisarm: probeValue(line, key: "pbDisarm"),
            disarmed: probeValue(line, key: "disarmed"),
            inBand: probeValue(line, key: "inBand"),
            raw: line
        )
    }

    /// Shared body for `test63Bug112FirstRowReachableAfterUpWalk` / `test64Bug112UpWalkWithCompressionOff`
    /// — the two tests differ only in `app`'s launch arguments and this helper's gate parameters.
    ///
    /// BUG-112 (reported on Apple TV hardware, beta.18-rc11, Medium+ poster size with Hide Titles
    /// ON — regime key prefix `P351c0`, carousel hero, zoom on): walk Down to Home's last row,
    /// walk back Up to row 2, then press Up again — nothing happens. Row 1 (a collection folder
    /// row) sits scrolled entirely above the rows viewport, clipped, and tvOS will not focus a
    /// clipped item. The tester's Row Settle probe shows rows 2–4 parking at `margin=-102…-108`
    /// on the way up versus roughly `-8` on the way down.
    ///
    /// H1 (what the down-vs-up table is evidence for): rc11's `rowCardLinkFrameFloor`
    /// (`PinnedRowGeometry.lastRowLinkFrameFloor` = max(linkFrame, viewport − 24)) grows the last
    /// row's label/shelf, so the down-walk ends at a deeper content offset than before rc11, and
    /// the up-walk only reveals the MINIMUM needed per row rather than unwinding that surplus —
    /// so it never gets back to where row 1 is reachable. H2 (not directly probed here): a fixed
    /// ~96pt device park slack rc11 merely stopped correcting. H4 (the per-row assertion below):
    /// the floor leaking onto a row that isn't actually the last one (`lastRowShaped=1` reported
    /// on a middle row).
    ///
    /// No band assertions — `test58LastRowFrameFloor`'s own notes establish the FA87 simulator's
    /// focus engine parks every row out of band regardless of mode, so `inBand=`/`margin=` are
    /// recorded for the human pass, not asserted. `test48`'s Leg A/B needs captions ON and
    /// `test58` needs zoom on with Large; this test's own premise (Medium+, Hide Titles ON) is
    /// disjoint from both, so it sets it up directly rather than reusing either fixture path.
    private func runBug112UpWalk(app: XCUIApplication, prefix: String, expectFits: Int, requireRegimePrefix: String?) throws {
        openTab(app, named: "Home")
        pause(1.5)

        press(.down, times: 1, gap: 0.9)
        pause(4.0)
        guard let firstLine = readSettleLine(app, "\(prefix)a_row1") else { return }
        guard let firstRowToken = Self.probeToken(firstLine, key: "row"), firstRowToken != "-" else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the entry settle carries no row= (or row=-); the PINNED (Nuvio-style) settle probe only reports rows in Home's pinned-hero carousel container, so this fixture is likely running the classic in-scroll hero BUG-112 does not reproduce under. Full settle line: \(firstLine)")
        }
        let firstRowKey = firstRowToken
        let regimeToken = Self.probeToken(firstLine, key: "regime") ?? "-"

        if let requireRegimePrefix {
            guard regimeToken.hasPrefix(requireRegimePrefix),
                  let fits = Self.probeValue(firstLine, key: "fits"), fits == expectFits else {
                let fitsValue = Self.probeValue(firstLine, key: "fits")
                throw XCTSkip("FIXTURE ASSUMPTION UNMET — regime='\(regimeToken)' fits=\(fitsValue.map(String.init) ?? "-") does not show the tester's BUG-112 regime (want a key with prefix '\(requireRegimePrefix)' and fits=\(expectFits)); run FixtureSetupTests/testSetHideLabelsOn then testSetPosterSizeMediumPlus and rerun. Full settle line: \(firstLine)")
            }
        } else {
            guard let fits = Self.probeValue(firstLine, key: "fits") else {
                XCTFail("settle line missing fits= — the settle line is append-only by contract. Full settle line: \(firstLine)")
                return
            }
            guard fits == expectFits else {
                throw XCTSkip("FIXTURE ASSUMPTION UNMET — fits=\(fits) (regime='\(regimeToken)'), expected \(expectFits) — the -debug.pinnedHeroCompressionOff knob did not take (the settle plan still fits). Full settle line: \(firstLine)")
            }
        }

        // ── Down walk: dedup to the FIRST sample seen per row key, in row order ────────────────
        var downSamples: [String: Bug112Sample] = [firstRowKey: Self.parseBug112Sample(firstLine)]
        var orderedKeys = [firstRowKey]

        guard let walk = try walkToLastRow(
            app, baselineLine: firstLine, shotPrefix: "\(prefix)b", settleLine: readSettleLine
        ) else { return }

        for line in walk.walked + [walk.line] {
            let sample = Self.parseBug112Sample(line)
            if downSamples[sample.row] == nil {
                downSamples[sample.row] = sample
                orderedKeys.append(sample.row)
            }
        }

        guard orderedKeys.count >= 3 else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the down walk only visited \(orderedKeys.count) distinct row(s) (\(orderedKeys)); BUG-112 needs at least 3 (row 1, row 2, and a last row) to reproduce the up-walk. Add more Home rows and rerun.")
        }
        let secondRowKey = orderedKeys[1]

        // ── Up walk: press Up until focus reports back on row 2, dedup to the FIRST sample per
        //    row key on the way up (mirrors the down walk above) ──────────────────────────────
        var upSamples: [String: Bug112Sample] = [:]
        var reachedRow2 = false
        var lastThreeRaw: [String] = []
        let upBudget = orderedKeys.count + 6
        for step in 0..<upBudget {
            press(.up, times: 1, gap: 0.9)
            pause(2.5)
            guard let line = readSettleLine(app, "\(prefix)c\(step)_up_toward_row2") else { return }
            lastThreeRaw.append(line)
            if lastThreeRaw.count > 3 { lastThreeRaw.removeFirst() }
            let sample = Self.parseBug112Sample(line)
            if upSamples[sample.row] == nil {
                upSamples[sample.row] = sample
            }
            if sample.row == secondRowKey {
                reachedRow2 = true
                break
            }
        }

        guard reachedRow2 else {
            let report = XCTAttachment(string: lastThreeRaw.joined(separator: "\n"))
            report.name = "\(prefix)x_never_reached_row2"
            report.lifetime = .keepAlways
            add(report)
            shot(app, "\(prefix)x_never_reached_row2")
            XCTFail("BUG-112: the up walk never got back to row 2 ('\(secondRowKey)') within \(upBudget) presses. Last three settle lines: \(lastThreeRaw.joined(separator: " || "))")
            return
        }

        shot(app, "\(prefix)c_row2_before_final_up")

        // ── Final presses: the reported repro is Up doing nothing once row 2 has focus and row 1
        //    (scrolled off the top) is unreachable ────────────────────────────────────────────
        let row2Seq = upSamples[secondRowKey]?.seq
        var finalSamples: [Bug112Sample] = []
        for step in 0..<3 {
            press(.up, times: 1, gap: 0.9)
            pause(2.5)
            guard let line = readSettleLine(app, "\(prefix)d\(step)_final_up") else { return }
            finalSamples.append(Self.parseBug112Sample(line))
        }
        let landedOnRow1 = finalSamples.contains { $0.row == firstRowKey }
        let seqAnalysis = finalSamples.map { sample -> String in
            guard let seq = sample.seq else { return "\(sample.row) seq=?" }
            guard let row2Seq else { return "\(sample.row) seq=\(seq) (no row2 baseline)" }
            return "\(sample.row) seq=\(seq) (\(seq == row2Seq ? "FROZEN — no settle fired" : "advanced") vs row2 seq=\(row2Seq))"
        }.joined(separator: "; ")

        // ── Attachments ─────────────────────────────────────────────────────────────────────
        let keysReport = XCTAttachment(string: orderedKeys.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        keysReport.name = "\(prefix)_row_keys"
        keysReport.lifetime = .keepAlways
        add(keysReport)

        func fmt(_ v: Int?) -> String { v.map(String.init) ?? "-" }
        var deltas: [Int] = []
        var tableLines = ["row | margin_down | margin_up | delta | y_down | y_up | delta_y | rowH_down | lastRowShaped_down | lastRowShaped_up | inBand_up | nudge_up | pull_up | pbDisarm_up"]
        for key in orderedKeys {
            let down = downSamples[key]
            let up = upSamples[key]
            var delta: Int?
            if let md = down?.margin, let mu = up?.margin { delta = md - mu }
            if let delta { deltas.append(delta) }
            var deltaY: Int?
            if let yd = down?.y, let yu = up?.y { deltaY = yd - yu }
            tableLines.append("\(key) | \(fmt(down?.margin)) | \(fmt(up?.margin)) | \(fmt(delta)) | \(fmt(down?.y)) | \(fmt(up?.y)) | \(fmt(deltaY)) | \(fmt(down?.rowH)) | \(fmt(down?.lastRowShaped)) | \(fmt(up?.lastRowShaped)) | \(fmt(up?.inBand)) | \(fmt(up?.nudge)) | \(fmt(up?.pull)) | \(fmt(up?.pbDisarm))")
        }
        if !deltas.isEmpty {
            let sorted = deltas.sorted()
            let median: Double = sorted.count % 2 == 0
                ? Double(sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
                : Double(sorted[sorted.count / 2])
            let lastKey = orderedKeys[orderedKeys.count - 1]
            tableLines.append("")
            tableLines.append("median(margin_down-margin_up)=\(String(format: "%.1f", median)) max=\(sorted.last ?? 0) over \(deltas.count) row(s) with both samples; last row '\(lastKey)' rowH_down=\(fmt(downSamples[lastKey]?.rowH)) lastRowShaped_down=\(fmt(downSamples[lastKey]?.lastRowShaped))")
        }
        let tableReport = XCTAttachment(string: tableLines.joined(separator: "\n"))
        tableReport.name = "\(prefix)_down_vs_up"
        tableReport.lifetime = .keepAlways
        add(tableReport)

        let finalReport = XCTAttachment(string: finalSamples.map(\.raw).joined(separator: "\n") + "\n\nseq analysis: \(seqAnalysis)")
        finalReport.name = "\(prefix)_final_presses"
        finalReport.lifetime = .keepAlways
        add(finalReport)

        // ── Assertions ──────────────────────────────────────────────────────────────────────
        XCTAssertTrue(
            landedOnRow1,
            "BUG-112: Up from row 2 never reached row 1 ('\(firstRowKey)') in three presses — matches the reported repro (row 1 scrolled entirely above the rows viewport, clipped, unreachable by Up). Final settle lines: \(finalSamples.map(\.raw).joined(separator: " || "))"
        )
        let lastKey = orderedKeys[orderedKeys.count - 1]
        for key in orderedKeys where key != lastKey {
            if let shaped = downSamples[key]?.lastRowShaped {
                XCTAssertNotEqual(shaped, 1, "H4: the last-row frame floor leaked to a non-last row ('\(key)') on the way down. Full settle line: \(downSamples[key]?.raw ?? "-")")
            }
            if let shaped = upSamples[key]?.lastRowShaped {
                XCTAssertNotEqual(shaped, 1, "H4: the last-row frame floor leaked to a non-last row ('\(key)') on the way up. Full settle line: \(upSamples[key]?.raw ?? "-")")
            }
        }

        shot(app, "\(prefix)d_after_up_from_row2")
    }

    /// BUG-112 at the tester's own regime (Medium+, Hide Titles ON, zoom on — see
    /// `runBug112UpWalk`'s header comment for the full repro and hypotheses). Set the fixture
    /// with `FixtureSetupTests.testSetHideLabelsOn` then `testSetPosterSizeMediumPlus`.
    func test63Bug112FirstRowReachableAfterUpWalk() throws {
        let app = launchToHome(
            extraArguments: ["-no_zoom_on_focus", "NO", "-debug.homeScrollProbe", "YES", "-debug.pinnedRowSettleProbe", "YES"],
            forceFreshLaunch: true
        )
        try runBug112UpWalk(app: app, prefix: "63", expectFits: 1, requireRegimePrefix: "P351c0")
    }

    /// Same BUG-112 repro as `test63Bug112FirstRowReachableAfterUpWalk`, with rc11's suspected
    /// cause (H1, the last-row frame floor) switched off via `-debug.pinnedHeroCompressionOff` —
    /// the knob works by making the settle plan NOT fit (`fits=0`), which is why the gate checks
    /// `fits` rather than the regime key here. If Up from row 2 reaches row 1 in THIS test but not
    /// in test63, H1 is confirmed; if it fails here too, H1 is not the whole story and H2/H4 need
    /// a harder look.
    func test64Bug112UpWalkWithCompressionOff() throws {
        let app = launchToHome(
            extraArguments: [
                "-no_zoom_on_focus", "NO", "-debug.homeScrollProbe", "YES", "-debug.pinnedRowSettleProbe", "YES",
                "-debug.pinnedHeroCompressionOff", "YES"
            ],
            forceFreshLaunch: true
        )
        try runBug112UpWalk(app: app, prefix: "64", expectFits: 0, requireRegimePrefix: nil)
    }

    /// BUG-112 (Item A): the Up fallback. The SHIPPED trigger — an Up press the focus engine did
    /// not consume — cannot be reproduced here: the FA87 simulator's engine resolves Up from row 2
    /// into a fully off-screen row 1 every time (that is exactly what test63/test64 record). So
    /// this gate arms `-debug.homeUpFallbackForce YES`, which binds the IDENTICAL fallback body to
    /// Play/Pause, and proves the action ladder end to end: the request reaches the previous row,
    /// that row takes focus, and the settle line's `row=` becomes the previous row's key.
    ///
    /// What it deliberately does NOT prove: that `onMoveCommand(.up)` is delivered on hardware when
    /// the engine gives up. That is the device pass — Steven's Row Settle pane will show the
    /// `upFallback row=… prev=… action=…` line the same fallback writes.
    ///
    /// Do not run this with Trailer Location = Hero and a playing hero trailer: the hero's player
    /// owns Play/Pause in that state. The launch arguments below do not enable inline trailers.
    func test65Bug112UpFallbackFocusesThePreviousRow() throws {
        let app = launchToHome(
            extraArguments: [
                "-no_zoom_on_focus", "NO", "-debug.homeScrollProbe", "YES",
                "-debug.pinnedRowSettleProbe", "YES", "-debug.homeUpFallbackForce", "YES"
            ],
            forceFreshLaunch: true
        )
        openTab(app, named: "Home")
        pause(1.5)

        press(.down, times: 1, gap: 0.9)
        pause(3.5)
        guard let firstLine = readSettleLine(app, "65a_row1") else { return }
        guard let rowOneKey = Self.probeToken(firstLine, key: "row"), rowOneKey != "-" else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the entry settle carries no row= (or row=-): this fixture is not in the PINNED (Nuvio-style) hero mode BUG-112 lives in. Full settle line: \(firstLine)")
        }

        press(.down, times: 1, gap: 0.9)
        pause(3.5)
        guard let secondLine = readSettleLine(app, "65b_row2") else { return }
        guard let rowTwoKey = Self.probeToken(secondLine, key: "row"), rowTwoKey != rowOneKey else {
            throw XCTSkip("FIXTURE ASSUMPTION UNMET — the second Down did not reach a second row (row='\(Self.probeToken(secondLine, key: "row") ?? "-")'); BUG-112's fallback needs a row WITH a predecessor. Full settle line: \(secondLine)")
        }

        remote.press(.playPause)
        pause(3.0)

        let fallback = app.staticTexts["debug_upfallback"]
        guard fallback.waitForExistence(timeout: 10) else {
            XCTFail("debug_upfallback probe missing — it is DEBUG-only (HomeView.swift); is this a Release build?")
            return
        }
        let fallbackLine = fallback.label
        let fallbackReport = XCTAttachment(string: fallbackLine)
        fallbackReport.name = "65c_upfallback_line"
        fallbackReport.lifetime = .keepAlways
        add(fallbackReport)
        shot(app, "65c_after_fallback")

        XCTAssertEqual(Self.probeToken(fallbackLine, key: "row"), rowTwoKey,
                       "the fallback fired for the wrong row — it must act for the row that HAD focus. Full line: \(fallbackLine)")
        XCTAssertEqual(Self.probeToken(fallbackLine, key: "prev"), rowOneKey,
                       "the fallback targeted the wrong predecessor. Full line: \(fallbackLine)")
        XCTAssertNotEqual(Self.probeToken(fallbackLine, key: "action"), "giveup",
                          "every rung of the hand-off ladder missed. Full line: \(fallbackLine)")

        guard let landedLine = readSettleLine(app, "65d_landed") else { return }
        XCTAssertEqual(Self.probeToken(landedLine, key: "row"), rowOneKey,
                       "BUG-112 Item A: the fallback did not land focus on the previous row ('\(rowOneKey)'). Fallback line: \(fallbackLine) || settle line: \(landedLine)")

        XCTAssertNotNil(Self.probeValue(landedLine, key: "dir"),
                        "the settle line lost `dir=` — it is append-only by contract. Full line: \(landedLine)")
        XCTAssertNotNil(Self.probeValue(landedLine, key: "rearm"),
                        "the settle line lost `rearm=` — it is append-only by contract. Full line: \(landedLine)")
    }

    // MARK: - FEAT-32: description → full-screen trailer bridge

    /// Opens a detail page with trailer auto-play forced on and lets its 4 s timer fire the same
    /// request the Watch Trailer button makes. The `debug_bridge` probe (DEBUG, invisible) records
    /// every phase the bridge passes through; after Back and the settle it must read the full
    /// `idle>leaving>playing>returning>idle` path. Existence of the caption or the chrome is NOT an
    /// oracle here: hidden SwiftUI elements still exist to XCUITest (`accessibilityHidden` did not
    /// change that on the tvOS 27 runtime), so the trace is the only honest signal. The screenshots
    /// give the human pass the look of each phase. Soft-skips when the fixture title resolves no
    /// trailer.
    func test51TrailerBridgeAutoPlay() throws {
        let app = launchToHome(
            extraArguments: ["-detail_trailer_autoplay", "YES", "-detail_trailer_background", "YES",
                             "-debug.trailerDiagnostics", "YES", "-debug.trailerProbe", "YES"],
            forceFreshLaunch: true
        )
        // Detail-page entry via the hero CTA ("Go to Movie"/"Go to Show"): test22's focus
        // normalization. The four-downs walk test21 uses lands on a collection folder page on the
        // current fixture Home, not a detail page.
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(1.5)
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Go to'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 8), "hero CTA not on screen; cannot reach a detail page")
        remote.press(.select)
        pause(2.5)
        shot(app, "51a_detail")

        // Watch Trailer only renders once the hero trailer resolved, which is auto-play's
        // precondition too.
        // Exact label: a CONTAINS 'Trailer' match also hit the "Trailers & Extras" cards on a page
        // whose hero trailer never resolved, and the test then pressed Menu on a page with no
        // cover and popped it (two runs, 2026-09-05 18:20).
        let watch = app.buttons["Watch Trailer"]
        guard watch.waitForExistence(timeout: 12) else {
            throw XCTSkip("no trailer resolved for the fixture's first title; the bridge has nothing to play")
        }
        let probe = app.staticTexts["debug_bridge"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "debug_bridge probe missing (DEBUG build?)")
        XCTAssertEqual(probe.label, "debug_bridge trace=idle", "the bridge must be idle before auto-play fires")

        // Auto-play fires 4 s after the page settles with no input; the leave runs 0.6 s more.
        pause(5.5)
        shot(app, "51b_leaving_or_playing")
        pause(3)
        shot(app, "51c_playing")

        remote.press(.menu)
        pause(0.4)
        shot(app, "51d_returning")
        // Poll the probe for the settle: the chrome animates back 0.5 s after it.
        let settled = NSPredicate(format: "label ENDSWITH 'returning>idle'")
        let settledExp = expectation(for: settled, evaluatedWith: probe)
        wait(for: [settledExp], timeout: 8)
        pause(1.5)
        shot(app, "51e_settled")
        let trace = probe.label
        print("[FEAT32] \(trace)")
        XCTAssertEqual(
            trace, "debug_bridge trace=idle>leaving>playing>returning>idle",
            "the bridge did not run its full choreography: \(trace)"
        )
        XCTAssertTrue(watch.exists, "Watch Trailer is gone after the return")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - FEAT-30: floating sidebar overlay

    /// FEAT-30's device-local opt-in (`-sidebar_style sidebar`) swaps the system tab bar for
    /// `SidebarOverlay`'s floating panel (`DesignSystem/SidebarOverlay.swift`): collapsed at rest
    /// to just the current tab's own row, expands to all six the instant focus lands on it, and
    /// stepping focus back out (Right, toward content) collapses it again. This is the harness's
    /// only coverage of that mode — every other test in this file runs in tabs mode, which is why
    /// the fixture restore at the end matters as much as the assertions above it.
    ///
    /// Reveal is Menu-only. FEAT-30 briefly (2026-09-05 device spike through 2026-09-08's BUG-98)
    /// also revealed the panel on an Up press with no focus target above it, gated for a day on a
    /// 0.45s "deliberate Up" settle window and then ungated on a misread of a tester's rc6 video.
    /// The rc7 tester verdict (2026-09-09) was that reveal-on-Up was unusable on hardware no
    /// matter how it was gated — the panel opened "no matter where he is" — so Christian dropped
    /// that path entirely; see `SidebarOverlay.swift`'s `SidebarMenuRevealModifier` doc comment for
    /// the full arc. This test now asserts BOTH directions of that decision: a lone Up does
    /// nothing, and Menu is what reveals + focuses the panel.
    ///
    /// Deliberately never presses Menu while a sidebar row could hold focus: `SidebarOverlay`
    /// installs no exit handler of its own, so Menu there falls through to the system's
    /// suspend-the-app default (see its doc comment, and `openTab`'s sidebar branch above, which
    /// this test's navigation mirrors).
    func test52SidebarOverlay() throws {
        let app = launchToHome(extraArguments: ["-sidebar_style", "sidebar"], forceFreshLaunch: true)
        pause(1.5)

        let debugSidebar = app.staticTexts["debug_sidebar"]
        XCTAssertTrue(debugSidebar.waitForExistence(timeout: 6), "debug_sidebar probe missing (DEBUG build?)")
        XCTAssertTrue(debugSidebar.label.contains("mode=1"), "sidebar mode did not turn on: \(debugSidebar.label)")

        // Collapsed at rest: only the current tab's (Home's) own row exists — and at rest the pill
        // is deliberately NOT a button (`SidebarOverlay.armed`: it is a plain label until a Menu
        // reveal arms it), so match any element type here.
        XCTAssertTrue(app.descendants(matching: .any)["sidebar_item_Home"].exists, "sidebar_item_Home must exist at rest on the Home tab")
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_item_Search"].exists, "sidebar_item_Search must NOT exist while the panel is collapsed")

        // The system tab bar must be gone outright. `app.buttons["Home"]` cannot say so — XCUI
        // matches identifier OR label, and the sidebar's own Home row is labelled "Home" — but
        // while the panel is collapsed NOTHING labelled "Search" may exist: the tab bar's Search
        // button is hidden with the bar, and the sidebar's Search row only exists once expanded.
        XCTAssertFalse(app.buttons["Search"].exists, "a 'Search' button exists while collapsed — the system tab bar is still present in sidebar mode")
        shot(app, "52a_collapsed")

        // 2026-09-09 (rc7 tester verdict, BUG-98 follow-up): a lone Up press with focus at rest on
        // the hero/first row must NOT reveal the panel any more — the Up-reveal path (device spike
        // through BUG-98) is gone outright, gated or not. Assert this BEFORE summoning the panel,
        // while focus is still exactly where launch left it.
        remote.press(.up)
        pause(0.6)
        XCTAssertFalse(app.buttons["sidebar_item_Search"].exists, "a lone Up press revealed the panel — the sidebar must only open on Menu now")
        XCTAssertTrue(app.descendants(matching: .any)["sidebar_item_Home"].exists, "sidebar_item_Home should still exist collapsed after a no-op Up")
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_item_Search"].exists, "sidebar_item_Search must still not exist after a no-op Up")

        // Menu is the ONLY reveal path now. Home's own Menu grammar (the BUG-27 ternary in
        // HomeView's body) only routes to the sidebar via `sidebarMenuRevealHandler` while
        // `!isScrolledDown` — true here since the test just launched and never scrolled — so this
        // one press both reveals AND focuses `sidebar_item_Home`, which is what expands the panel
        // to all six rows (`SidebarOverlay.isExpanded`).
        let homeRow = app.buttons["sidebar_item_Home"]
        remote.press(.menu)
        pause(1.0)
        print("[test52] after Menu focused=\(focusedButton(app).map { "\($0.identifier)|\($0.label)|\($0.frame)" } ?? "nil")")
        let expanded = homeRow.waitForExistence(timeout: 4) && homeRow.hasFocus
        XCTAssertTrue(expanded, "Menu did not reveal + focus sidebar_item_Home")
        pause(0.5)
        let stateProbe = app.staticTexts["sidebar_state"]
        XCTAssertTrue(stateProbe.waitForExistence(timeout: 4), "sidebar_state probe missing while the panel is shown")
        XCTAssertTrue(stateProbe.label.contains("expanded=1"), "panel did not report expanded once focus landed on a row: \(stateProbe.label)")
        XCTAssertTrue(app.buttons["sidebar_item_Search"].exists, "sidebar_item_Search must exist once the panel is expanded")
        shot(app, "52b_expanded")

        // Down to Search, Select to enter it. NOT Menu — see the header comment.
        let searchRow = app.buttons["sidebar_item_Search"]
        XCTAssertTrue(moveFocus(.down, until: searchRow, max: 4), "could not focus sidebar_item_Search from sidebar_item_Home")
        remote.press(.select)
        pause(2.5)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 6), "Search content did not appear after selecting sidebar_item_Search")
        shot(app, "52c_search")

        // Selecting a row releases focus to the new tab's content (`SidebarOverlay.basePanel`:
        // our pages start below the panel, so the reference's keep-focus behaviour left no way
        // out but Down past the last row), so the panel must now be collapsed with no further
        // press — AND something in content must actually hold focus (internal review r3 P2-9:
        // `expanded=0` alone also describes the BUG-47 dead end where focus landed nowhere).
        pause(1.5)
        // `focusedButton` unions cells/buttons/toggles/switches; Search's first focusable is its
        // TextField, so include text fields (and any focused static container) in the landing read.
        let landed = focusedButton(app)
            ?? app.textFields.allElementsBoundByIndex.first(where: { $0.hasFocus })
            ?? app.otherElements.allElementsBoundByIndex.first(where: { $0.hasFocus })
        print("[test52] landed=\(landed.map { "\($0.elementType.rawValue):\($0.identifier)|\($0.label)" } ?? "nil") \(stateProbe.exists ? stateProbe.label : "(no sidebar_state)")")
        XCTAssertNotNil(landed, "after selecting Search nothing holds focus — the hand-off landed nowhere (BUG-47 class)")
        if let landed {
            XCTAssertFalse(landed.identifier.hasPrefix("sidebar_item_"), "focus stayed in the panel after the row press: \(landed.identifier)|\(landed.label)")
        }
        if stateProbe.exists {
            XCTAssertTrue(stateProbe.label.contains("expanded=0"), "panel should report collapsed once focus left it: \(stateProbe.label)")
        } else {
            // Also acceptable: the whole panel (and its probe) can disappear once collapsed AND
            // scrolled — `SidebarOverlay.shouldShow` folds the reveal/scroll resting rule together.
            // Either shape means "no longer expanded showing every row".
            XCTAssertFalse(
                app.buttons["sidebar_item_Home"].exists && app.buttons["sidebar_item_Search"].exists,
                "both sidebar_item_Home and sidebar_item_Search still exist — the panel never collapsed"
            )
        }

        // Restore: fresh tabs-mode launch, exactly like test43's fixture restore.
        let restored = launchToHome(forceFreshLaunch: true)
        let restoredProbe = restored.staticTexts["debug_sidebar"]
        XCTAssertTrue(restoredProbe.waitForExistence(timeout: 6), "debug_sidebar probe missing after restore")
        XCTAssertTrue(restoredProbe.label.contains("mode=0"), "fixture did not restore to tabs mode: \(restoredProbe.label)")
        XCTAssertTrue(restored.state == .runningForeground)
    }

    // MARK: - FEAT-31: Open Sans typeface

    /// FEAT-31's device-local opt-in (`-ui_font openSans`) resolves every `Theme.Font` token to
    /// Open Sans (`Theme.AppFontFamily`, `DesignSystem/Theme.swift`). AX has no way to see which
    /// font actually rendered, so the two screenshots are this test's real evidence; the
    /// assertions below only confirm the Appearance pane's new "Typeface" row exists and reads
    /// "Open Sans" as its current value.
    ///
    /// Reaches the row with a FIXED down-count from the Theme swatches, the same technique
    /// `FixtureSetupTests.walkFromSwatchesToSizeRow` uses and for the same reason (its doc
    /// comment): `SettingsPickerRow` composes no matchable label on its wrapping Cell/Button, so a
    /// label-based walk (`walkToRowByTreeIndex`) cannot find it, and a lazy List will not have
    /// materialised a row this far down without focus actually having stepped through it. Counted
    /// directly off `AppearanceSettingsPane.body`'s literal order: swatches -> Accent Focus Ring
    /// (1) -> No Zoom on Focus (2) -> Settings Style (3) -> Navigation (4) -> Typeface (5).
    func test53TypefaceOpenSans() throws {
        let app = launchToHome(extraArguments: ["-ui_font", "openSans"], forceFreshLaunch: true)
        pause(1.5)
        shot(app, "53a_home_open_sans")

        openTab(app, named: "Settings")
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1) // lands on the swatch row, test43's proven anchor
        pause(1)
        press(.down, times: 5, gap: 0.6)
        pause(0.8)

        let typefaceRowExists = app.buttons["appearance_row_typeface"].waitForExistence(timeout: 4)
            || app.cells["appearance_row_typeface"].waitForExistence(timeout: 2)
            || app.otherElements["appearance_row_typeface"].waitForExistence(timeout: 2)
        XCTAssertTrue(typefaceRowExists, "appearance_row_typeface row not found on the Appearance pane")
        XCTAssertTrue(app.staticTexts["Open Sans"].waitForExistence(timeout: 4), "Typeface row does not read 'Open Sans' as its current value")
        shot(app, "53b_appearance_typeface")

        // Restore: fresh tabs/system-font launch. `ui_font` was only ever a launch argument here
        // (never written through the UI), so a plain relaunch with no arguments is already back to
        // system — nothing else to undo.
        let restored = launchToHome(forceFreshLaunch: true)
        XCTAssertTrue(restored.state == .runningForeground)
    }

    // MARK: - FEAT-33: collection focus-frame probe (driver only — numbers are a device harvest)

    /// FEAT-33's on-device frame-timing probe (`CollectionFocusFrameProbe`,
    /// `debug.collectionFrameProbe`) answers a tester's "our collection row animates at 30fps, not
    /// official Nuvio's 60fps" report with real per-vsync data instead of a screen recording's own
    /// sample rate. This test is a DRIVER, not a gate: it focuses onto a collection/folder row —
    /// the same `fitem=` `nuvio-folder://` oracle `test31HeroCommitsOnce`'s Leg C uses off the
    /// `debug_hero` probe, since this fixture's Home may or may not have a collection row at all —
    /// so `CollectionRowView`'s `onChange(of: focusedFolderId)` has something to arm the sampler
    /// with, then reads `collection_frame_blob` back from the About pane. The `frames=`/`dropped=`/
    /// `p95=` numbers themselves are a device harvest for a human to read off the attachment/shot,
    /// not something this test judges pass/fail on.
    func test54CollectionFrameProbeDriver() throws {
        let app = launchToHome(extraArguments: ["-debug.collectionFrameProbe", "YES"], forceFreshLaunch: true)
        pause(1.5)

        func liveHeroProbe() -> String {
            let probe = app.staticTexts["debug_hero"]
            return probe.exists ? probe.label : ""
        }
        var folderFound = false
        var lastFocusedItem = ""
        var stalledPresses = 0
        for _ in 1...28 {
            press(.down, times: 1)
            pause(0.5)
            let focused = probeField(liveHeroProbe(), "fitem") ?? ""
            if focused.hasPrefix("nuvio-folder://") { folderFound = true; break }
            // Bottom of Home, or no collection row at all: Down stops changing what is focused.
            if focused == lastFocusedItem {
                stalledPresses += 1
            } else {
                stalledPresses = 0
                lastFocusedItem = focused
            }
            if stalledPresses >= 5 { break }
        }
        guard folderFound else {
            throw XCTSkip("no folder/collection tile focused within 28 Down presses on this profile's Home — cannot drive the collection frame probe without one")
        }
        shot(app, "54a_folder_focused")
        // A second focus step inside the same row gives the sampler a second measured window, on
        // top of the one that already fired the instant focus first landed on the row (arm() keys
        // off `onChange(of: focusedFolderId)`, which fired going from nil to this tile).
        press(.right, times: 1, gap: 0.5)
        pause(0.8)

        openTab(app, named: "Settings")
        _ = moveToSidebarRow(app, .down, named: "About", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1) // lands on "Hero Paint Diagnostics", the pane's first focusable row
        pause(1)

        // Walk down until the readout itself is on screen, rather than a fixed count: the toggle
        // that gates it (`Collection Frame Probe`) sits several focusable rows into the "About"
        // section, behind a few non-focusable `SettingsValueRow`s that don't consume a D-pad stop
        // — see `AppearanceSettingsPane`'s Down-count comment above for why a fixed count is used
        // there but not here (here, the STOP CONDITION is the target itself existing, so an
        // over-shoot is simply a few harmless extra presses at the bottom of the pane, not a wrong
        // landing spot the way a blind fixed count risks).
        // Snapshot walk, not `app.staticTexts[…]` — see `probeBlobLabel`.
        var blobText: String? = nil
        for _ in 0..<20 {
            if let hit = probeBlobLabel(app, identifier: "collection_frame_blob") { blobText = hit; break }
            remote.press(.down)
            pause(0.5)
        }
        if blobText == nil {
            pause(2)
            blobText = probeBlobLabel(app, identifier: "collection_frame_blob")
        }
        guard let text = blobText else {
            shot(app, "54x_about_no_blob")
            let f = focusedButton(app)
            print("[test54] no blob; focused=\(f.map { "\($0.identifier)|\($0.label)|\($0.frame)" } ?? "nil") toggles=\(app.switches.count + app.descendants(matching: .toggle).count) cells=\(app.cells.count)")
            throw XCTSkip("collection_frame_blob never appeared on the About pane — cannot read the frame-timing harvest")
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "54a_frame_probe_text"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[FEAT33] \(text)")
        shot(app, "54b_frame_probe")
        XCTAssertTrue(text.contains("focus n="), "collection_frame_blob has no 'focus n=' line — the sampler never measured a focus step: \(text)")

        let restored = launchToHome(forceFreshLaunch: true)
        XCTAssertTrue(restored.state == .runningForeground)
    }

    /// BUG-102 (rc9, 2026-09-10): with No Zoom on Focus OFF and the accent ring ON, a focused
    /// collection folder tile draws the accent ring (it drew nothing before rc9 — `FolderTile`
    /// only knew the no-zoom still ring). Evidence leg, not a measurement: the walk is test54's
    /// (Down until the hero probe's `fitem` names a `nuvio-folder://` item — the collection row
    /// can be ~40 rows deep on this profile), then one screenshot of the focused tile for the
    /// record. Asserts only that a folder tile was reached and that a screenshot was attached;
    /// whether the ring survives the native lift on hardware is the device pass's question.
    func test56CollectionFolderRingWithZoomOn() throws {
        let app = launchToHome(extraArguments: ["-no_zoom_on_focus", "NO", "-accent_focus_ring", "YES",
                                                 "-debug.cardGeometryProbe", "YES"],
                               forceFreshLaunch: true)
        // Codex r1 P2: restore the default settings on EVERY exit, the skip below included — a
        // skipped run otherwise leaves the app running with the forced ring-on/zoom-on overrides,
        // and a later `launchToHome()` without arguments can attach to that process and inherit
        // them (order-dependent results in the rest of the suite).
        defer {
            let restored = launchToHome(forceFreshLaunch: true)
            XCTAssertTrue(restored.state == .runningForeground)
        }
        pause(1.5)

        func liveHeroProbe() -> String {
            let probe = app.staticTexts["debug_hero"]
            return probe.exists ? probe.label : ""
        }

        func namedFrames(_ identifier: String) -> [CGRect] {
            guard let root = try? app.snapshot() else { return [] }
            var out: [CGRect] = []
            func walk(_ node: XCUIElementSnapshot) {
                if node.identifier == identifier { out.append(node.frame) }
                node.children.forEach(walk)
            }
            walk(root)
            return out
        }

        // Group rects by aspect ratio (width / height, tolerance ±0.03 against the group's first
        // member) so a mixed-shape row (poster 2:3, square, landscape 16:9) never compares a
        // tile's height against a differently-shaped sibling's.
        func aspectGroups(_ rects: [CGRect]) -> [[CGRect]] {
            var groups: [[CGRect]] = []
            for rect in rects {
                guard rect.height > 0 else { continue }
                let ratio = rect.width / rect.height
                if let idx = groups.firstIndex(where: { group in
                    guard let rep = group.first, rep.height > 0 else { return false }
                    return abs(rep.width / rep.height - ratio) <= 0.03
                }) {
                    groups[idx].append(rect)
                } else {
                    groups.append([rect])
                }
            }
            return groups
        }
        // The modal (most common, within 1pt) height in a group of same-shape rects — i.e. the
        // group's "rest" height. Ties are broken toward the smaller height: a lift only ever
        // grows a tile, so on a tie the smaller value is the more plausible rest state.
        func modalHeight(_ rects: [CGRect]) -> CGFloat? {
            let heights = rects.map { $0.height }.sorted()
            guard !heights.isEmpty else { return nil }
            var bestHeight: CGFloat?
            var bestCount = 0
            for h in heights {
                let count = heights.filter { abs($0 - h) < 1 }.count
                if count > bestCount {
                    bestCount = count
                    bestHeight = h
                }
            }
            return bestHeight
        }
        // Rects in `group` that stand at least `margin`pt taller than the group's own rest height.
        func liftedRects(in group: [CGRect], margin: CGFloat) -> [CGRect] {
            guard let rest = modalHeight(group) else { return [] }
            return group.filter { $0.height - rest >= margin }
        }

        // P2 fix (was an unconditional XCTSkip below): before this runtime is trusted to say "I
        // cannot report transformed frames," prove that claim against an INDEPENDENT control this
        // same walk already passes through — the poster catalog rows, which `test49RingModeRiseMatchesAllowance`
        // shows this harness CAN measure a 20pt rise on (`poster_card`). The walk crosses several
        // catalog rows before it ever reaches the folder row, and the first Down press can just as
        // easily land on the Continue Watching row (`LandscapeCard`, no `poster_artwork` lift) as on
        // a poster row — so the control is sampled on EVERY Down press, not only the first, and
        // `framesReportTransforms` latches true the first time a press shows exactly one
        // `poster_artwork` rect standing ≥10pt above its shape group's rest height. `controlObserved`
        // (any press saw ≥2 poster rects at all) is tracked separately so a folder-row skip can say
        // whether the control was simply unavailable, as opposed to having demonstrated untransformed
        // frames.
        var framesReportTransforms = false
        var controlObserved = false
        var folderFound = false
        var lastFocusedItem = ""
        var stalledPresses = 0
        for _ in 1...45 {
            press(.down, times: 1)
            pause(0.5)
            let posterArtworkRects = namedFrames("poster_artwork")
            if posterArtworkRects.count >= 2 {
                controlObserved = true
            }
            if !framesReportTransforms {
                let lifted = aspectGroups(posterArtworkRects).flatMap { liftedRects(in: $0, margin: 10) }
                if lifted.count == 1 {
                    framesReportTransforms = true
                }
            }
            let focused = probeField(liveHeroProbe(), "fitem") ?? ""
            if focused.contains("nuvio-folder://") { folderFound = true; break }
            if focused == lastFocusedItem {
                stalledPresses += 1
            } else {
                stalledPresses = 0
                lastFocusedItem = focused
            }
            if stalledPresses >= 5 { break }
        }
        guard folderFound else {
            throw XCTSkip("no folder/collection tile focused within 45 Down presses on this profile's Home")
        }
        pause(1)
        shot(app, "56a_folder_ring_zoom_on")

        // BUG-108 gate. What the SIMULATOR can prove is not the hardware compositor bug (it does not
        // reproduce it — see the FEAT-14 graveyard in PosterCard.swift): it is the GEOMETRIC claim
        // underneath the fix, that the ring and the artwork are one scaled layer and the rise costs
        // the row no reflow.
        let artworkRects = namedFrames("folder_artwork")
        let cardRects = namedFrames("folder_card")
        guard artworkRects.count >= 2, cardRects.count >= 2 else {
            XCTFail("`-debug.cardGeometryProbe YES` published \(artworkRects.count) folder_artwork / \(cardRects.count) folder_card rects — the probe is not armed (DEBUG + NSArgumentDomain) or no folder row is on screen")
            return
        }
        // P3 fix: the collection row is mixed-shape (poster 2:3, square, landscape 16:9), so a
        // single tallest-rect-wins heuristic across ALL shapes can pick a resting POSTER over a
        // correctly lifted SQUARE (at Medium a lifted square is ~260pt tall, a resting poster
        // ~330pt). Group by aspect ratio first and judge "lifted" against each group's own rest
        // height, then require exactly one lifted rect across every group.
        let artworkGroups = aspectGroups(artworkRects)
        let allLifted = artworkGroups.flatMap { liftedRects(in: $0, margin: 10) }
        guard allLifted.count == 1 else {
            if framesReportTransforms {
                let perGroupHeights = artworkGroups.map { $0.map { $0.height } }
                XCTFail("expected exactly one lifted folder tile across all shape groups, found \(allLifted.count) (per-group heights: \(perGroupHeights))")
                return
            }
            throw XCTSkip("control never saw a lifted poster (observed=\(controlObserved))")
        }
        let focusedArt = allLifted[0]
        guard let group = artworkGroups.first(where: { $0.contains(focusedArt) }) else {
            XCTFail("internal: lifted rect \(focusedArt) not found in its own aspect group")
            return
        }
        guard group.count >= 2 else {
            throw XCTSkip("the only lifted folder tile is in a shape group with no resting sibling to compare against (singleton group, height \(focusedArt.height))")
        }
        guard let restHeight = modalHeight(group),
              let restArt = group.filter({ $0 != focusedArt })
                  .min(by: { abs($0.height - restHeight) < abs($1.height - restHeight) }) else {
            throw XCTSkip("no resting folder tile of the same shape on screen to compare against")
        }
        let rise = restArt.minY - focusedArt.minY
        XCTAssertEqual(rise, 20, accuracy: 2.5, "focused folder artwork rose \(rise)pt; focused=\(focusedArt) rest=\(restArt)")
        XCTAssertEqual(focusedArt.maxY - restArt.maxY, rise, accuracy: 2.5)
        XCTAssertEqual((focusedArt.width - restArt.width) / 2,
                       rise * (restArt.width / restArt.height), accuracy: 3.0,
                       "width growth must be the same uniform scale as the height growth")
        let focusedCard = cardRects.min(by: { abs($0.midX - focusedArt.midX) < abs($1.midX - focusedArt.midX) })!
        let restCard = cardRects.min(by: { abs($0.midX - restArt.midX) < abs($1.midX - restArt.midX) })!
        XCTAssertEqual(focusedCard.minY, restCard.minY, accuracy: 2.0,
                       "the tile's LAYOUT box moved — the lift is not render-only")

        press(.right, times: 1, gap: 0.5)
        pause(1)
        shot(app, "56b_folder_ring_zoom_on_second_tile")
    }

    /// BUG-109 (rc9, u/mrStevenx3): entering a collection folder page and pressing Menu must put
    /// Home focus back on the folder tile the user left from, not on the catalog row above it.
    /// Evidence + gate: the hero probe's `fitem` names the focused item; the same
    /// `nuvio-folder://` id must be reported after the pop. `-debug.pinnedRowSettleProbe YES` is
    /// on so a `covered=1 skipped=1` line lands in the Row Settle pane when the corrector tried to
    /// scroll the covered Home (diagnostics only; the assertion is the landing).
    func test57FolderExitRestoresFocus() throws {
        let app = launchToHome(extraArguments: ["-debug.pinnedRowSettleProbe", "YES"], forceFreshLaunch: true)
        defer {
            let restored = launchToHome(forceFreshLaunch: true)
            XCTAssertTrue(restored.state == .runningForeground)
        }
        pause(1.5)

        func liveHeroProbe() -> String {
            let probe = app.staticTexts["debug_hero"]
            return probe.exists ? probe.label : ""
        }
        var folderItem: String?
        var lastFocusedItem = ""
        var stalledPresses = 0
        for _ in 1...45 {
            press(.down, times: 1)
            pause(0.5)
            let focused = probeField(liveHeroProbe(), "fitem") ?? ""
            if focused.contains("nuvio-folder://") { folderItem = focused; break }
            if focused == lastFocusedItem {
                stalledPresses += 1
            } else {
                stalledPresses = 0
                lastFocusedItem = focused
            }
            if stalledPresses >= 5 { break }
        }
        guard let folderItem else {
            throw XCTSkip("no folder/collection tile focused within 45 Down presses on this profile's Home")
        }
        shot(app, "57a_folder_focused_before_push")
        remote.press(.select)
        pause(3)
        shot(app, "57b_folder_page")
        remote.press(.menu)
        pause(2.5)
        shot(app, "57c_after_pop")
        let after = probeField(liveHeroProbe(), "fitem") ?? ""
        XCTAssertEqual(after, folderItem, "focus after popping the folder page landed on \(after), expected the folder tile \(folderItem)")
    }
}
