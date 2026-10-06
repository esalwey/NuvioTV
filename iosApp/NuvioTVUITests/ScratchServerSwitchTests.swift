import XCTest

/// DESTRUCTIVE end-to-end checks for the self-hosted server switch + the guest-mode TMDB filter
/// editor. They sign the account out and wipe local data, so they are gated on the
/// `NUVIO_SCRATCH_DEVICE=1` environment variable (pass it as `TEST_RUNNER_NUVIO_SCRATCH_DEVICE=1`
/// to xcodebuild) and are meant for a throwaway simulator whose app container was cloned from the
/// signed-in device — NEVER the shared signed-in sim. Without the variable every test skips.
///
/// Three ordered parts (run them one at a time with `-only-testing:…/test90a…`, `…90b…`,
/// `…90c…`; each checkpoint is screenshotted):
///  a. (signed in OR signed out) → Settings › Account & Services › Connect to a Self-Hosted
///     Server, or Welcome › Connect to a Server → loopback stub → review → Connect → alert → the
///     switch lands on Welcome ("Connected to 127.0.0.1:…", no QR primary because the stub
///     advertises tv_login=false, email primary instead);
///  b. Continue as Guest (creating the first guest profile) with `-debug.collectionsSeedJsonB64`
///     → the seeded TMDB Discover folder → Edit Filters → exclude a genre chip → Save → the draft
///     round-trips on reopen;
///  c. Settings › Use Official Server → alert → Welcome shows the official layout again.
/// The scratch device recipe (create, install, rsync the signed-in container, import its
/// container plist) lives in the session scratchpad / memory notes; between a and b the
/// orchestrator clears the sim-wide prefs layer so imported keys can't masquerade as wipe gaps.
final class ScratchServerSwitchTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["NUVIO_SCRATCH_DEVICE"] == "1" else {
            throw XCTSkip("destructive scratch-device test — set TEST_RUNNER_NUVIO_SCRATCH_DEVICE=1 on a throwaway simulator")
        }
    }

    // MARK: - Helpers

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times { remote.press(button); pause(gap) }
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

    private func focusedButton(_ app: XCUIApplication) -> XCUIElement? {
        app.buttons.allElementsBoundByIndex.first { $0.hasFocus }
    }

    /// From anywhere on a root tab surface: climb to the tab bar, move to `title`, enter it.
    private func openTab(_ app: XCUIApplication, named title: String) {
        let tabNames = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        press(.up, times: 1, gap: 0.5)
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 6) { _ = moveFocus(.left, until: tab, max: 8) }
        remote.press(.select)
        pause(2)
        press(.down, times: 1)
    }

    /// Pass the profile gate: select whichever profile tile is focused (the clone's "Chris", or
    /// the guest's default profile), then wait for Home.
    private var createdGuestProfile = false

    private func passProfileGate(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        let home = app.buttons["Home"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if home.exists && home.frame.minY > 0 { return }
            // A profile picker shows tiles as buttons whose labels are profile names; the
            // Welcome screen shows "Continue as Guest". If we're on a picker, Select the focused tile.
            if app.buttons["Continue as Guest"].exists { return }
            // The Add Profile COVER (a name TextField is on screen — the picker has none): a
            // brand-new guest has no profile yet, so name it, save, and RELAUNCH — after the
            // cover dismisses, the picker stops taking arrow presses (fullScreenCover focus-wedge
            // class), while a fresh launch's picker default-focuses the first profile tile
            // (probe-verified). Never press Menu here: with the picker at the root a mistimed
            // Menu exits to the springboard.
            if app.staticTexts["Add Profile"].exists, app.textFields.firstMatch.exists {
                if !createdGuestProfile {
                    createdGuestProfile = true
                    let name = app.textFields.firstMatch
                    if !name.hasFocus { _ = moveFocus(.up, until: name, max: 4) }
                    remote.press(.select)
                    pause(2)
                    app.typeText("Guest")
                    pause(0.8)
                    remote.press(.menu) // dismiss the keyboard only (cover stays)
                    pause(1.5)
                    let save = app.buttons["Save"]
                    if save.waitForExistence(timeout: 3) {
                        if !save.hasFocus { _ = moveFocus(.down, until: save, max: 6) }
                        remote.press(.select)
                        pause(6)
                    }
                }
                // Whether just saved or accidentally reopened: relaunch to reset picker focus.
                app.terminate()
                pause(1)
                app.launch()
                pause(12)
                continue
            }
            // On the picker, prefer an existing profile tile — after the Add Profile cover saves,
            // focus lands back on the Add Profile tile, and blindly selecting the focused element
            // would mint guest profiles forever instead of entering one.
            let guestTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Guest'")).firstMatch
            if guestTile.exists {
                // On a fresh launch the picker default-focuses the first profile tile
                // (probe-verified) — one Left (no-op from the leftmost tile) and Select.
                pause(2)
                press(.left, times: 1, gap: 0.6)
                remote.press(.select)
                pause(8)
                continue
            }
            if let focused = focusedButton(app), !["Home", "Search", "Library", "Add-ons", "Settings", "Profile"].contains(focused.label) {
                remote.press(.select)
                pause(6)
            } else {
                pause(2)
            }
        }
    }

    /// Types into the tvOS full-screen keyboard (hardware-keyboard synthesis first, validated by
    /// the field's value), then Menu to commit. Returns whether the field now contains `text`.
    private func type(_ app: XCUIApplication, into field: XCUIElement, _ text: String) -> Bool {
        if !field.hasFocus { _ = moveFocus(.up, until: field, max: 8) }
        remote.press(.select)
        pause(2)
        app.typeText(text)
        pause(0.8)
        remote.press(.menu)
        pause(1.5)
        let value = (field.value as? String) ?? ""
        return value.contains(text)
    }

    /// Walks Down from the pane's current row until a button whose label starts with `prefix`
    /// reports focus OR (toggle/action rows never report focus) until it is the nearest row to
    /// the focused element's Y. Falls back to a fixed Down count computed from tree order.
    private func walkToRow(_ app: XCUIApplication, labelPrefix: String, sidebarMaxX: CGFloat) -> XCUIElement? {
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
        guard target.waitForExistence(timeout: 6) else { return nil }
        let tabNames: Set<String> = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        let pane = app.buttons.allElementsBoundByIndex
            .filter { $0.frame.minX > sidebarMaxX + 20 && $0.frame.width > 0 && !tabNames.contains($0.label) && $0.frame.minY > 90 }
            .sorted { $0.frame.minY < $1.frame.minY }
        var rowsY: [CGFloat] = []
        for b in pane where !(rowsY.last.map { abs($0 - b.frame.minY) < 6 } ?? false) { rowsY.append(b.frame.minY) }
        let targetRow = rowsY.firstIndex(where: { abs($0 - target.frame.minY) < 6 }) ?? 0
        let fromRow = focusedButton(app).flatMap { f in rowsY.firstIndex(where: { abs($0 - f.frame.minY) < 6 }) } ?? 0
        let delta = targetRow - fromRow
        if delta > 0 { press(.down, times: delta, gap: 0.6) }
        if delta < 0 { press(.up, times: -delta, gap: 0.6) }
        pause(0.8)
        return target
    }

    private func openAccountPane(_ app: XCUIApplication) -> CGFloat {
        openTab(app, named: "Settings")
        let account = app.buttons["Account & Services"]
        if !(account.exists && account.hasFocus) { _ = moveFocus(.up, until: account, max: 8) }
        remote.press(.select)
        pause(1.2)
        press(.right, times: 1)
        pause(1)
        return account.frame.maxX
    }

    /// True when the app's active server is already a 127.0.0.1 stub — visible on the signed-out
    /// Welcome ("Server: 127.0.0.1:…" secondary button) or, in-app, via the Settings Server rows.
    private func isOnCustomServer(_ app: XCUIApplication) -> Bool {
        if app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Server: 127.0.0.1'")).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Connected to 127.0.0.1")).firstMatch.exists {
            return true
        }
        if app.buttons["Continue as Guest"].exists { return false } // Welcome without the custom label
        // In-app: the Account & Services pane offers "Use Official Server" only on a custom server.
        _ = openAccountPane(app)
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use Official Server'")).firstMatch.waitForExistence(timeout: 4)
    }

    /// Drives the FULL switch to `stub` through the UI, from either entry point (signed-in
    /// Settings row, or the signed-out Welcome button). Throws XCTest failures on any snag.
    /// (NEVER use a real Sign Out on a clone: it revokes the shared server-side session, which
    /// signs the source sim out too — learned the hard way.)
    private func switchToStub(_ app: XCUIApplication, stub: DiscoveryStubServer) -> Bool {
        let welcomeConnect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to a Server'")).firstMatch
        if app.buttons["Continue as Guest"].exists {
            if !moveFocus(.down, until: welcomeConnect, max: 6) { _ = moveFocus(.right, until: welcomeConnect, max: 6) }
            guard welcomeConnect.hasFocus else { XCTFail("could not focus Welcome's Connect to a Server"); return false }
            remote.press(.select)
        } else {
            let sidebarX = openAccountPane(app)
            // "Connect to a Self-Hosted Server" on the official server, "Connect to Another
            // Server" when a custom one is already active — match the shared prefix.
            guard walkToRow(app, labelPrefix: "Connect to a", sidebarMaxX: sidebarX) != nil else {
                XCTFail("Connect to a … Server row missing"); return false
            }
            remote.press(.select)
        }
        pause(1.5)
        let urlField = app.textFields["server.url"]
        guard urlField.waitForExistence(timeout: 6) else { XCTFail("cover did not open"); return false }
        guard type(app, into: urlField, stub.origin) else {
            shot(app, "90x_url"); XCTFail("could not enter the stub URL (value=\(String(describing: urlField.value)))"); return false
        }
        // Pin focus on Check Server (leftmost of the button row; glass buttons don't report focus).
        press(.down, times: 1); press(.left, times: 2, gap: 0.5)
        remote.press(.select)
        guard app.staticTexts["server.review"].waitForExistence(timeout: 20) else {
            shot(app, "90x_review"); XCTFail("review never appeared; stub log \(stub.requestLog)"); return false
        }
        shot(app, "90b_review")
        // Connect to This Server is the leftmost control of the review's button row.
        press(.down, times: 8, gap: 0.4); press(.left, times: 2, gap: 0.5)
        remote.press(.select)
        pause(1.5)
        shot(app, "90c_connect_alert")
        let alertConnect = app.buttons["Connect"].firstMatch
        guard alertConnect.waitForExistence(timeout: 5) else { XCTFail("confirm alert missing"); return false }
        // Cancel holds default focus in the alert; Connect is to its right.
        if !alertConnect.hasFocus { _ = moveFocus(.right, until: alertConnect, max: 3) || moveFocus(.left, until: alertConnect, max: 3) }
        remote.press(.select)
        // The switch: sign-out + wipe + client reset → root gate → Welcome (custom server).
        let connected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Connected to 127.0.0.1")).firstMatch
        guard connected.waitForExistence(timeout: 45) else { XCTFail("Welcome never reported the custom server after the switch"); return false }
        pause(2)
        return true
    }

    /// Each part establishes its own server state (Codex round 1: XCTest guarantees no method
    /// order): already on a 127.0.0.1 server → done; otherwise run the full switch.
    private func ensureOnCustomServer(_ app: XCUIApplication, stub: DiscoveryStubServer) -> Bool {
        if isOnCustomServer(app) { return true }
        return switchToStub(app, stub: stub)
    }

    // MARK: - The scratch flow

    /// Part A — the clone (signed in or out) → Connect to a Self-Hosted Server → stub → review →
    /// Connect → alert → Welcome on the custom server (email primary, no QR).
    func test90aSwitchToCustomServer() throws {
        let stub = DiscoveryStubServer(document: .init(emailPasswordAuth: true, tvLogin: false))
        try stub.start()
        defer { stub.stop() }

        let app = XCUIApplication()
        app.launch()
        passProfileGate(app)
        shot(app, "90a_start")
        if isOnCustomServer(app) { throw XCTSkip("already on a custom server — reset the scratch clone to exercise the switch") }
        guard switchToStub(app, stub: stub) else { return }
        shot(app, "90d_welcome_custom")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In with Your Phone")).firstMatch.exists, "QR primary must be hidden when the server lacks tv_login")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign In with Email'")).firstMatch.exists, "email sign-in must be the primary action without tv_login")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Server: 127.0.0.1'")).firstMatch.exists, "the secondary row must show the active custom server")
    }

    /// Part B — on the custom server (establishing it if needed), signed out: Continue as Guest,
    /// then (seeded via the DEBUG knob) open the TMDB Discover folder → Edit Filters → exclude a
    /// genre → Save → reopen.
    func test90bGuestTmdbFilterEditor() throws {
        let stub = DiscoveryStubServer(document: .init(emailPasswordAuth: true, tvLogin: false))
        try stub.start()
        defer { stub.stop() }
        let seed = """
        [{"id":"seed-collection","title":"Seed Collection","folders":[{"id":"seed-folder","title":"Seed Sci-Fi","sources":[{"provider":"tmdb","tmdbSourceType":"DISCOVER","mediaType":"movie","title":"Discover Movies","sortBy":"popularity.desc"}]}]}]
        """
        let app = XCUIApplication()
        app.launchArguments = ["-debug.collectionsSeedJsonB64", Data(seed.utf8).base64EncodedString()]
        app.launch()
        passProfileGate(app, timeout: 60) // returns early on Welcome, passes the gate if already a guest
        guard ensureOnCustomServer(app, stub: stub) else { return }
        // The in-app custom-server check parks focus in Settings — reset to top-of-Home so the
        // collection-row walk below starts from a known place.
        if app.buttons["Home"].exists, !app.buttons["Continue as Guest"].exists {
            openTab(app, named: "Home")
            pause(2)
        }
        let guest = app.buttons["Continue as Guest"]
        if guest.exists {
            // ---- 2. Guest mode + seeded TMDB folder → filter editor ----
            if !moveFocus(.down, until: guest, max: 6) { _ = moveFocus(.right, until: guest, max: 6) || moveFocus(.left, until: guest, max: 6) }
            guard guest.hasFocus else { XCTFail("could not focus Continue as Guest"); return }
            remote.press(.select)
            // First-guest creation goes through the Add Profile cover and may need a relaunch to
            // clear the cover's focus wedge — give the gate a real budget.
            passProfileGate(app, timeout: 240)
        }
        guard app.buttons["Home"].waitForExistence(timeout: 30) else { shot(app, "90x_no_home"); XCTFail("never reached Home as a guest"); return }
        pause(4)
        shot(app, "90f_guest_home_seeded")
        // Home → the seeded collection row → its folder tile.
        let folderTile = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Seed Sci-Fi")).firstMatch
        // Walk Down row by row until the tile itself reports focus (rows above it — hero, any
        // Continue Watching cards, catalog rows — must be crossed, and a lazily-mounted tile
        // only materialises as focus nears its row).
        var reached = false
        for _ in 0..<18 {
            if folderTile.exists && folderTile.hasFocus { reached = true; break }
            if folderTile.exists, let focused = focusedButton(app), abs(focused.frame.minY - folderTile.frame.minY) < 6 {
                // Same row: slide horizontally onto the tile.
                if moveFocus(.left, until: folderTile, max: 6) || moveFocus(.right, until: folderTile, max: 6) { reached = true; break }
            }
            remote.press(.down); pause(0.9)
        }
        guard reached else { shot(app, "90x_no_folder"); XCTFail("seeded folder tile never took focus on Home"); return }
        shot(app, "90f2_folder_tile_focused")
        remote.press(.select)
        let editFilters = app.buttons["folder.editFilters"]
        guard editFilters.waitForExistence(timeout: 10) else { shot(app, "90x_no_edit"); XCTFail("Edit Filters missing on the TMDB folder"); return }
        shot(app, "90g_folder_detail")
        if !moveFocus(.up, until: editFilters, max: 6) { _ = moveFocus(.right, until: editFilters, max: 6) }
        remote.press(.select)
        let withoutGenres = app.textFields["filters.withoutGenres"]
        guard withoutGenres.waitForExistence(timeout: 10) else { shot(app, "90x_no_editor"); XCTFail("filter editor did not open"); return }
        shot(app, "90h_editor")
        // Exclude "Animation": the chips are labelled by genre; the second "Animation" chip (in
        // tree order) is the Exclude row's.
        let animationChips = app.buttons.matching(NSPredicate(format: "label == %@", "Animation"))
        XCTAssertGreaterThanOrEqual(animationChips.count, 2, "Include and Exclude genre chip rows expected (got \(animationChips.count))")
        let excludeAnimation = animationChips.element(boundBy: min(1, max(0, animationChips.count - 1)))
        // The editor opens with the Sort row focused; Include chips are one Down, Exclude chips
        // two. Land on the Exclude row's first chip, then slide Right onto "Animation" (chips
        // report focus on the 26.5 runtime).
        press(.down, times: 2, gap: 0.8)
        if !moveFocus(.right, until: excludeAnimation, max: 8) { _ = moveFocus(.left, until: excludeAnimation, max: 8) }
        XCTAssertTrue(excludeAnimation.hasFocus, "Exclude Animation chip must be focusable")
        remote.press(.select)
        pause(1)
        XCTAssertEqual((withoutGenres.value as? String) ?? "", "16", "toggling the Exclude Animation chip must write 16 into Excluded genre IDs")
        shot(app, "90i_excluded_animation")
        let save = app.buttons["filters.save"]
        if !moveFocus(.down, until: save, max: 40) {
            // Prominent buttons may not report focus: the footer row is the last focusable row and
            // Save Filters is its leftmost control, so overshoot Down and pin Left.
            press(.down, times: 6, gap: 0.3)
            press(.left, times: 3, gap: 0.4)
        }
        shot(app, "90i2_before_save")
        remote.press(.select)
        XCTAssertTrue(editFilters.waitForExistence(timeout: 10), "saving must return to the folder grid")
        pause(1)
        // Round-trip: reopen and the draft must still hold 16.
        if !moveFocus(.up, until: editFilters, max: 6) { _ = moveFocus(.right, until: editFilters, max: 6) }
        remote.press(.select)
        XCTAssertTrue(withoutGenres.waitForExistence(timeout: 10))
        XCTAssertEqual((withoutGenres.value as? String) ?? "", "16", "excluded genre must persist across reopen")
        shot(app, "90j_editor_reopened")
        remote.press(.menu)
        pause(1.5)
        remote.press(.menu) // back to Home
        pause(1.5)

    }

    /// Part C — on the custom server (establishing it if needed): Settings → Use Official Server
    /// → alert → Welcome in the official layout (QR primary back).
    func test90cUseOfficialServer() throws {
        let stub = DiscoveryStubServer(document: .init(emailPasswordAuth: true, tvLogin: false))
        try stub.start()
        defer { stub.stop() }
        let app = XCUIApplication()
        app.launch()
        passProfileGate(app, timeout: 90)
        guard ensureOnCustomServer(app, stub: stub) else { return }
        // A fresh switch lands on Welcome signed out — become a guest so Settings is reachable.
        if app.buttons["Continue as Guest"].exists {
            let guest = app.buttons["Continue as Guest"]
            if !moveFocus(.down, until: guest, max: 6) { _ = moveFocus(.right, until: guest, max: 6) || moveFocus(.left, until: guest, max: 6) }
            guard guest.hasFocus else { XCTFail("could not focus Continue as Guest"); return }
            remote.press(.select)
            passProfileGate(app, timeout: 240)
        }
        // ---- 3. Back to the official server ----
        let sidebarX = openAccountPane(app)
        guard walkToRow(app, labelPrefix: "Use Official Server", sidebarMaxX: sidebarX) != nil else {
            XCTFail("Use Official Server row missing while on a custom server"); return
        }
        remote.press(.select)
        pause(1.5)
        shot(app, "90k_use_official_alert")
        let switchButton = app.buttons["Switch"].firstMatch
        guard switchButton.waitForExistence(timeout: 5) else { XCTFail("Use official alert missing"); return }
        if !switchButton.hasFocus { _ = moveFocus(.right, until: switchButton, max: 3) || moveFocus(.left, until: switchButton, max: 3) }
        remote.press(.select)
        let qrPrimary = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In with Your Phone")).firstMatch
        XCTAssertTrue(qrPrimary.waitForExistence(timeout: 45), "after switching back the official Welcome layout (QR primary) must return")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Connected to 127.0.0.1")).firstMatch.exists)
        shot(app, "90l_welcome_official")
        XCTAssertTrue(app.state == .runningForeground)
    }
}
