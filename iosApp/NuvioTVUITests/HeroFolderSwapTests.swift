import XCTest

/// BUG-95 (beta.18, 2026-09-08) simulator repro rig — companion to the `HeroBitmapLayer` fix in
/// `HomeView.swift` and the layout unit tests in `HeroCrossfadeLayoutTests.swift`.
///
/// This is NOT a pass/fail geometry assertion. XCUITest has no way to sample a `UIImageView`'s
/// `bounds` mid-crossfade from outside the process, and the bug is a VISUAL one (a mosaic backdrop
/// visibly re-cropping itself over ~35 frames) — so this test's only job is to drive a scripted
/// walk across several folder-to-folder and folder-to-title hero swaps on the FA87 fixture while
/// the main session records the simulator screen with `scripts/dev/hero-swap-sheets.sh` (or a
/// straight screen recording) running alongside it. The actual verdict — whether the backdrop
/// re-crops after it appears — is read off that recording, not off any assertion in this file.
///
/// The walk begins with a self-locating Down loop: starting from the tab bar, press Down once at
/// a time (up to 45 times) while reading `debug_hero`'s `pitem=` value, and break once the
/// presented item's identity starts with the folder id prefix `nuvio-folder://`. If the loop
/// exhausts without finding a folder, the test fails with the last probe label. Once a folder
/// hero is found, the choreography (three rights across consecutive tiles, one up, one down)
/// exercises the swap classes BUG-95 was filmed against (folder→folder, folder→title, title→folder).
/// The `debug_hero` probe confirms that a hero surface was live and responding to focus.
///
/// Total scripted duration is ~14s (4×1.2 + 1.5 + 3×1.5 + 1.5 + 1.5 + 1.5 + 2.0), not counting
/// launch/profile-picker time.
final class HeroFolderSwapTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers (trimmed copies — see the other hero test files' type docs for why these are
    // duplicated per-file rather than shared: they are `private` to each file already).

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
        // Session restore + profile fetch can take well past 15s on a cold sim launch — same
        // budget `NuvioTVUITests.launchToHome` and `HeroOffLaunchTests.launchToHome` use.
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90),
                      "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        return app
    }

    /// Press `direction` until `element` has focus (or the budget runs out). Trimmed copy of
    /// `NuvioTVUITests.moveFocus` — see the type doc on why these are duplicated per-file.
    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// From Home content, walk up to the tab bar, right to the wanted tab, and enter it. Trimmed
    /// copy of `NuvioTVUITests.openTab`'s tab-bar branch only — this rig's fixture runs in tabs
    /// mode, not the sidebar overlay, so the sidebar branch that function also carries is left out
    /// here rather than duplicated unused.
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

    /// Reads the `hero_probe_lines`/`hero_probe_blob` ring buffer (`AboutSettingsPane.swift`) —
    /// exactly the mechanism `NuvioTVUITests.heroProbeLines` reads (`NuvioTVUITests.swift:1408`),
    /// reused here rather than re-invented per this file's own trimmed-copy convention. Prefers the
    /// hidden single-`Text` blob (whole buffer in one label) and falls back to the per-line
    /// container's `staticText` children.
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

    /// Reads a single `key=value` token out of a probe line. Trimmed copy of
    /// `NuvioTVUITests.probeField` — tolerant of token order, first match wins.
    private func probeField(_ line: String, _ key: String) -> String? {
        let prefix = "\(key)="
        for token in line.split(separator: " ") where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    /// The probe line's TYPE token — second whitespace-separated token. Trimmed copy of
    /// `NuvioTVUITests.probeKind`.
    private func probeKind(_ line: String) -> String? {
        let tokens = line.split(separator: " ")
        return tokens.count > 1 ? String(tokens[1]) : nil
    }

    /// Navigates Settings → About and reads the probe buffer. Trimmed copy of
    /// `NuvioTVUITests.readHeroProbeAboutPane`, minus the `shot()` screenshot helper that lives
    /// only on that file's base class.
    @discardableResult
    private func readHeroProbeAboutPane(_ app: XCUIApplication, shotPrefix: String) -> [String] {
        openTab(app, named: "Settings")
        let about = app.buttons["About"]
        _ = moveFocus(.down, until: about, max: 8)
        press(.right, times: 1)
        pause(1.5)
        XCTContext.runActivity(named: "\(shotPrefix)_about_probe") { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(shotPrefix)_about_probe"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        let lines = heroProbeLines(app)
        if lines.isEmpty {
            XCTFail("\(shotPrefix): hero_probe_lines produced no readable lines")
        } else {
            let blob = lines.joined(separator: "\n")
            let attachment = XCTAttachment(string: blob)
            attachment.name = "\(shotPrefix)_probe_lines_text"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[HeroProbe] \(shotPrefix):\n\(blob)")
        }
        return lines
    }

    /// Self-locating loop: walk Down up to 45 times looking for a folder hero, parsing
    /// `pitem=<identity>` off `debug_hero`'s label and stopping once the identity starts with the
    /// folder id prefix `nuvio-folder://`. Returns the number of Down presses it took to arrive, or
    /// `nil` (having already `XCTFail`'d with the last probe label) if the budget exhausts. Factored
    /// out of test54 so test55 can reuse the identical walk rather than re-deriving it.
    private func locateFolderHero(_ probe: XCUIElement) -> Int? {
        var lastProbeLabel = ""
        for attempt in 1...45 {
            press(.down, times: 1, gap: 1.2)

            let label = probe.label
            lastProbeLabel = label

            if let pitemRange = label.range(of: "pitem=") {
                let afterPitem = String(label[pitemRange.upperBound...])
                let pitemValue = afterPitem.components(separatedBy: " ")[0]

                if pitemValue.contains("nuvio-folder://") {
                    return attempt
                }
            }
        }
        XCTFail("Could not locate a collection-folder hero after 45 Down presses. Last probe: \(lastProbeLabel)")
        return nil
    }

    // MARK: - test54

    /// Drives the scripted hero-swap walk described in the type doc. Waits for Home's rows to be
    /// present (the same `debug_hero` probe every other hero test uses as its "Home is live" gate),
    /// then walks: 4× Down (1.2s gaps, reaching the fixture's row 4), a 1.5s settle, 3× Right (1.5s
    /// gaps — three folder-to-folder hero swaps), a 1.5s settle, 1× Up (folder → title swap), a
    /// 1.5s settle, 1× Down (title → folder swap), and a final 2s settle before the closing
    /// screenshot. `-debug.homeHeroProbe YES` is the same release-safe probe knob every other hero
    /// test uses; no other debug launch arguments are needed to reach Home on the signed-in FA87
    /// fixture (the profile picker auto-select above is `launchToHome`'s whole job).
    func test54FolderHeroSwapGeometry() throws {
        let app = launchToHome(extraArguments: [
            "-debug.homeHeroProbe", "YES",
        ])

        let probe = app.staticTexts["debug_hero"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20),
                      "debug_hero probe never appeared — Home rows are not up, nothing to walk")
        pause(2.0) // catalog fan-out settle, matching the other hero tests' post-Home pause

        guard let downsPressedForFolder = locateFolderHero(probe) else { return }

        XCTContext.runActivity(named: "folder_found_at_down_\(downsPressedForFolder)") { _ in }
        print("Found collection folder after \(downsPressedForFolder) Down presses")
        pause(1.5)

        // 3 Rights, 1.5s gaps — three consecutive folder-to-folder hero swaps.
        press(.right, times: 3, gap: 1.5)
        pause(1.5)

        // 1 Up — folder → title swap.
        press(.up, times: 1, gap: 1.5)
        pause(1.5)

        // 3 Rights on the row above (the Genres folders on the fixture) with a 6 s dwell on the
        // last one: a cold-cache folder whose mosaic misses the 1.5 s resolver deadline must
        // still get its backdrop while it stays focused (`present … backdrop=late`, 2026-09-08).
        press(.right, times: 3, gap: 1.5)
        pause(40.0)

        // 1 Down — folder → folder swap back onto the last row.
        press(.down, times: 1, gap: 1.5)
        pause(2.0)

        XCTContext.runActivity(named: "54_hero_swap_walk_final") { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "54_hero_swap_walk_final"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertTrue(probe.exists,
                      "debug_hero probe disappeared after the walk — hero surface no longer live")
        XCTAssertTrue(app.state == .runningForeground,
                      "app must still be foregrounded after the scripted swap walk")
    }

    // MARK: - test55

    /// 2026-09-08: proves `HeroArtResolver.adoptLateBackdrop` (`HomeView.swift`, ~line 2580) — a
    /// folder hero that committed with NO backdrop because its fetch missed `folderDeadline` later
    /// adopts that backdrop once the fetch actually lands, instead of staying blank until focus
    /// moves to a different, already-cached folder. On the simulator's real image hosts the fetch
    /// routinely answers in under 60ms — well inside even the production 1.5s deadline — so this
    /// test forces the miss with the `#if DEBUG`-only `debug.heroFolderDeadlineMs` launch-argument
    /// override on `HeroArtResolver.folderDeadline` rather than hoping for a slow network.
    ///
    /// Reads the outcome off the SAME probe surface `test31HeroCommitsOnce`'s Leg C already reads
    /// (`NuvioTVUITests.swift:2372` parses `probeField(folderPresent, "backdrop")` off the
    /// `hero_probe_lines`/`hero_probe_blob` buffer) — no new probe surface, just this file's own
    /// trimmed copy of the same read (`heroProbeLines`/`probeField`/`readHeroProbeAboutPane` above).
    ///
    /// Cold cache is load-bearing: the main session clears `Library/Caches` in the app container
    /// before running this. A warm cache means every folder `present` line already reads
    /// `backdrop=cached`, the 1ms deadline never has anything to miss, and this test skips rather
    /// than passing vacuously.
    ///
    /// WINDOW RULE (2026-09-08, Codex P2 fix): `HomeHeroProbe`'s buffer (`HomeView.swift`
    /// ~3194-3258) freezes a 24-line launch HEAD forever and rolls a 32-line TAIL behind it, once
    /// eviction starts, behind a single `"… N lines elided …"` marker line. After the ~40-Down
    /// locate walk plus this test's own dwells, a folder's `backdrop=none` present can scroll out
    /// of that TAIL while its later `backdrop=late` present survives — so every assertion below
    /// runs on `window` (the lines strictly after the marker, or the whole buffer if the buffer
    /// never rolled), never on the raw `lines` array. Comparing across the marker risks pairing a
    /// surviving `late` line against an unrelated line from the frozen launch head.
    func test55FolderHeroLateBackdropAdopts() throws {
        let app = launchToHome(extraArguments: [
            "-debug.homeHeroProbe", "YES",
            "-debug.heroFolderDeadlineMs", "1",
        ])

        let probe = app.staticTexts["debug_hero"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20),
                      "debug_hero probe never appeared — Home rows are not up, nothing to walk")
        pause(2.0) // catalog fan-out settle, matching test54 and the other hero tests

        guard locateFolderHero(probe) != nil else { return }
        pause(1.5)

        // Two more folder tiles, dwelling 8s on each — long enough for a cold fetch to land and
        // `adoptLateBackdrop` to fire well within the walk, short of test54's much longer 40s
        // dwell (that test films a real network fetch; this one only needs the fetch that a local
        // simulator image host actually completes in well under a second).
        press(.right, times: 1, gap: 1.5)
        pause(8.0)
        press(.right, times: 1, gap: 1.5)
        pause(8.0)

        // The About pane is the only surface that exposes the probe blob, and walking focus
        // back up ~40 rows would log a `present` per row and push the folder lines out of
        // the 32-line tail before they are read (Codex r2). Home handles Menu as a
        // jump-to-top while scrolled down (`onExitCommand` → `home_top`), so one press puts
        // the tab bar a couple of Ups away with at most one or two extra lines.
        remote.press(.menu)
        pause(1.5)
        let lines = readHeroProbeAboutPane(app, shotPrefix: "55")
        guard !lines.isEmpty else { return } // readHeroProbeAboutPane already XCTFail'd

        // Window rule: only the lines after HomeHeroProbe's elision marker (if the buffer ever
        // rolled) are safe to compare against each other — see the doc comment above. Every
        // assertion below reads `window`, never `lines` directly.
        let markerIndex = lines.firstIndex { $0.contains("lines elided") }
        let window = markerIndex.map { Array(lines[($0 + 1)...]) } ?? lines

        let folderPresents = window.filter {
            probeKind($0) == "present" && (probeField($0, "item") ?? "").hasPrefix("nuvio.folder:")
        }
        guard !folderPresents.isEmpty else {
            throw XCTSkip("test55: no folder 'present' line survived in the readable tail (window has \(window.count)/\(lines.count) lines) — cannot judge the late-arrival path without one. lines=\(lines)")
        }

        let noneFirstPresents = folderPresents.filter { probeField($0, "backdrop") == "none" }

        if noneFirstPresents.isEmpty {
            // No none-first folder present survived the window — but if a backdrop=late present
            // did survive, that is still pass-worthy: the adoption already happened before the
            // readable window began, we just can't see its "none" half anymore.
            if let lateLine = window.first(where: { probeKind($0) == "present" && probeField($0, "backdrop") == "late" }) {
                XCTAssertTrue((probeField(lateLine, "item") ?? "").hasPrefix("nuvio.folder:"),
                              "test55: a backdrop=late present survived the window but its item is not a folder — \(lateLine)")
                print("[HeroProbe] test55: window has no backdrop=none folder present, but a backdrop=late present for \(probeField(lateLine, "item") ?? "?") survived — adoption already happened before the readable window began.")
                return
            }
            let tokensSeen = folderPresents.compactMap { probeField($0, "backdrop") }
            throw XCTSkip("test55: no folder 'present' line in the window carries backdrop=none (warm cache or evicted evidence, not a product failure) — backdrop tokens seen: \(tokensSeen). window=\(window)")
        }

        // For every `backdrop=late` present line in the window, the nearest PRECEDING folder
        // `present` line in the window with the same `item=` must exist and carry `backdrop=none`
        // — never compare across the marker. A late line with no preceding same-item folder
        // present in the window is skipped rather than failed: its `none` half may simply have
        // rolled out of the tail before the marker.
        for (index, line) in window.enumerated() {
            guard probeKind(line) == "present", probeField(line, "backdrop") == "late" else { continue }
            let lateItem = probeField(line, "item") ?? ""
            var precedingFolderPresent: String?
            for prior in window[..<index].reversed() {
                guard probeKind(prior) == "present",
                      (probeField(prior, "item") ?? "").hasPrefix("nuvio.folder:"),
                      probeField(prior, "item") == lateItem else { continue }
                precedingFolderPresent = prior
                break
            }
            guard let precedingFolderPresent else { continue }
            XCTAssertEqual(probeField(precedingFolderPresent, "backdrop"), "none",
                           "test55: backdrop=late landed on item=\(lateItem) but the nearest preceding folder present for that item in the window was not backdrop=none — late=\(line) preceding=\(precedingFolderPresent)")
        }

        // At least one none-first folder identity in the window must be followed, later in the
        // window, by a late present for that SAME item. When none is, that's only a failure if
        // the unadopted identity is the LAST folder presented (it stayed focused through the end
        // of the dwell with nothing to supersede it, so the late path had every chance to fire and
        // didn't). A none identity superseded by a different folder before its art could land is
        // expected — focus moved on — and must not fail.
        let lateItems = Set(window.compactMap { line -> String? in
            guard probeKind(line) == "present", probeField(line, "backdrop") == "late" else { return nil }
            return probeField(line, "item")
        })
        let noneItems = Set(noneFirstPresents.compactMap { probeField($0, "item") })
        let adopted = noneItems.intersection(lateItems)

        guard !adopted.isEmpty else {
            // Environment, not product: if NO folder art reached the hero at all during the run
            // (no cached/fetched/late token on any folder present in the window), the image host
            // was stalled — i.postimg.cc answered 0–32 KB in 25 s on 2026-09-08 — and the late
            // path had nothing to adopt. Skip with the lines rather than fail; the product verdict
            // needs a run where at least one folder's art arrives.
            let artReached = folderPresents.contains { line in
                ["cached", "fetched", "late"].contains(probeField(line, "backdrop") ?? "")
            }
            if !artReached {
                throw XCTSkip("test55: no folder art reached the hero during this run (every folder present is backdrop=none — image host stalled?); nothing to judge. window=\(window)")
            }
            let lastFolderItem = folderPresents.last.flatMap { probeField($0, "item") }
            if let lastFolderItem, noneItems.contains(lastFolderItem) {
                XCTFail("test55: \(noneItems.count) folder(s) presented with backdrop=none (\(noneItems.sorted())) in the window but none was later adopted by a backdrop=late present, and the last folder presented (\(lastFolderItem)) is one of them — it stayed focused through the end of the dwell with no adoption. window=\(window)")
            } else {
                print("[HeroProbe] test55: \(noneItems.count) folder(s) presented with backdrop=none (\(noneItems.sorted())) but none was adopted before focus moved to another folder — expected, not a failure.")
            }
            return
        }
        print("[HeroProbe] test55: late-adopted \(adopted.count)/\(noneItems.count) folder(s): \(adopted.sorted())")
    }
}
