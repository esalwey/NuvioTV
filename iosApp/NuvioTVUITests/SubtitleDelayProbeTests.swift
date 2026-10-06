import XCTest

/// Ad-hoc probe for the beta.15 §B1/B2 subtitle-delay Timing row (`PlayerSubtitlesTab`), mpv
/// engine. Attaches to an already-running app pre-warmed with the `debug.mpvSmokeURL` harness
/// (see `MPVSmokeTest.swift`) forced onto the mpv path — mpv reports `supportsSubtitleDelay = true`
/// unconditionally (`MPVPlayerPanelAdapter`), so no addon subtitle needs to be fetched first; the
/// Timing row is present as soon as the Subtitles tab is. Skipped unless `SUBTITLE_DELAY_PROBE=1`
/// is in the environment (pass it as `TEST_RUNNER_SUBTITLE_DELAY_PROBE=1` to xcodebuild).
///
/// Pre-launch setup (device/sim, `<dev>` = target udid, matches the recipe in `MPVSmokeTest.swift`
/// / `mpv-main-thread-contention-fix` notes):
///   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV player.nativeDolbyVision -bool NO
///   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.mpvSmokeURL -string '<url>'
///   xcrun simctl launch <dev> com.nuvio.media.NuvioTV
///
/// The tvOS 27 runtime never reports `hasFocus`, so navigation is driven by fixed, pre-verified
/// `XCUIRemote` press counts (never by asserting focus) and checkpoints assert on the visible
/// `%+.2f s` value label instead — existence/value-driven per `tvos-ui-sim-verification` notes.
final class SubtitleDelayProbeTests: XCTestCase {
    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Looks up an accessibility identifier regardless of the underlying AX element type — the
    /// delay chips are `Button`s (`.buttons`) but the value readout is a plain `Text` (typically
    /// `.staticTexts`, but SwiftUI's exact AX role isn't a contract worth pinning down here).
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Opens the top panel (Down) and switches to the Subtitles tab (Right), from a state where the
    /// transport/panel is fully dismissed — mirrors `PlayerTopPanelProbeTests`' steps 1–2.
    private func openSubtitlesTab(_ app: XCUIApplication) {
        let panel = app.otherElements["player.panel"]
        remote.press(.down)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "panel did not present on Down")
        pause(3)   // let the presentation + SwiftUI accessibility tree settle (matches PlayerTopPanelProbeTests)
        remote.press(.right)
        pause(2)
        XCTAssertEqual(app.buttons["player.panel.tab.subtitles"].value as? String, "selected",
                        "Subtitles tab not selected")
        // No "Off" row assertion here: mpv's adapter only emits an Off entry when
        // `state.subtitleTracks` is non-empty (MPVPlayerPanelAdapter.rebuildSelections) — the mpv
        // smoke fixture has no embedded/external subtitle tracks, so the tab legitimately shows
        // only "No subtitles for this title" + the Timing row. Assert the Timing row's presence
        // instead, which is what this probe actually cares about.
        XCTAssertTrue(element(app, "player.panel.subtitleDelay.value").waitForExistence(timeout: 3),
                       "no Timing row / subtitle delay value label")
    }

    /// From the Subtitles tab (focus still on the tab bar), two Down presses land focus somewhere
    /// in the Timing row — with no embedded/addon subtitles (mpv smoke context has none) there is no
    /// Off row at all (`MPVPlayerPanelAdapter.rebuildSelections` only emits one when
    /// `subtitleTracks` is non-empty), just the non-focusable "No subtitles" caption, which the
    /// focus engine skips regardless. A Left hunt (idempotent once at the wall) then guarantees
    /// focus sits on the leftmost chip, `subtitleDelay.minus1`, regardless of exactly where the two
    /// Downs landed — screenshot-verified (`02-timing-row-entered`) rather than asserted, since
    /// `hasFocus` never reads true on this runtime.
    private func focusTimingRowLeftEdge() {
        remote.press(.down)
        pause(1.5)
        remote.press(.down)
        pause(1.5)
        for _ in 0..<5 { remote.press(.left) }
        pause(1.5)
    }

    /// Right from the (hunted) leftmost chip `minus1` to `plus1`: minus1 → minus → (value, not
    /// focusable, skipped) → plus → plus1 — three presses.
    private func focusPlusOne() {
        for _ in 0..<3 { remote.press(.right) }
        pause(1)
    }

    func testSubtitleDelayTimingRow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_DELAY_PROBE"] == "1")
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30),
                      "mpv player view never appeared — MPVSmokeTest harness not armed?")
        pause(3)   // let the panel's swipe-down recognizer attach

        // 1. Open the panel, switch to Subtitles.
        openSubtitlesTab(app)
        shot("01-subtitles-tab")

        // 2. Enter the Timing row; value starts at +0.00 s (fresh videoId, no prior delay saved
        //    yet, or a prior run's persisted value — assert existence/format only here, not zero,
        //    since a previous probe run in the same session may have left a value; the reset step
        //    below normalizes it before the persistence assertions matter).
        focusTimingRowLeftEdge()
        let valueLabel = element(app, "player.panel.subtitleDelay.value")
        XCTAssertTrue(valueLabel.waitForExistence(timeout: 3), "no subtitle delay value label")
        shot("02-timing-row-entered")

        // Normalize to +0.00 s first: if a Reset chip is present (delay != 0 from a prior run),
        // hunt to it and press it before the scripted +1/+1/reset sequence below.
        if app.buttons["player.panel.subtitleDelay.reset"].exists {
            for _ in 0..<5 { remote.press(.right) }   // hunt to the right wall (reset is last)
            pause(1)
            remote.press(.select)
            pause(1)
            focusTimingRowLeftEdge()
        }
        XCTAssertTrue((valueLabel.label).contains("+0.00"), "expected +0.00 s at start, got \(valueLabel.label)")

        // 3. plus1 × 2 → +2.00 s.
        focusPlusOne()
        remote.press(.select)
        pause(1)
        remote.press(.select)
        pause(1)
        XCTAssertTrue(valueLabel.label.contains("+2.00"), "expected +2.00 s after plus1×2, got \(valueLabel.label)")
        shot("03-plus2")

        // 4. Reset → +0.00 s. Reset sits one more Right past plus1.
        remote.press(.right)
        pause(1)
        XCTAssertTrue(app.buttons["player.panel.subtitleDelay.reset"].waitForExistence(timeout: 3), "no Reset chip")
        remote.press(.select)
        pause(1)
        XCTAssertTrue(valueLabel.label.contains("+0.00"), "expected +0.00 s after Reset, got \(valueLabel.label)")
        shot("04-reset")

        // 5. plus1 × 1 → +1.00 s, then terminate + relaunch to prove persistence (§B2:
        //    PlayerTrackPreferenceStorage, restored in MPVPlayerView.onFileLoaded()).
        focusTimingRowLeftEdge()
        focusPlusOne()
        remote.press(.select)
        pause(1)
        XCTAssertTrue(valueLabel.label.contains("+1.00"), "expected +1.00 s before relaunch, got \(valueLabel.label)")
        shot("05-plus1-before-relaunch")

        app.terminate()
        pause(1)
        app.activate()
        XCTAssertTrue(app.otherElements["player.mpv"].waitForExistence(timeout: 30),
                      "mpv player view never reappeared after relaunch")
        pause(3)

        openSubtitlesTab(app)
        focusTimingRowLeftEdge()
        let valueLabelAfter = element(app, "player.panel.subtitleDelay.value")
        XCTAssertTrue(valueLabelAfter.waitForExistence(timeout: 5), "no subtitle delay value label after relaunch")
        shot("06-after-relaunch")
        XCTAssertTrue(valueLabelAfter.label.contains("+1.00"),
                      "expected persisted +1.00 s after relaunch, got \(valueLabelAfter.label)")
    }
}
