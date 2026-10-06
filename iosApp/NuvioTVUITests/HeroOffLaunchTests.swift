import XCTest

/// BUG-86 hero-off rows (beta.18): the "Show Hero" OFF launch, which `test31HeroCommitsOnce` does
/// not cover and structurally cannot.
///
/// The tester runs Home with Show Hero off, so the top of the screen is the FEAT-15 focus panel
/// (`HomeView.swift`'s `focusHeroActive`), whose resting title is the first item of the first
/// CATALOG row — falling back to Continue Watching, then to a collection folder. His build-117
/// Hero Paint Diagnostics photo:
///
///     1539ms  addonsChanged ready=5 catalogs=18
///     1700ms  rows vm=1 n=2 first=collection_… settingsSig=7805ec5f heldRebuilds=3
///     1830ms  present item=nuvio.folder:… / paint kind=seededPrimary first=1
///     2477ms  rows n=6 first=tmdb-addon:movie:… settingsSig=f2774137
///     2703ms  present item=movie:tt37752275 / paint kind=image first=0 same=0
///
/// No `publish` line and no `commit` line at all, because `HomeViewModel`'s probe only logged
/// hero-BEARING publishes and there is no hero here. The rows gate opened at 1.7 s on a
/// partially-settled catalog set, the launch sync burst reordered the rows at 2.5 s, and the focus
/// panel repainted with a different title. That is the doubled hero this whole protocol exists to
/// prevent, one layer down — the panel's title is a function of the row order, so gating the hero
/// while leaving the rows free never covered this profile.
///
/// The fix holds the ROWS through a `heroOff`/`noSources` release until the launch sync burst has
/// settled (or the same 4 s budget expires), and adds the hero-empty `publish` probe line that
/// carries `gate=`/`rowsWait=` into the About pane. This test asserts that shape end to end.
///
/// Helper methods here are a trimmed COPY of `NuvioTVUITests`' (`launchToHome`, `press`, `pause`,
/// `shot`, `openTab`, `moveFocus`, `heroProbeLines`, `probeKind`, `probeField`, `probeStampMs`)
/// rather than a shared import — they are `private` to that file, and this harness already accepts
/// duplication over factoring out cross-file test helpers (same rationale `TrailerSoakTests`
/// states in its own type doc). Like that file's copy, `launchToHome` here is deliberately the
/// simple always-fresh-`launch()` form: every assertion below depends on the debug launch
/// arguments actually being in effect for a COLD launch, which the suite-order recovery dance in
/// `NuvioTVUITests` cannot guarantee.
final class HeroOffLaunchTests: XCTestCase {

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
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// From Home content, walk up to the tab bar, right to the wanted tab, and enter it. Copy of
    /// `NuvioTVUITests.openTab` — the climb is existence-driven rather than a fixed Up count for
    /// the reason documented there (a fixed count cannot leave a long Settings pane, and Up past
    /// the tab bar is a harmless no-op).
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

    @discardableResult
    private func launchToHome(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        app.launch()
        // Session restore + profile fetch can take well past 15s on a cold sim launch (the same
        // wait `NuvioTVUITests.launchToHome` and `TrailerSoakTests` both use).
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90),
                      "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        return app
    }

    /// Reads the `hero_probe_lines` container off Settings › About. Copy of
    /// `NuvioTVUITests.heroProbeLines`, including the `hero_probe_blob` preference: the List row
    /// clips below the fold, so the per-line `Text` children beyond it never enter the AX tree and
    /// a container walk alone sees only the first line. One hidden `Text` = one AX element = the
    /// whole buffer in its label.
    private func heroProbeLines(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
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
        var container: XCUIElementSnapshot?
        func findContainer(_ node: XCUIElementSnapshot) {
            guard container == nil else { return }
            if node.identifier == "hero_probe_lines" {
                container = node
                return
            }
            for child in node.children { findContainer(child) }
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

    /// The probe line's TYPE token — the second whitespace-separated token, right after the leading
    /// `<N>ms` stamp (`vm`, `publish`, `commit`, `rows`, `present`, `paint`).
    private func probeKind(_ line: String) -> String? {
        let tokens = line.split(separator: " ")
        return tokens.count > 1 ? String(tokens[1]) : nil
    }

    /// Reads a single `key=value` token, tolerant of token ORDER — see
    /// `NuvioTVUITests.probeField`'s doc for why a fixed-position parse breaks on these lines.
    /// Returns the FIRST match, which matters only on `publish`, whose own leading fields precede
    /// `HomeRepository.heroRankingDebug`'s space-separated tokens.
    private func probeField(_ line: String, _ key: String) -> String? {
        let prefix = "\(key)="
        for token in line.split(separator: " ") where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    private func probeStampMs(_ line: String) -> Int? {
        guard let range = line.range(of: "ms ") else { return nil }
        return Int(line[line.startIndex..<range.lowerBound])
    }

    /// A genuine repaint — excludes `paint suppressed …`, which is the crossfade correctly
    /// declining to repaint (evidence the invariant HELD, not evidence it broke). Copy of
    /// `NuvioTVUITests.isRealPaintLine`.
    private func isRealPaintLine(_ line: String) -> Bool {
        let tokens = line.split(separator: " ")
        guard tokens.count > 1, tokens[1] == "paint" else { return false }
        return tokens.count > 2 ? tokens[2] != "suppressed" : true
    }

    // MARK: - test31D

    /// A cold launch with the hero forced off and the launch sync burst replayed, asserting the
    /// hero-off photo contract (see `HomeViewModel.swift`'s hero-empty probe branch):
    ///
    ///   GOOD  `publish … n=0 … gate=released:heroOff rowsWait=settled rowsWaitMs≤4000`,
    ///         then exactly one `rows … rowsGate=open` carrying `heldRebuilds=`,
    ///         then one `present … same=0` and one `paint … first=1`.
    ///   BAD   a SECOND `rows` line whose `settingsSig=` moved, followed by a `present` line with a
    ///         different `item=` — the burst reordering the rows under a panel that had painted.
    ///
    /// `-debug.homeHeroOff YES` is applied through `HomeCatalogSettingsRepository.debugForceHeroOff`
    /// (never `setHeroEnabled(false)`, which persists and pushes), so the fixture profile is left
    /// exactly as it was found. `-debug.homeLaunchBurstSim YES` is the same offline burst replay
    /// `test31` Leg B uses, and it carries that leg's documented fixture-only mutation: it reverses
    /// the local Home row and collection order and turns "hide unreleased content" on. Nothing is
    /// pushed to the server, and the plain relaunch in the `defer` below lets the next real sync
    /// restore the account's true state — the same restore-and-verify shape Leg B ends with.
    func test31DHeroOffRowsWaitForSync() throws {
        let app = launchToHome(extraArguments: [
            "-debug.homeHeroProbe", "YES",
            "-debug.homeHeroOff", "YES",
            "-debug.homeLaunchBurstSim", "YES",
        ])
        defer {
            app.terminate()
            pause(1.0)
            // Fixture restore, same as test31 Leg B's: relaunch WITHOUT the burst or hero-off args
            // so the next real sync pulls the account's true row order back over the burst's
            // locally persisted reversal. Nothing is asserted — this leg's own assertions are all
            // above, and a failure here would only mask them.
            let restore = XCUIApplication()
            restore.launch()
            pause(20)
            restore.terminate()
        }

        // The gate's own budget is HERO_COMMIT_GATE_TIMEOUT_MS (4s) and the rows hold is bounded by
        // the same 4s from the first evaluation, so the launch window this test asserts on is over
        // inside ~6s. The extra time is the burst sim: on a hero-off profile
        // `HomeLaunchBurstSim.runBurst` waits for a non-empty hero publish that never arrives, so
        // it bursts one second after its own 6s timeout — reading the pane before that would leave
        // the app mutating its local row order while this test navigates into Settings.
        pause(12.0)
        shot(app, "31d_hero_off_settled")
        XCTAssertTrue(app.state == .runningForeground, "app must be alive after the rows hold's budget")

        openTab(app, named: "Settings")
        let about = app.buttons["About"]
        _ = moveFocus(.down, until: about, max: 8)
        press(.right, times: 1)
        pause(1.5)
        shot(app, "31d_about_probe")

        let lines = heroProbeLines(app)
        guard !lines.isEmpty else {
            XCTFail("31d: hero_probe_lines produced no readable lines — cannot verify the hero-off rows contract this run; see NuvioTVUITests.heroProbeLines' doc for why this can happen independent of whether HomeHeroProbe actually logged anything")
            return
        }
        // House pattern (`heroSrcProbe`, `readHeroProbeAboutPane`): attach the raw blob so a
        // device-pass-style read of THIS run is always in the result bundle, not only whichever
        // assertion happened to fail.
        let blob = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: blob)
        attachment.name = "31d_probe_lines_text"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[HeroProbe] 31d:\n\(blob)")

        // Scoped to the launch window the gate governs — the same 15s span
        // `assertHeroPhotoContract` uses, but measured from the `vm start` line rather than from
        // the process's own t0. `HomeHeroProbe.sinceLaunchMs` counts from PROCESS start, and this
        // test's launch spends an unbounded amount of that on the profile picker
        // (`waitForExistence(timeout: 90)`), so an absolute 15s cut can legitimately land before
        // the first Home publish and filter the whole launch away into a vacuous green.
        let launchStartMs = lines.first(where: { probeKind($0) == "vm" }).flatMap(probeStampMs) ?? 0
        let early = lines.filter { (probeStampMs($0) ?? Int.max) < launchStartMs + 15_000 }

        // 1. Exactly one rows-gate open. `RowsGate.open()` returns the held count on the first
        //    open only, so `heldRebuilds=` appears on exactly one line per open — which makes the
        //    count of those lines the count of opens, and a second one is the launch double-build.
        let opens = early.filter { probeKind($0) == "rows" && probeField($0, "heldRebuilds") != nil }
        XCTAssertEqual(opens.count, 1,
                       "31d: expected exactly one 'rows … rowsGate=open heldRebuilds=' line, found \(opens.count) — lines=\(early)")
        guard let openIdx = early.firstIndex(where: { probeKind($0) == "rows" && probeField($0, "heldRebuilds") != nil }) else {
            XCTFail("31d: no rows-gate open line found — the rows never published. lines=\(early)")
            return
        }
        XCTAssertEqual(probeField(early[openIdx], "rowsGate"), "open",
                       "31d: the heldRebuilds line must itself report rowsGate=open — \(early[openIdx])")

        // 2. The `publish` line immediately before it is the hero-off release, and it says the rows
        //    waited for the launch sync burst (or, on a slow/absent burst, that the budget bounded
        //    the wait — diagnosable, never silent, same tolerance test31 Leg B gives the hero).
        guard let publishIdx = early[0..<openIdx].lastIndex(where: { probeKind($0) == "publish" }) else {
            XCTFail("31d: no 'publish' line before the rows open — the hero-empty probe branch did not log, which is the exact hole the tester's build-117 photo had. lines=\(early)")
            return
        }
        let publish = early[publishIdx]
        XCTAssertEqual(probeField(publish, "gate"), "released:heroOff",
                       "31d: the publish that opens the rows must be the heroOff release — \(publish)")
        let rowsWait = probeField(publish, "rowsWait")
        XCTAssertTrue(rowsWait == "settled" || rowsWait == "timeout",
                      "31d: expected rowsWait ∈ {settled, timeout}, got \(rowsWait ?? "nil") — 'sync' here means the rows opened while still holding, 'n/a' means they were never gated — \(publish)")
        if let waitMs = probeField(publish, "rowsWaitMs").flatMap(Int.init) {
            // The contract is HERO_COMMIT_GATE_TIMEOUT_MS (4000). The slack is scheduling, not
            // tolerance for a longer hold: the rows timeout job resumes on Dispatchers.Default,
            // which the catalog fan-out and the enrichment fetches are saturating at exactly that
            // moment, and this shared build machine has been observed at load average 10-30 on 8
            // cores. What must never pass is an UNBOUNDED hold, which reads in the thousands above.
            XCTAssertLessThanOrEqual(waitMs, 6_000,
                                     "31d: the rows hold must be bounded by HERO_COMMIT_GATE_TIMEOUT_MS (4000ms + scheduling slack) — \(publish)")
        } else {
            XCTFail("31d: publish line carried no rowsWaitMs= field — \(publish)")
        }

        // 3. At most one present/paint pair before the rows open. The focus panel's seed is the
        //    first item of the first catalog row, so a paint BEFORE the rows are final is a paint
        //    of a title that is about to change — which is the whole bug. Zero is also correct
        //    (the panel has nothing to seed from until the rows publish).
        let presentsBefore = early[0..<openIdx].filter { probeKind($0) == "present" }
        let paintsBefore = early[0..<openIdx].filter(isRealPaintLine)
        // Gate-run refinement (beta.18): the first fixture run painted the CONTINUE WATCHING seed at
        // 5659 ms while the rows were still held (rowsWait=sync), then repainted the first catalog
        // row's title 850 ms later when the rows opened — the same double paint by another door.
        // `heroPanelSeed` now waits for the rows gate, so NO present may precede the rows open.
        XCTAssertEqual(presentsBefore.count, 0,
                       "31d: a 'present' line before the rows opened — the focus panel seeded (CW/folder) while the rows were still held — \(presentsBefore)")
        XCTAssertLessThanOrEqual(paintsBefore.count, 1,
                                 "31d: more than one 'paint' line before the rows opened — \(paintsBefore)")

        // 4. And nothing repaints a DIFFERENT title inside the window that follows. Anchored on the
        //    rows line rather than on an absolute stamp, because the profile picker eats an
        //    unbounded amount of `sinceLaunch`, and cut at +2.5s for two reasons:
        //      - the tester's second `present` landed 873ms after the first, so the signature this
        //        catches is comfortably inside it;
        //      - a LATER re-present is not this wave's bug. A focus move legitimately re-presents
        //        the panel (this test performs one, walking up to the tab bar for Settings), and a
        //        post-commit reorder is allowed by design — `RowsOrderRule` in NuvioTVUITests.swift
        //        is the oracle for that split. The burst sim in particular cannot land inside this
        //        window on a hero-off profile at all: `HomeLaunchBurstSim.runBurst` waits for a
        //        non-empty hero publish that never comes here, so it bursts one second after its
        //        own 6s timeout.
        // Gate-run refinement (beta.18, first leg D run on the fixture): a title move IS legitimate
        // once a `rows` line with a CHANGED `settingsSig=` has landed — that is a remote Home Rows
        // reorder (the burst sim's step 2, or a real second device), and the photo contract says the
        // same: "later sync-driven publish lines only if the settings signature changed". What this
        // wave forbids is a move with the settings order UNCHANGED, which is the launch-sync reorder
        // arriving after the rows gate opened — the tester's 2477 ms `rows` line.
        let openSig = probeField(early[openIdx], "settingsSig")
        let repaintWindowEndMs = (probeStampMs(early[openIdx]) ?? 0) + 2_500
        var sigChanged = false
        var violations: [String] = []
        var firstItem: String?
        for line in lines where (probeStampMs(line) ?? Int.max) <= repaintWindowEndMs {
            switch probeKind(line) {
            case "rows":
                if let sig = probeField(line, "settingsSig"), let openSig, sig != openSig { sigChanged = true }
            case "present":
                guard let item = probeField(line, "item") else { continue }
                if firstItem == nil { firstItem = item; continue }
                if item != firstItem, !sigChanged { violations.append(line) }
            default:
                continue
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "31d: a later 'present' line carried a different item than the first (\(firstItem ?? "-")) with the settings order UNCHANGED — the focus panel's resting title moved after first paint — \(violations)")
    }
}
