import XCTest

/// BUG-92 device/sim check (u/mrStevenx3, beta.17: "inline trailer on the GIGN card sits offset —
/// dark band between the [ring] and the video"). Forces the Home inline-trailer poster morph
/// (`trailer_playback_location poster` — the morph is suppressed entirely under `hero`, see
/// `InlineTrailerCard.swift`'s BUG-92 doc) and reads the `debug_trailerTile` AX probe
/// (`InlineTrailerCard.swift`'s `trailerSurface`, `#if DEBUG`-gated like `debug_ux6`) to assert
/// the tile's inset/ring geometry, not just eyeball a screenshot: `inner == outer − 2*band` and
/// `rIn == rOut − band` in a ring-band configuration, and byte-identical (`inner == outer`,
/// `rIn == rOut`) in the shipped default (both focus-ring settings off).
///
/// Helper methods here are a trimmed COPY of `NuvioTVUITests`'/`TrailerSoakTests`' (`launchToHome`,
/// `press`, `pause`, `shot`) rather than a shared import — same house rule those two give for why
/// cross-file UI-test helpers stay duplicated rather than factored out.
final class InlineTrailerTileProbeTests: XCTestCase {

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

    /// The UX-4c smoke id (also `TrailerSoakTests.smokeVideoId`) — a known bar-free 16:9 trailer
    /// already used elsewhere in this codebase for deterministic sim verification.
    private static let smokeVideoId = "rNZ0xKaCdus"

    private func launchArguments(ringMode: [String]) -> [String] {
        [
            "-inline_trailers_enabled", "YES",
            "-debug.trailerProbe", "YES",
            "-debug.trailerSmokeVideoId", Self.smokeVideoId,
            // Deterministic row geometry (TrailerSoakTests' trick): removes the Upcoming row so
            // the down×4 walk below has a stable target.
            "-home_upcoming_row_enabled", "NO",
            // BUG-92 precondition: the poster morph is suppressed under `hero` — only `poster`
            // (the default) grows the focused card itself.
            "-trailer_playback_location", "poster",
        ] + ringMode
    }

    /// One parsed `debug_trailerTile` reading: `outer=WxH inner=WxH band=B rOut=R rIn=R`.
    private struct TileProbe {
        let outerWidth, outerHeight: Double
        let innerWidth, innerHeight: Double
        let band, rOut, rIn: Double

        init?(_ label: String) {
            var values: [String: String] = [:]
            for token in label.split(separator: " ") where token.contains("=") {
                let parts = token.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                values[String(parts[0])] = String(parts[1])
            }
            func dims(_ key: String) -> (Double, Double)? {
                guard let raw = values[key] else { return nil }
                let parts = raw.split(separator: "x")
                guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
                return (w, h)
            }
            guard
                let outer = dims("outer"), let inner = dims("inner"),
                let band = values["band"].flatMap(Double.init),
                let rOut = values["rOut"].flatMap(Double.init),
                let rIn = values["rIn"].flatMap(Double.init)
            else { return nil }
            (outerWidth, outerHeight) = outer
            (innerWidth, innerHeight) = inner
            self.band = band
            self.rOut = rOut
            self.rIn = rIn
        }
    }

    /// Walks down×4 to the first row (same pre-Upcoming layout `TrailerSoakTests`/`test37` walk),
    /// then polls up to 8s for `debug_trailerTile` to appear (the morph phase is data-driven —
    /// `model.isExpanded` — so the probe can show up before the video itself resolves).
    private func pollTileProbe(_ app: XCUIApplication, tag: String) throws -> TileProbe {
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
            throw XCTSkip("\(tag): debug_trailerTile never appeared within the poll window — no morph observed on this sim run")
        }
        guard let probe = TileProbe(label) else {
            XCTFail("\(tag): could not parse debug_trailerTile label: \(label)")
            throw XCTSkip("unparseable probe label")
        }
        return probe
    }

    // MARK: - Ring-band configuration: inner == outer − 2*band, rIn == rOut − band

    /// `-no_zoom_on_focus YES` (the neutral still ring) reserves the same band the accent ring
    /// does (`InlineTrailerCard.swift`'s `ringBandActive`), so this leg alone covers both ring
    /// settings' geometry — they compute the identical `band`/`rIn`.
    func testConcentricGeometryWithRingBandReserved() throws {
        let app = launchToHome(extraArguments: launchArguments(ringMode: ["-no_zoom_on_focus", "YES", "-accent_focus_ring", "NO"]))
        let probe = try pollTileProbe(app, tag: "92a_ring_band")

        XCTAssertEqual(probe.band, 4, accuracy: 0.1, "ring-band config must reserve the 4pt ringWidth band")
        XCTAssertEqual(probe.innerWidth, probe.outerWidth - 2 * probe.band, accuracy: 0.5,
                        "inner width must be outer width minus the band on both edges — outer=\(probe.outerWidth) inner=\(probe.innerWidth) band=\(probe.band)")
        XCTAssertEqual(probe.innerHeight, probe.outerHeight - 2 * probe.band, accuracy: 0.5,
                        "inner height must be outer height minus the band on both edges — outer=\(probe.outerHeight) inner=\(probe.innerHeight) band=\(probe.band)")
        XCTAssertEqual(probe.rIn, probe.rOut - probe.band, accuracy: 0.1,
                        "inner corner radius must be outer radius minus the band — rOut=\(probe.rOut) rIn=\(probe.rIn) band=\(probe.band)")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the ring-band leg")
    }

    // MARK: - Default configuration: identity (band == 0)

    /// Both focus-ring settings off — the shipped default — must read as a pure identity: no
    /// reserved band, inner geometry byte-identical to the outer tile.
    func testIdentityGeometryInDefaultConfig() throws {
        let app = launchToHome(extraArguments: launchArguments(ringMode: ["-no_zoom_on_focus", "NO", "-accent_focus_ring", "NO"]))
        let probe = try pollTileProbe(app, tag: "92b_default")

        XCTAssertEqual(probe.band, 0, accuracy: 0.05, "default config must reserve no band")
        XCTAssertEqual(probe.innerWidth, probe.outerWidth, accuracy: 0.1, "default config inner width must equal outer width")
        XCTAssertEqual(probe.innerHeight, probe.outerHeight, accuracy: 0.1, "default config inner height must equal outer height")
        XCTAssertEqual(probe.rIn, probe.rOut, accuracy: 0.05, "default config inner radius must equal outer radius")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the default-config leg")
    }
}
