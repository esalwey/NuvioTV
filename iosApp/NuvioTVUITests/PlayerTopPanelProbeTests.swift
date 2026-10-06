import XCTest

/// Ad-hoc probe for the app-drawn swipe-down top panel on the native player. Attaches to the
/// already-running app (pre-warmed with `debug.mpvSmokeURL` + `player.nativeDolbyVision=YES` on a
/// two-audio-track MKV with an embedded subtitle, e.g. `long2a-sub.mkv`), then drives it with
/// `XCUIRemote`, pausing so the shell can `simctl io screenshot` each state and grep the app's
/// console log for `[NativePlayer]` selection lines. Skipped unless PLAYER_PANEL_PROBE=1 is in the
/// environment (pass it as TEST_RUNNER_PLAYER_PANEL_PROBE=1 to xcodebuild).
///
/// The tvOS 27 runtime never reports `hasFocus`, so assertions are existence/accessibility-value
/// driven; the selections are also proven by the app's own `print`s.
final class PlayerTopPanelProbeTests: XCTestCase {
    func testProbeTopPanel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAYER_PANEL_PROBE"] == "1")
        let app = XCUIApplication()
        app.activate()
        sleep(3)
        let remote = XCUIRemote.shared
        let panel = app.otherElements["player.panel"]

        // 1. Down while controls hidden → panel presents on the Info tab.
        remote.press(.down)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "panel did not present on Down")
        sleep(3)   // let the presentation + SwiftUI accessibility tree settle
        if ProcessInfo.processInfo.environment["PLAYER_PANEL_DUMP"] == "1" {
            print("[PanelProbe] tree:\n" + app.debugDescription)
        }
        XCTAssertEqual(app.buttons["player.panel.tab.info"].value as? String, "selected")
        sleep(3)   // screenshot: Info tab

        // 2. Right → Subtitles tab (selection follows focus).
        remote.press(.right)
        sleep(1)
        XCTAssertEqual(app.buttons["player.panel.tab.subtitles"].value as? String, "selected")
        XCTAssertTrue(app.buttons["player.panel.subtitle.off"].waitForExistence(timeout: 3), "no Off row")
        sleep(2)   // screenshot: Subtitles tab

        // 3. Down into the list, pick the second row (first embedded track), then Off again.
        let embedded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.panel.subtitle.' AND identifier != 'player.panel.subtitle.off'"))
        XCTAssertGreaterThan(embedded.count, 0, "no embedded/addon subtitle rows")
        remote.press(.down)     // focus → Off row
        remote.press(.down)     // focus → first track
        sleep(1)
        remote.press(.select)
        sleep(2)
        XCTAssertEqual(embedded.element(boundBy: 0).value as? String, "selected", "track row not selected after Select")
        XCTAssertEqual(app.buttons["player.panel.subtitle.off"].value as? String, "", "Off still selected")
        sleep(2)   // screenshot: subtitle selected
        remote.press(.up)
        sleep(1)
        remote.press(.select)   // Off
        sleep(2)
        XCTAssertEqual(app.buttons["player.panel.subtitle.off"].value as? String, "selected", "Off not re-selected")

        // 4. Up back to the tab row, Right → Audio tab; select the second audio track.
        remote.press(.up)
        sleep(1)
        remote.press(.right)
        sleep(1)
        XCTAssertEqual(app.buttons["player.panel.tab.audio"].value as? String, "selected")
        let audioRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.panel.audio.' AND identifier != 'player.panel.audio.route'"))
        XCTAssertGreaterThanOrEqual(audioRows.count, 2, "expected two audio tracks")
        sleep(2)   // screenshot: Audio tab
        remote.press(.down)     // first audio row
        remote.press(.down)     // second audio row
        sleep(1)
        remote.press(.select)
        sleep(3)
        XCTAssertEqual(audioRows.element(boundBy: 1).value as? String, "selected", "second audio row not selected")
        sleep(2)   // screenshot: audio selected

        // 4b. Engines with a fourth "Playback" tab (mpv): back up to the tab row (two rows deep),
        // Right → Playback, check its controls.
        remote.press(.up)
        remote.press(.up)
        sleep(1)
        remote.press(.right)
        sleep(1)
        if app.buttons["player.panel.tab.playback"].exists {
            XCTAssertEqual(app.buttons["player.panel.tab.playback"].value as? String, "selected")
            XCTAssertTrue(app.buttons["player.panel.speed.1.0"].waitForExistence(timeout: 3), "no speed buttons")
            XCTAssertTrue(app.buttons["player.panel.diagnostics"].exists, "no diagnostics toggle")
            sleep(3)   // screenshot: Playback tab
        }

        // 5. Menu closes the panel and does NOT pop the player.
        remote.press(.menu)
        sleep(2)
        XCTAssertFalse(panel.exists, "panel still present after Menu")
        XCTAssertTrue(app.otherElements["player.native"].exists || app.otherElements["player.mpv"].exists, "player was popped by Menu")
        sleep(2)   // screenshot: closed

        // 6. Down while the transport bar is visible also opens the panel.
        remote.press(.select)   // shows transport bar (toggles pause)
        sleep(1)
        remote.press(.down)
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "panel did not open with transport bar visible")
        remote.press(.menu)
        sleep(2)
        XCTAssertTrue(app.otherElements["player.native"].exists || app.otherElements["player.mpv"].exists, "player gone at end")
    }
}
