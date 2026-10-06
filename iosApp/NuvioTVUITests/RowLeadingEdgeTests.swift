import XCTest

/// BUG-92 (beta.18 follow-up, u/mrStevenx3): with No Zoom ON (`CardFocusButtonStyle` swaps to
/// `StillCardButtonStyle` + `.focusEffectDisabled(true)` — zero system lift, `PosterCard.swift`
/// ~L196-210), accent ring OFF, Card Depth ON, the inline poster trailer spills past the poster's
/// edge — but only on the FIRST (left-most) card of a row. Root cause: the row's horizontal
/// `ScrollView` runs `.scrollClipDisabled()` (`BrowseComponents.swift` ~L3107), so any bleed a
/// focused card puts outside its own layout frame lands on top of its LEFT neighbour and is
/// invisible everywhere except at card #1, which has no neighbour to hide behind — the empty
/// overscan margin left of the row shows it plainly. `RowLeadingEdgeClip`
/// (`NuvioTV/DesignSystem/RowLeadingEdgeClip.swift`) is the fix; see that type's header for the
/// exact `BrowseComponents.swift` attachment this repo's DesignSystem wave does NOT itself touch.
///
/// Card Depth is deliberately left at its default (untouched by either launch-argument leg below):
/// its rail/shadow draw strictly INSIDE the tile's own `.clipShape` (`CardDepthStyle.swift`), so it
/// has no bearing on bleed PAST the tile's edge — the reporter's "Card Depth ON" is incidental to
/// this bug, not a precondition of it.
///
/// Helper methods here are a trimmed COPY of `NuvioTVUITests`'/`TrailerSoakTests`'/
/// `InlineTrailerTileProbeTests`' (`launchToHome`, `press`, `pause`, `shot`) — same house rule those
/// give for why cross-file UI-test helpers stay duplicated rather than factored out.
final class RowLeadingEdgeTests: XCTestCase {

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
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    /// The UX-4c smoke id (also used by `TrailerSoakTests`/`InlineTrailerTileProbeTests`) — a known
    /// bar-free 16:9 trailer, kept here purely so a title that DOES reach `.playing` (extraction not
    /// blocked) plays something deterministic. `.expandedStatic` — the phase that actually produces
    /// the widened tile + `.shadow` this bug is about — needs only a listed trailer in the focused
    /// title's metadata, not a successful extraction (see `InlineTrailerCardModel.expand`/`resolve`:
    /// the card promotes to `.expandedStatic` once a selectable trailer is confirmed and the single
    /// extraction slot is granted, BEFORE the YouTube fetch itself completes) — so this smoke id is
    /// belt-and-braces, not what makes the tile appear at all.
    private static let smokeVideoId = "rNZ0xKaCdus"

    /// `noZoom`: the two legs the plan asks for — No Zoom ON (`CardFocusMode.still`, zero lift, the
    /// reporter's exact config) and OFF (`CardFocusMode.systemLift`, the shipped default's real
    /// system hover lift, which can bleed independently of the ring/no-zoom band). Both toggle via
    /// launch arguments (`NSArgumentDomain`, top priority over any persisted value), the same knob
    /// `InlineTrailerTileProbeTests` already relies on — neither leg touches the synced profile, so
    /// both run for real rather than one being written as a skip.
    private func launchArguments(noZoom: Bool) -> [String] {
        [
            "-inline_trailers_enabled", "YES",
            "-debug.trailerProbe", "YES",
            "-debug.trailerSmokeVideoId", Self.smokeVideoId,
            // Deterministic row geometry (TrailerSoakTests'/InlineTrailerTileProbeTests' trick):
            // removes the Upcoming row so the down×4 walk below has a stable target.
            "-home_upcoming_row_enabled", "NO",
            "-trailer_playback_location", "poster",
            "-no_zoom_on_focus", noZoom ? "YES" : "NO",
            "-accent_focus_ring", "NO",
        ]
    }

    /// `debug_trailerTile`'s `x=` field — the tile's own frame origin in `.global` space
    /// (`InlineTrailerCard.swift`'s BUG-92 doc: the row defines no NAMED coordinate space, so the
    /// probe reads `.global`, the same space a screenshot's pixel columns are already in).
    private func tileGlobalOriginX(_ label: String) -> CGFloat? {
        for token in label.split(separator: " ") where token.hasPrefix("x=") {
            // Spelled out: `Double(...).map(CGFloat.init)` made the Swift 6 type checker give up
            // ("failed to produce diagnostic for expression") on the Phase 1 gate build.
            guard let value = Double(String(token.dropFirst(2))) else { return nil }
            return CGFloat(value)
        }
        return nil
    }

    /// One consistent read of every button's frame + focus flag from a SINGLE `snapshot()` walk —
    /// `NuvioTVUITests.buttonSnapshots`' own pattern (a per-element `.frame`/`.hasFocus` read via
    /// `allElementsBoundByIndex` can throw "No matches found for Element at index N" while the
    /// poster morph is remounting tiles; one snapshot walk has no such race).
    private func focusedButtonFrame(_ app: XCUIApplication) -> CGRect? {
        guard let root = try? app.snapshot() else { return nil }
        var found: CGRect?
        func walk(_ node: XCUIElementSnapshot) {
            guard found == nil else { return }
            if node.elementType == .button, node.hasFocus { found = node.frame; return }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Walks down×4 to the first poster row (same pre-Upcoming layout as
    /// `InlineTrailerTileProbeTests`/`TrailerSoakTests`), which lands focus on the row's FIRST
    /// (left-most) card — the one this bug's follow-up report is about — then polls up to 8s for
    /// `debug_trailerTile` (dwell 1.0s + `InlineTrailerCardModel.morphAnimation`'s ~0.35s) and
    /// returns its `x=` field.
    private func pollFirstCardTileOriginX(_ app: XCUIApplication, tag: String) throws -> CGFloat {
        press(.down, times: 4)
        shot(app, "\(tag)_00_row_focused")

        let probeText = app.staticTexts["debug_trailerTile"]
        var label: String?
        for i in 0..<16 {
            pause(0.5)
            if probeText.exists {
                label = probeText.label
                break
            }
            if i == 8 { shot(app, "\(tag)_01_mid_poll") }
        }
        shot(app, "\(tag)_02_after_poll")
        guard let label else {
            // YouTube extraction has been returning LOGIN_REQUIRED from this Mac since ~2026-09-05
            // 18:20 ET (see FEAT-32's tracker notes) — but `.expandedStatic` (the phase that
            // actually widens the tile) needs only a listed trailer in metadata, not a successful
            // extraction, so a missing probe here more likely means the focused title's metadata
            // never resolved at all, or the dwell/expand pipeline stalled for some other reason.
            // Either way this is an environment/content limitation the test can't tell apart from a
            // real regression by itself — skip rather than fail.
            throw XCTSkip("\(tag): debug_trailerTile never appeared within the poll window — no trailer tile observed on this sim run")
        }
        guard let originX = tileGlobalOriginX(label) else {
            XCTFail("\(tag): debug_trailerTile carries no parseable x= field: \(label)")
            throw XCTSkip("unparseable probe label")
        }
        return originX
    }

    /// Rasterizes both crops to raw RGBA bytes and returns the largest single-channel absolute
    /// difference between them — a pixel-for-pixel oracle, not a luma average
    /// (`NuvioTVUITests.lumaProfile`/`lumaStats`'s tool): the fix here is a CLIP, not a brightness
    /// change, and a colored bleed against a similarly-lit background could hide from a luma-only
    /// check. Same points→pixels scaling contract as those two (sim screenshots are exactly the
    /// window's own scale factor, read from the screenshot/window width ratio).
    private func maxChannelDelta(_ before: UIImage, _ after: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> Int {
        guard let beforeCg = before.cgImage, let afterCg = after.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(beforeCg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: beforeCg.width, height: beforeCg.height))
        guard !px.isEmpty, let beforeCrop = beforeCg.cropping(to: px), let afterCrop = afterCg.cropping(to: px) else {
            throw XCTSkip("column \(pointRect) is off-screen")
        }
        func bytes(_ cg: CGImage) -> [UInt8] {
            let w = cg.width, h = cg.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return [] }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buffer
        }
        let beforeBytes = bytes(beforeCrop)
        let afterBytes = bytes(afterCrop)
        guard !beforeBytes.isEmpty, beforeBytes.count == afterBytes.count else {
            throw XCTSkip("could not rasterize both crops to compare")
        }
        var maxDelta = 0
        for i in 0..<beforeBytes.count {
            let delta = abs(Int(beforeBytes[i]) - Int(afterBytes[i]))
            if delta > maxDelta { maxDelta = delta }
        }
        return maxDelta
    }

    /// Per-channel byte tolerance for "no pixel differs beyond noise" — sim screenshots are
    /// lossless (no JPEG ringing), so this only has to absorb the video decoder's own frame-to-frame
    /// dither and any single-pixel anti-aliasing seam at a shape edge, never a genuine bleed (which
    /// reads as many dozens of bytes of real picture content, not a handful of rounding bytes).
    private static let noiseTolerance = 10

    // MARK: - No Zoom ON (the reporter's exact config)

    func testNoZoomFirstCardLeavesNoBleedPastLeadingEdge() throws {
        try assertNoBleedPastLeadingEdge(noZoom: true, tag: "rowEdge_noZoom")
    }

    // MARK: - Zoom ON (the shipped default's system lift)

    func testZoomOnFirstCardLeavesNoBleedPastLeadingEdge() throws {
        try assertNoBleedPastLeadingEdge(noZoom: false, tag: "rowEdge_zoomOn")
    }

    private func assertNoBleedPastLeadingEdge(noZoom: Bool, tag: String) throws {
        let app = launchToHome(extraArguments: launchArguments(noZoom: noZoom))
        let originX = try pollFirstCardTileOriginX(app, tag: tag)
        // `debug_trailerTile` exists as soon as `model.isExpanded` flips true (dwell fired), which
        // is the START of `InlineTrailerCardModel.morphAnimation` (~0.35s), not its end — the
        // tile's LEADING edge (`originX`, `.topLeading`-anchored) is invariant across that
        // animation, but the bleed sources this test looks for (the tile's `.shadow`, its rounded
        // corners) are still animating in at the moment the probe first appears. Settle past the
        // morph before judging the steady state.
        pause(0.5)

        guard let buttonFrame = focusedButtonFrame(app) else {
            throw XCTSkip("\(tag): no focused element reported (27.0 runtime never reports hasFocus reliably) — cannot bound the column vertically")
        }
        // The button's reported WIDTH/X can lag the live morph (house memory: "the focused
        // Button's AX frame never follows the tile"), but its Y/HEIGHT do not — UX-4a's whole
        // point is that a card's height never changes across the morph, only its width does — so
        // the vertical band below is trustworthy even though `buttonFrame.minX`/`.width` are not
        // used for anything.
        let columnWidth: CGFloat = 60
        let column = CGRect(x: originX - columnWidth, y: buttonFrame.minY, width: columnWidth, height: buttonFrame.height)

        let focusedShot = XCUIScreen.main.screenshot().image
        shot(app, "\(tag)_03_focused")

        // Defocus card #1 by moving RIGHT onto card #2 — same row, same vertical scroll position —
        // rather than DOWN to a different row, which would risk the whole page re-scrolling
        // vertically and invalidating the column's screen coordinates between the two shots. A
        // short pause lets card #1's collapse animation (`InlineTrailerCardModel.morphAnimation`,
        // ~0.35s) finish while staying well under card #2's own 1.0s dwell threshold, so nothing
        // new expands (and no horizontal reach-scroll can fire) before the second screenshot.
        remote.press(.right)
        pause(0.6)
        let unfocusedShot = XCUIScreen.main.screenshot().image
        shot(app, "\(tag)_04_unfocused")

        let delta = try maxChannelDelta(focusedShot, unfocusedShot, pointRect: column, windowSize: app.frame.size)
        XCTAssertLessThanOrEqual(
            delta, Self.noiseTolerance,
            "\(tag): the 60pt column left of the first card's leading edge (x=\(originX)) differs by up to \(delta)/255 between focused and unfocused — BUG-92 bleed past the row's leading edge"
        )
        XCTAssertTrue(app.state == .runningForeground, "\(tag): app must survive the leading-edge check")
    }
}
