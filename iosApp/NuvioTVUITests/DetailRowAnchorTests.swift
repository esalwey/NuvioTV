import XCTest

/// BUG-96 (beta.18): on the detail page, a vertical focus move must leave every section header
/// either fully on screen or fully off it — never straddling the top edge (the tester's photos:
/// "Guide parental" cut in half above a focused Saga row) — and the focused row's title must rest
/// near `DetailRowAnchor.topInset`.
///
/// BUG-99 (rc6): the direction split changed what "at rest" means for a Down press. Down no
/// longer anchors by default — the engine's own minimal reveal is left alone unless it would
/// leave the header straddling the top scrim — so the Down walk below no longer expects every
/// step to land within ±16 of `DetailRowAnchor.screenRest`; it instead asserts the row never rests
/// ABOVE the rest, and that the probe's `anchor=… free` reading actually fires on at least two of
/// the six presses (proof the new decision is being exercised, not just never triggering). Up is
/// unchanged — it must still anchor every time — so an Up leg is appended after the Down walk to
/// cover that.
///
/// Oracle: XCUI frames of the section-title `staticTexts` at rest after each press. The tvOS
/// 27 runtime never reports `hasFocus`, so the leg does not identify the focused row; it asserts
/// the invariant every title must satisfy, plus that SOME title sits at the anchor band once focus
/// has left the top block. The detail page is recognised by its DEBUG-only `debug_ux6` probe.
final class DetailRowAnchorTests: XCTestCase {
    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication()
        // Deterministic row geometry: no Upcoming row, so down×4 lands on a movies catalog row
        // (the same trick TrailerSoakTests / RowLeadingEdgeTests use).
        // No trailer anywhere: the detail page otherwise auto-enters the full-screen cover
        // (FEAT-32) a few seconds in, and the Down walk would be pressing inside it.
        // `forceNoTrailer` is honoured only alongside `debug.trailerProbe`.
        app.launchArguments += ["-home_upcoming_row_enabled", "NO",
                                "-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES",
                                "-debug.detailScrollProbe", "YES"]
        app.launch()
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10)
        return app
    }

    /// `key=<number>` out of the probe label (first occurrence).
    private func probeNumber(_ label: String, key: String) -> Double? {
        guard let range = label.range(of: key) else { return nil }
        let tail = label[range.upperBound...]
        let token = tail.prefix { $0 == "-" || $0 == "." || $0.isNumber }
        return Double(token)
    }

    /// Section-title candidates: single-line labels at the section-title size. Cards' captions are
    /// shorter and posters are not staticTexts, so a height band is a stable enough filter here.
    private func sectionTitleFrames(_ app: XCUIApplication) -> [(label: String, frame: CGRect)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(String, CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText {
                let f = node.frame
                if f.height >= 30, f.height <= 64, f.width >= 80, f.width <= 900, !node.label.isEmpty {
                    out.append((node.label, f))
                }
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    func testDownWalkNeverLeavesAHeaderStraddlingTheTopEdge() throws {
        let app = launchToHome()
        // test02's route to a real DetailView: a movies catalog row (portrait cards → NavigationLink).
        press(.down, times: 4)
        pause(0.5)
        remote.press(.select)
        pause(8)
        guard app.staticTexts["debug_ux6"].waitForExistence(timeout: 6) else {
            throw XCTSkip("no detail page opened (debug_ux6 probe absent) — the down×4 walk did not land on a movies row on this fixture; nothing to measure")
        }
        // FEAT-32: the page auto-enters the full-screen trailer cover a few seconds in (its caption
        // carries the Back hint). `forceNoTrailer` does not gate that path, so back out of the
        // cover once and settle before walking; the auto-entry fires once per page.
        // The Back hint element persists on the page (it is the cover's caption, kept mounted), so
        // its presence is not proof the cover is up; press Menu once regardless — on the page it is
        // a no-op for focus, inside the cover it returns to the page.
        pause(6)
        if app.staticTexts["Press Back to exit the trailer"].exists {
            remote.press(.menu)
            pause(3)
        }
        // AES-10: a synopsis longer than four lines adds its More / Less pill as a focus stop
        // between the action row and the rows below. Step onto it first, so the six-press walk
        // below starts where it always has: one press from the first row.
        if app.buttons["detail.overview.toggle"].exists {
            press(.down, times: 1, gap: 1.4)
        }

        var anchorSamples = 0
        var anchoredRows = Set<String>()
        var straddles: [String] = []
        // BUG-96 rc5 regression fix: `moves=` is `DetailScrollMotion.segments` over this focus
        // visit's raw offset samples — `1` means the engine's reveal and the anchor pass blended
        // into one motion, `2`+ means the old land-then-nudge two-step move is back. Kept alongside
        // the `(top − off) − 108` residual per step so both survive in the failure message and in
        // an attachment even when the run passes. BUG-99: both are now tagged by `direction` since
        // the Down walk and the Up leg below are measured with the same arrays.
        var movesByStep: [(step: Int, direction: String, moves: Int)] = []
        var residualByStep: [(step: Int, direction: String, residual: Double)] = []
        // BUG-99 rc6: how many of the Down presses read `anchor=… free` on the probe — i.e. the
        // engine's own minimal reveal was left alone rather than pulled up to the anchor. At least
        // some of the six presses on a typical detail page (short rows, no straddle) must land
        // here, or the new decision is never actually being exercised by this walk.
        var downFreeSteps = 0
        // Only the anchored rows' section titles are the oracle; the top block's details grid
        // (Network, Country, …) is not an anchored row.
        let sectionLabels: Set<String> = ["Parental Guide", "Guide parental", "Cast", "Casting", "Episodes", "Épisodes",
                                          "Trailers & Extras", "Bandes-annonces et extras", "More Like This", "Comments"]

        for step in 1...6 {
            press(.down, times: 1, gap: 1.4)
            let titles = sectionTitleFrames(app).filter { sectionLabels.contains($0.label) || $0.label.hasSuffix("Saga") || $0.label.hasSuffix("Collection") }
            for (label, f) in titles {
                // Straddling: the top edge cuts through the title's own glyph box AND the title sits
                // below the top scrim's opaque zone (a header under the scrim is faded away, not cut).
                if f.minY > 40, f.minY < f.height * 0.8 {
                    straddles.append("step \(step) (down): '\(label)' minY=\(Int(f.minY)) h=\(Int(f.height))")
                }
            }
            // The anchor oracle reads the app's own probe: `anchor=<row> top=<content y> …` and
            // `geo=off=<content offset>`; the focused row's screen top is `top − off`. On Down,
            // BUG-99 no longer expects this to land at `DetailRowAnchor.screenRest` (108) on every
            // press — only that it never rests ABOVE the rest (a residual below -16 would mean the
            // header was pushed past the anchor band, the pre-blend-fix symptom), and that the
            // probe's `free` note actually shows up more than once across the six presses. Title
            // heuristics are not used for this — rows whose top is not a title (season chips,
            // logos) and titles the accessibility walk does not list (Cast) would make it vacuous.
            let probeLabel = app.staticTexts["debug_ux6"].exists ? app.staticTexts["debug_ux6"].label : ""
            if let top = probeNumber(probeLabel, key: "top="), let off = probeNumber(probeLabel, key: "off=") {
                anchorSamples += 1
                let residual = (top - off) - 108
                residualByStep.append((step, "down", residual))
                // Codex BUG-96 r3 (P3): a stuck focus would repeat one good sample on every press —
                // the walk must reach DISTINCT rows, not the same one six times.
                if let range = probeLabel.range(of: "anchor=") {
                    let row = probeLabel[range.upperBound...].prefix { $0 != " " }
                    anchoredRows.insert(String(row))
                }
                // The `debug_ux6` label reads `anchor=<row> top=<t> free geo=…` for a `.free`
                // decision (see `DetailView`'s `String(format: "%@ top=%.0f free", …)`), so " free
                // geo=" is present exactly when this step's decision was `.free`.
                if probeLabel.contains(" free geo=") { downFreeSteps += 1 }
                // BUG-96 rc5: the motion-segment count sampled alongside this same at-rest probe
                // read — `debug_ux6`'s `geo=` mirrors `dimModel.geometrySample`, which carries
                // `moves=` (see `DetailView`'s scroll-geometry handler).
                if let moves = probeNumber(probeLabel, key: "moves=") {
                    movesByStep.append((step, "down", Int(moves)))
                }
            }
            let visible = titles.filter { $0.frame.minY >= 0 && $0.frame.maxY <= 1080 }.map { "\($0.label)@\(Int($0.frame.minY))" }
            let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shotAttachment.name = "bug99_down_step\(step)"
            shotAttachment.lifetime = .keepAlways
            add(shotAttachment)
            let probe = app.staticTexts["debug_ux6"]
            print("[BUG99] down step \(step) titles=\(visible) probe=\(probe.exists ? probe.label : "-")")
        }
        XCTAssertGreaterThanOrEqual(anchorSamples, 4, "BUG-96: the probe never reported a row — is -debug.detailScrollProbe on?")
        XCTAssertGreaterThanOrEqual(anchoredRows.count, 3,
                                    "BUG-96: the Down walk must reach at least three DISTINCT rows (saw \(anchoredRows.sorted())) — a repeated sample means focus was stuck")

        // BUG-99 (rc6): replaces the old "residual within ±16 on nearly every step" rule, which
        // assumed Down always anchors — it doesn't any more. What must still hold on Down: the row
        // never rests ABOVE `DetailRowAnchor.screenRest` (that would be the ORIGINAL BUG-96
        // straddle, not the two-step-motion regression the blend fix already closed), and the
        // straddle-only-when-needed decision must actually be exercised at least twice in six
        // presses.
        let downResiduals = residualByStep.filter { $0.direction == "down" }
        let aboveRestSteps = downResiduals.filter { $0.residual < -16 }
        XCTAssertTrue(aboveRestSteps.isEmpty,
                      "BUG-99: a Down step rested the row ABOVE DetailRowAnchor.screenRest (108) — " +
                      "\(aboveRestSteps.map { "step\($0.step)=\(String(format: "%.0f", $0.residual))" })")
        XCTAssertGreaterThanOrEqual(downFreeSteps, 2,
                                    "BUG-99: at least two of the six Down presses must leave the engine's own minimal reveal alone (anchor=… free) — saw \(downFreeSteps)")

        // BUG-99: Up is unchanged — it must still anchor every time, exactly like every row did
        // before rc6. Same oracle, appended as its own leg after the Down walk.
        for step in 1...3 {
            press(.up, times: 1, gap: 1.4)
            let titles = sectionTitleFrames(app).filter { sectionLabels.contains($0.label) || $0.label.hasSuffix("Saga") || $0.label.hasSuffix("Collection") }
            for (label, f) in titles {
                if f.minY > 40, f.minY < f.height * 0.8 {
                    straddles.append("step \(step) (up): '\(label)' minY=\(Int(f.minY)) h=\(Int(f.height))")
                }
            }
            let probeLabel = app.staticTexts["debug_ux6"].exists ? app.staticTexts["debug_ux6"].label : ""
            if let top = probeNumber(probeLabel, key: "top="), let off = probeNumber(probeLabel, key: "off=") {
                let residual = (top - off) - 108
                residualByStep.append((step, "up", residual))
                if let moves = probeNumber(probeLabel, key: "moves=") {
                    movesByStep.append((step, "up", Int(moves)))
                }
            }
            let visible = titles.filter { $0.frame.minY >= 0 && $0.frame.maxY <= 1080 }.map { "\($0.label)@\(Int($0.frame.minY))" }
            let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shotAttachment.name = "bug99_up_step\(step)"
            shotAttachment.lifetime = .keepAlways
            add(shotAttachment)
            let probe = app.staticTexts["debug_ux6"]
            print("[BUG99] up step \(step) titles=\(visible) probe=\(probe.exists ? probe.label : "-")")
        }
        let upResiduals = residualByStep.filter { $0.direction == "up" }
        XCTAssertGreaterThanOrEqual(upResiduals.count, 2, "BUG-99: the Up leg never reported a probe sample — is -debug.detailScrollProbe on?")
        for entry in upResiduals {
            XCTAssertLessThanOrEqual(abs(entry.residual), 16,
                                     "BUG-99: Up step \(entry.step) must anchor to DetailRowAnchor.screenRest (108) — residual \(String(format: "%.0f", entry.residual))")
        }

        XCTAssertTrue(straddles.isEmpty, "BUG-96: a section header straddled the top edge at rest — \(straddles)")

        // Numbers first, so they survive a PASSING run too — the experiment report needs the
        // moves= distribution and residuals per direction regardless of outcome, not just on
        // failure.
        let movesDescription = movesByStep.map { "\($0.direction)\($0.step)=\($0.moves)" }.joined(separator: " ")
        let residualDescription = residualByStep.map { "\($0.direction)\($0.step)=\(String(format: "%.0f", $0.residual))" }.joined(separator: " ")
        XCTContext.runActivity(named: "BUG-99 moves= distribution and (top-off-108) residuals, Down then Up") { activity in
            let attachment = XCTAttachment(string: "moves: \(movesDescription)\nresiduals(top-off-108): \(residualDescription)\ndownFreeSteps: \(downFreeSteps)/\(downResiduals.count)")
            attachment.name = "bug99_moves_and_residuals"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print("[BUG99] moves=\(movesDescription) residuals=\(residualDescription) downFreeSteps=\(downFreeSteps)")

        // The blend fix's whole point (unchanged by BUG-99): every at-rest sample, on either
        // direction, reads as ONE motion. `moves=2`+ is the land-then-nudge regression rc5 reported.
        let multiMoveSteps = movesByStep.filter { $0.moves > 1 }
        XCTAssertTrue(multiMoveSteps.isEmpty,
                      "BUG-96: a focus move landed in more than one visible motion (land-then-nudge) — " +
                      "steps \(multiMoveSteps.map { "\($0.direction)\($0.step)=\($0.moves)" }) — full distribution moves: \(movesDescription) residuals(top-off-108): \(residualDescription)")

        remote.press(.menu)
        pause(1)
    }
}
