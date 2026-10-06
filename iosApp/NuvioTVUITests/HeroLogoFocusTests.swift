import Foundation
import XCTest

/// FEAT-42 (2026-09-11): "add the movie logo to the feed selection" — the Home hero/focus panel's
/// title-logo resolution now reaches catalog items the shared TMDB overlay never touched (past
/// `HOME_ROW_ENRICHMENT_PREFIX`, or a TMDB-id catalog the overlay skips entirely), via
/// `HeroArtResolver.logoPlan` + `TitleLogoStore` (`HomeView.swift`). This is an EVIDENCE test, not
/// a hardware-proof one: whether the logo bitmap actually reaches the screen (as opposed to just
/// resolving inside the resolver) depends on the same FEAT-14/BUG-93 lift/ring rendering path every
/// other card treatment does, which the simulator cannot fully stand in for — see the device pass
/// this task's plan owes. What this test DOES pin, off the release-safe `debug_hero`/`hero_probe_blob`
/// probes, live on the fixture: at least one card in a row walk presents its logo FROM THE STORE
/// (`plgs=tmdb plg=1`), most of the row's cards resolve rather than sitting at `none`, the
/// presented item and the focused item agree, `plgs` and `plg` never disagree about whether a
/// bitmap is on screen, a warm revisit of the proof card still presents a logo, and the probe's
/// `present` lines carry the `logoSrc=` field with no `same=1` repaint signature and no
/// back-to-back commit of one item.
///
/// rc12 (Codex Finding B) rewrote the walk to fail with the collected `(fitem, plgs, plg)` table
/// instead of skipping on an all-`none` walk. The launch was still opportunistic, though: `logoPlan`
/// prefers a card's own logo (the Kotlin row overlay fills `item.logo` for a row's leading items)
/// and then the synchronous metahub guess for IMDb ids, so `plgs=tmdb` only ever showed up by
/// timing luck — a card whose own logo or metahub guess resolved first never reached the store at
/// all. Codex round 4 also flagged that the table-based warm read could BE the proof read itself
/// (when the proof only turned up on the back pass) and that the navigation fallback's backward-step
/// arithmetic was measured from the wrong edge.
///
/// This version removes the luck entirely: the app is launched with `debug.heroLogoStoreOnly`
/// (`#if DEBUG`-only, see `HeroArtResolver.heroLogoStoreOnly`'s doc comment in `HomeView.swift`),
/// which makes `present` pass `logoPlan` `addonLogo: nil` and `allowMetahub: false` — so a logo can
/// only ever come from `TitleLogoStore`, and every read's `plgs` can only ever be `tmdb` or `none`.
/// With the faster candidates out of the way, one row is enough: no second-row fallback, no
/// cross-row navigation. The proof is now a table-wide count (at least one card resolved through
/// the store, and resolved cards are not a minority), not a single lucky hit.
///
/// ⚠️ Pass `-debug.heroLogoStoreOnly YES` as a LAUNCH ARGUMENT only, the way this test does —
/// never persist it on the fixture simulator with `defaults write`. It withholds a card's own
/// logo and the metahub guess for every hero commit while it's set, folder heroes included, which
/// would silently break the evidence every OTHER hero UI test relies on for as long as it stuck
/// around outside this one launch.
///
/// This test has exactly two skip paths, both retained from before: (1) an explicit
/// `-debug.assumeTmdbOff` on the runner — TMDB is deliberately off, so `plgs=tmdb` is unreachable
/// by construction; (2) no non-folder row focused within 20 Down presses — this profile's Home has
/// nothing walkable to begin with, not a code question.
///
/// Helpers below are a trimmed copy of `NuvioTVUITests`'s (`pause`/`press`/`launchToHome`/
/// `moveFocus`/`openTab`/`heroProbeLines`/`probeField`/`probeKind`/`readHeroProbeAboutPane`) — see
/// `HeroFolderSwapTests`'s own type doc for why these are duplicated per hero test file rather than
/// shared (each copy is already `private` to its own file).
final class HeroLogoFocusTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers (trimmed copies)

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

    /// Reads the `hero_probe_lines`/`hero_probe_blob` ring buffer (`AboutSettingsPane.swift`).
    /// Prefers the hidden single-`Text` blob (whole buffer in one label) and falls back to the
    /// per-line container's `staticText` children.
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

    /// Reads a single `key=value` token out of a probe line. Tolerant of token order, first match
    /// wins.
    private func probeField(_ line: String, _ key: String) -> String? {
        let prefix = "\(key)="
        for token in line.split(separator: " ") where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    /// The probe line's TYPE token — second whitespace-separated token.
    private func probeKind(_ line: String) -> String? {
        let tokens = line.split(separator: " ")
        return tokens.count > 1 ? String(tokens[1]) : nil
    }

    /// Navigates Settings → About and reads the probe buffer.
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

    private func shot(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// A single settled read of `debug_hero` for one focused card: which item focus is on, what the
    /// hero committed for it, and which source the PRESENTED logo came from. Under
    /// `debug.heroLogoStoreOnly` (which this test always launches with) `plgs` can only ever be
    /// `tmdb` or `none` — `logoPlan`'s own-logo and metahub steps are disallowed, so there is
    /// nothing else left for it to name.
    private struct LogoRead: CustomStringConvertible {
        let pass: String
        let step: Int
        let fitem: String
        let pitem: String
        let plgs: String
        let plg: String
        /// True only when `pitem` (the PRESENTED item, `"type:id"`) names the same item as
        /// `fitem` (the FOCUSED item, bare id). During a cold hero commit the previous card's
        /// `plgs`/`plg` can still be what is on screen for a read taken just after focus already
        /// moved on — crediting that read to the newly focused card would misattribute a stale
        /// source's resolution to it. Non-evidence reads still go through every invariant check
        /// in `readLogo`; they are only excluded from the FEAT-42 per-card proof table
        /// (`byItem`/`tmdbHits`).
        let isEvidence: Bool

        /// The FEAT-42 store path — the one source `logoPlan` can still reach with the item's own
        /// logo withheld and the metahub guess disallowed.
        var provesTheStorePath: Bool { isEvidence && plgs == "tmdb" && plg == "1" }
        var description: String { "\(pass)\(step) \(fitem) plgs=\(plgs) plg=\(plg)" }
    }

    /// Every value `plgs` may legitimately carry under `debug.heroLogoStoreOnly`: the store hit
    /// (`tmdb`) or nothing (`none`, text wordmark). `addon`/`metahub` are NOT in this set on
    /// purpose — either one appearing on a read means the knob failed to apply, and `readLogo`
    /// fails loudly on that rather than letting an unrecognized value fall through silently.
    private static let validLogoSourceValues: Set<String> = ["tmdb", "none"]

    /// How far along a row to walk. `HOME_ROW_ENRICHMENT_PREFIX` is 12 (the shared TMDB overlay's
    /// reach) and `CatalogRowView.homePreviewLimit` is 18 (what the row renders, and what the
    /// FEAT-42 first-focus prewarm batches a lookup for), so a 16-card walk covers the whole gap
    /// this task closes while staying inside the prewarmed prefix. KEEP IN SYNC with both.
    private static let cardsPerRow = 16

    /// The escape hatch for OFFLINE runs. A fixture with TMDB genuinely switched off (no key,
    /// artwork off) can never produce `plgs=tmdb`, and on such a run this test has nothing to
    /// prove rather than something to report — but that has to be asserted from OUTSIDE, never
    /// inferred from the absence of the very evidence the test exists to find (the mistake the
    /// first version of this test made: it skipped on `plgs=none`, so a broken store/pending
    /// integration passed silently). This is the ONLY way a missing `plgs=tmdb` reads as anything
    /// but a failure — a fixture whose sampled rows carry no TMDB logo at all is a fixture
    /// assumption to fix by re-pointing the fixture (a documented assumption, the same way
    /// `FixtureSetupTests` documents its own Poster Size assumption), not something this test can
    /// safely infer at runtime. Set it on the RUNNER, not the app: `-debug.assumeTmdbOff` in the
    /// runner's own arguments, or `TEST_RUNNER_NUVIO_ASSUME_TMDB_OFF=1` in the xcodebuild
    /// environment (the `TEST_RUNNER_` prefix is stripped before it reaches the runner's
    /// environment). Defaults off.
    private var assumeTmdbOff: Bool {
        if ProcessInfo.processInfo.arguments.contains("-debug.assumeTmdbOff") { return true }
        let environment = ProcessInfo.processInfo.environment
        for key in ["NUVIO_ASSUME_TMDB_OFF", "TEST_RUNNER_NUVIO_ASSUME_TMDB_OFF"] {
            if let value = environment[key], ["1", "YES", "yes", "true"].contains(value) { return true }
        }
        return false
    }

    /// Review finding 4: the source/bitmap invariant (`plgs`/`plg` must agree on whether a
    /// bitmap is presented) used to be checked only in `test62`'s body, only over a filtered
    /// subset of reads (`fitem != "-"`), which meant a missing/unknown `plgs` value fell through
    /// with no assertion at all, and reads with no usable `fitem` — including the "leave" read at
    /// the end of the function — were never checked. Enforcing it HERE instead, on every read
    /// this file ever constructs (forward/back row walks via `walkRow`, the warm revisit, and the
    /// leave read all funnel through this one function), closes that gap: there is no read site
    /// left that can skip the check, and `fitem=-` reads are covered too even though they still
    /// stay out of the PROOF table (a read with no item id proves nothing about the store path).
    private func readLogo(_ probe: XCUIElement, pass: String, step: Int) -> LogoRead {
        let label = probe.label
        let plgs = probeField(label, "plgs") ?? "-"
        let plg = probeField(label, "plg") ?? "-"
        XCTAssertTrue(Self.validLogoSourceValues.contains(plgs),
                      "\(pass)\(step): plgs=\(plgs) is not one of \(Array(Self.validLogoSourceValues).sorted()) — probe label: \(label)")
        if plgs == "none" {
            XCTAssertEqual(plg, "0",
                           "\(pass)\(step): plgs=none but plg=\(plg) (expected 0 — no bitmap should be presented): \(label)")
        } else if Self.validLogoSourceValues.contains(plgs) {
            XCTAssertEqual(plg, "1",
                           "\(pass)\(step): plgs=\(plgs) but plg=\(plg) (expected 1 — a named source means a bitmap is presented): \(label)")
        }
        let fitem = probeField(label, "fitem") ?? "-"
        let pitem = probeField(label, "pitem") ?? "-"
        // `pitem` is `"type:id"`; `fitem` is the bare id (same convention `test62` already uses
        // at its own settled-commit check). A read is only evidence for `fitem`'s card when the
        // two agree.
        let pitemId = pitem.split(separator: ":").dropFirst().joined(separator: ":")
        let isEvidence = fitem != "-" && !pitemId.isEmpty && pitemId == fitem
        return LogoRead(pass: pass, step: step,
                        fitem: fitem,
                        pitem: pitem,
                        plgs: plgs,
                        plg: plg,
                        isEvidence: isEvidence)
    }

    /// Walks `direction` across one row, one card at a time, reading `debug_hero` after each hop has
    /// had time to settle (the 0.2 s focus dwell plus the resolver's 400 ms `laterSwapDeadline`).
    /// Stops early ONLY at the end of the row (two consecutive reads of the same item — a press
    /// into the row's edge is a no-op). Returns the reads it collected.
    ///
    /// Review finding 2: this used to also stop as soon as one card proved the store path — a hit
    /// on card two ended the walk right there, so the boundary this test exists to exercise (past
    /// the shared overlay's 12-item reach) and the back pass (where a repaired metahub miss shows
    /// up as `tmdb`) could both go completely untested by a passing run. The traversal is now
    /// unconditional: every card in the budget gets walked (or the row's real edge is hit) no
    /// matter how early proof shows up, and `test62` evaluates the proof condition over the whole
    /// collected table afterward instead of using it to cut the walk short.
    private func walkRow(_ probe: XCUIElement, direction: XCUIRemote.Button, pass: String,
                         steps: Int) -> [LogoRead] {
        var reads: [LogoRead] = []
        for step in 1...steps {
            press(direction, times: 1, gap: 0.85)
            let read = readLogo(probe, pass: pass, step: step)
            reads.append(read)
            if reads.count >= 2, reads[reads.count - 2].fitem == read.fitem {
                // Row edge: the press moved nothing, so every further press in this direction is
                // another no-op. (Two reads of one item is also the warm re-read, which is fine —
                // it just means there is nothing new to learn this way.)
                break
            }
        }
        return reads
    }

    // MARK: - test62

    /// Self-locating loop: walk Down (up to 20 times) looking for the first row-focused item that
    /// is NOT a collection folder — `fitem=` off `debug_hero`, non-empty and not prefixed
    /// `nuvio-folder://` (the same prefix `HeroFolderSwapTests.locateFolderHero` matches the
    /// other way). Returns the presses it took, or nil (having already logged the last probe
    /// label) if the budget exhausts.
    ///
    /// Single-row only: under `debug.heroLogoStoreOnly` one row's forward-and-back walk is enough
    /// evidence on its own, so unlike earlier versions there is no second-row fallback and no
    /// `avoiding` parameter to keep a cross-row search off the row it just left.
    private func locateNonFolderRow(_ probe: XCUIElement) -> Int? {
        var lastRead: LogoRead?
        for attempt in 1...20 {
            press(.down, times: 1, gap: 0.9)
            let read = readLogo(probe, pass: "locate", step: attempt)
            lastRead = read
            guard read.fitem != "-", !read.fitem.isEmpty else { continue }
            if !read.fitem.hasPrefix("nuvio-folder://") { return attempt }
        }
        print("[test62] no non-folder row focused after 20 Down presses. Last probe: \(lastRead?.description ?? "none")")
        return nil
    }

    /// FEAT-42: proves the `TitleLogoStore` path actually reaches the Home hero, on the fixture, off
    /// the release-safe probes — deterministically, under the `debug.heroLogoStoreOnly` launch
    /// knob rather than by timing luck.
    ///
    /// Before this knob, `logoPlan` almost always resolved a card's logo before the store got a
    /// say: the Kotlin row overlay fills `item.logo` for a row's leading items, and the synchronous
    /// metahub guess for IMDb ids answers before any lookup can land. Two earlier runs proved
    /// `tmdb` purely by which card happened to have neither a faster candidate — not a contract
    /// this test could rely on. With the item's own logo withheld and the metahub guess disallowed
    /// (`allowMetahub: false`), only the store is left: every read's `plgs` can only ever be `tmdb`
    /// or `none`, and `readLogo`'s `validLogoSourceValues` check fails loudly if either one is
    /// something else — that would mean the knob did not apply.
    ///
    /// The walk covers ONE non-folder row, forward across `cardsPerRow` cards and back — no
    /// second-row fallback and no cross-row navigation, since one row is enough evidence once the
    /// faster candidates are out of the way. The PROOF is table-wide, not a single lucky hit: at
    /// least one distinct card must show `plgs=tmdb plg=1` somewhere in its reads, AND cards that
    /// never resolve (`none` on every read) must not be the majority — a row of real titles where
    /// TMDB carries logos for most of them must actually resolve most of them; a broken store
    /// integration yields 100% `none` regardless of how many cards are sampled.
    ///
    /// This test has exactly two skip paths, named here so none is ever added silently: (1) an
    /// explicit `-debug.assumeTmdbOff` on the runner (see `assumeTmdbOff`) — TMDB is deliberately
    /// off, so `plgs=tmdb` is unreachable by construction, which also means zero cards resolve;
    /// (2) no non-folder row focused within 20 Down presses (`locateNonFolderRow`) — this profile's
    /// Home has nothing walkable to begin with, not a code question. Anything else is a failure,
    /// never a skip.
    ///
    /// This stays an EVIDENCE test, not a hardware-proof one: whether the resolved bitmap reaches
    /// the panel the way it should on a TV rides the same FEAT-14/BUG-93 rendering path the
    /// simulator cannot stand in for — see the device pass this task's plan owes.
    func test62HeroLogoOnRowFocus() throws {
        let app = launchToHome(extraArguments: ["-debug.homeHeroProbe", "YES", "-debug.heroLogoStoreOnly", "YES"])

        let probe = app.staticTexts["debug_hero"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20),
                      "debug_hero probe never appeared — Home rows are not up, nothing to walk")
        pause(2.0) // catalog fan-out settle, matching the other hero tests' post-Home pause

        guard locateNonFolderRow(probe) != nil else {
            throw XCTSkip("no non-folder row focused within 20 Down presses on this profile's Home")
        }

        // Out along the row, past the shared overlay's 12-item reach — the FEAT-42 gap.
        let forward = walkRow(probe, direction: .right, pass: "r1>", steps: Self.cardsPerRow)
        shot(app, "62a_deep_row_item_focused")

        // The hero must be showing the card focus actually settled on. `pitem` is `"type:id"`,
        // `fitem` the bare id.
        if let settled = forward.last {
            let pitemId = settled.pitem.split(separator: ":").dropFirst().joined(separator: ":")
            XCTAssertEqual(pitemId, settled.fitem,
                           "the hero must have committed to the item focus landed on: \(settled)")
        }

        // Back over the same cards: the revisit where a prewarm that missed the forward pass's
        // dwell window shows up as `tmdb`.
        let back = walkRow(probe, direction: .left, pass: "r1<", steps: forward.count)
        let reads = forward + back

        let table = reads.map(\.description).joined(separator: "\n")
        let tableAttachment = XCTAttachment(string: table)
        tableAttachment.name = "62_logo_reads"
        tableAttachment.lifetime = .keepAlways
        add(tableAttachment)
        print("[test62] \(reads.count) reads:\n\(table)")

        // Proving the store path is only meaningful if the walk actually reached past the shared
        // TMDB overlay's 12-item reach — the FEAT-42 gap this test exists to cover. A row that hit
        // its edge (or ran out of the `cardsPerRow` budget) before card 13 never exercised that
        // gap, so this fails loudly rather than letting an early, in-overlay-range hit stand in
        // for it.
        // Both checks matter: `reachedBoundary` only counts PRESSES, which can pass over fewer
        // than 13 distinct cards if focus oscillates (bounces back onto a card it already
        // visited); `distinctForwardCards` catches that case directly off the forward pass's own
        // set of focused items.
        let reachedBoundary = reads.contains { $0.pass.hasSuffix(">") && $0.step >= 13 }
        let distinctForwardCards = Set(forward.map(\.fitem)).subtracting(["-"]).count
        guard reachedBoundary, distinctForwardCards >= 13 else {
            XCTFail("""
            FEAT-42 boundary check: the forward pass never demonstrably reached card index 13 — \
            past the shared TMDB overlay's 12-item reach (reachedBoundary=\(reachedBoundary) \
            distinctForwardCards=\(distinctForwardCards)). The row is shorter than 13 cards (or \
            hit its edge early, or oscillated over fewer than 13 distinct cards), so the walk \
            never exercised the gap this test exists to cover. Reads:
            \(table)
            """)
            return
        }

        // Note: the source/bitmap invariant (`plgs`/`plg` must agree on whether a bitmap is
        // presented, and under this knob `plgs` must be `tmdb` or `none` — nothing else) is
        // enforced inside `readLogo` itself, on every read this file ever constructs, so there is
        // nothing left to re-check in this function's body.

        // Table-wide proof: group reads by distinct card (`fitem`), then classify each card as
        // RESOLVED (at least one `tmdb plg=1` read anywhere in its history) or unresolved (every
        // read for that card was `none`). At least one card must resolve, and unresolved cards
        // must not be the majority.
        let byItem = Dictionary(grouping: reads.filter { $0.fitem != "-" && $0.isEvidence }, by: { $0.fitem })
        let resolvedItems = byItem.filter { _, itemReads in itemReads.contains { $0.provesTheStorePath } }
        let unresolvedItems = byItem.filter { _, itemReads in itemReads.allSatisfy { $0.plgs == "none" } }

        guard !resolvedItems.isEmpty else {
            if assumeTmdbOff {
                throw XCTSkip("""
                -debug.assumeTmdbOff: this run declares TMDB switched off, so TitleLogoStore can \
                never resolve a URL and plgs=tmdb is unreachable by construction. \
                \(reads.count) reads across \(byItem.count) card(s), none from the store.
                """)
            }
            XCTFail("""
            FEAT-42: no card presented a logo from TitleLogoStore. \(reads.count) reads across \
            \(byItem.count) distinct card(s) and not one read plgs=tmdb, under a knob that makes \
            addon/metahub impossible — either the store/pending/prewarm path is not working, or \
            this fixture needs to be re-pointed at titles TMDB actually carries logos for (a \
            documented fixture assumption, like `FixtureSetupTests`' Poster Size). Pass \
            -debug.assumeTmdbOff on the runner only when TMDB really is off. Reads:
            \(table)
            """)
            return
        }
        guard unresolvedItems.count * 2 <= byItem.count else {
            XCTFail("""
            FEAT-42: \(unresolvedItems.count) of \(byItem.count) distinct card(s) never resolved a \
            logo (plgs=none on every read) — more than half. A row of real titles where TMDB \
            carries logos for most of them must resolve most of them; this ratio reads as a \
            broken store integration, not a fixture whose titles happen to lack logos. Reads:
            \(table)
            """)
            return
        }
        print("[test62] \(resolvedItems.count) of \(byItem.count) distinct card(s) resolved through the store")

        // Warm path: pick the FIRST chronological `tmdb` read whose card (`fitem`) has a LATER
        // read in the table — the back pass revisits every forward-pass card, so this is almost
        // always available without any navigation. Only the edge case where every `tmdb` hit is on
        // a card with no later read (every hit is from the back pass, which nothing further
        // revisits) falls back to deriving the proof card from wherever focus actually rests at
        // the end of the walk, then direction-probing a maneuver that leaves and returns to it —
        // see the `else` branch below for why a fixed Left-then-Right cannot be assumed here.
        let indexedReads = Array(reads.enumerated())
        let tmdbHits = indexedReads.filter { $0.element.provesTheStorePath && $0.element.fitem != "-" }
        let proofWithLater = tmdbHits.first { candidate in
            indexedReads[(candidate.offset + 1)...].contains { $0.element.fitem == candidate.element.fitem }
        }

        let proof: LogoRead
        let warm: LogoRead

        if let proofWithLater {
            proof = proofWithLater.element
            // Table path: take the LAST chronological read of the proof card — the revisit.
            warm = reads.filter { $0.fitem == proof.fitem }.last!
        } else {
            // Every `tmdb` hit's card has no later read — reached exactly when every hit is from
            // the back pass. `tmdbHits.first!` would pick the EARLIEST chronological hit, which
            // in this scenario is the row's DEEPEST card, while focus has since walked all the
            // way back to the row's START by the end of the back pass — Left there is a no-op
            // and Right just moves onto card two, so a fixed Left-then-Right maneuver could never
            // land back on that deep card. Derive the proof card from where focus ACTUALLY rests
            // instead of from table order.
            let stillFocused = readLogo(probe, pass: "warmcheck", step: 0)
            guard let resolvedProof = tmdbHits.last(where: { $0.element.fitem == stillFocused.fitem })?.element else {
                XCTFail("""
                warm path: expected the currently focused card \(stillFocused.fitem) to have a \
                recorded tmdb hit to revisit, found none among this table's hits. Reads:
                \(table)
                """)
                return
            }
            proof = resolvedProof
            // Probe which direction actually moves focus before committing to a maneuver, rather
            // than assuming Left is always a no-op at this point: press Left first; if that was a
            // no-op (still the same card — a true row-start edge), move Right then back Left to
            // leave and return; otherwise Left already moved focus away, so a single Right
            // returns to the proof card.
            press(.left, times: 1, gap: 0.7)
            if readLogo(probe, pass: "warmprobe", step: 0).fitem == proof.fitem {
                press(.right, times: 1, gap: 0.7)
                press(.left, times: 1, gap: 0.7)
            } else {
                press(.right, times: 1, gap: 0.7)
            }
            pause(1.0)
            let landed = readLogo(probe, pass: "warm", step: 0)
            guard landed.fitem == proof.fitem else {
                XCTFail("""
                warm path: the direction-probed maneuver landed on \(landed.fitem) instead of the \
                proof card \(proof.fitem). Refusing to assert a mismatched pair.
                """)
                return
            }
            warm = landed
        }

        XCTAssertEqual(warm.plgs, "tmdb", "a cache-warm revisit must still name the store as its source: \(warm)")
        XCTAssertEqual(warm.plg, "1", "a cache-warm revisit must still present the logo, never flick back to text: \(warm)")

        let attachment = XCTAttachment(string: "proof: \(proof.description)\nwarm: \(warm.description)")
        attachment.name = "62b_warm_path_reads"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Photo-contract invariants off the About pane's ring buffer.
        let lines = readHeroProbeAboutPane(app, shotPrefix: "62c")
        let presentLines = lines.filter { probeKind($0) == "present" }

        for line in presentLines {
            XCTAssertNotEqual(probeField(line, "same"), "1", "same=1 is the repaint signature the photo contract forbids: \(line)")
            XCTAssertNotNil(probeField(line, "logoSrc"), "every present line must carry the FEAT-42 logoSrc= field: \(line)")
        }

        // No item may present TWICE IN A ROW. The old bound (at most two `present` lines per item
        // in the buffer) only held for a one-visit walk and says nothing once this test walks a row
        // out and back; adjacency is the invariant that actually matters and is independent of how
        // far the walk goes — two commits for one item with no other item between them is the
        // double-paint BUG-42/BUG-90 exist to prevent. The one legitimate exception is
        // `backdrop=late`: `adoptLateBackdrop` deliberately re-commits the same item once when its
        // artwork lands after a deadline miss that painted nothing.
        for (index, line) in presentLines.enumerated() where index > 0 {
            guard let item = probeField(line, "item"),
                  let previous = probeField(presentLines[index - 1], "item"),
                  item == previous else { continue }
            XCTAssertEqual(probeField(line, "backdrop"), "late",
                           "\(item) presented twice with nothing between — only a late-backdrop adoption may do that: \(line)")
        }

        let restored = launchToHome(extraArguments: [])
        XCTAssertTrue(restored.state == .runningForeground)
    }
}
