import XCTest

/// SCRATCH harness for the BUG-59 reveal gate, guest edition — written 2026-08-19 while the shared
/// signed-in sim fixture (FA87E9B6…) was broken by the Wave 11 auth-restore stall (session restore
/// hangs, the 10 s watchdog dumps to Welcome). Guest sign-in never touches session RESTORE, so it
/// gets a working Home on a blank device and lets the reveal-gate soak logic run end to end.
///
/// Same philosophy as `TrailerSoakTests` (tolerant walk, screenshots + the `[TrailerZoom]` log
/// stream are the oracle, helpers duplicated by design — see that file's type doc). Harvest:
///
///     xcrun simctl spawn <udid> log show --last 15m \
///       --predicate 'eventMessage CONTAINS "[TrailerZoom]"'
///
/// Expected on a healthy reveal-gate build (cold store, fresh guest):
///   * per playing card: `reveal reason=interim|cap` and NEVER a barred video frame in the
///     screenshot burst — the tile holds static art until the video appears already-cropped;
///   * `reveal reason=cap` only with `frameTicks>=12` (~3 s of delivered frames).
///
/// SCRATCH-DEVICE ONLY, enforced (Codex, Wave 13 round 2): the UITests target is file-system-
/// synchronized, so this file would otherwise run in every ordinary suite pass — where it doesn't
/// just fail on a signed-in fixture, it would walk into "Add Profile" and CREATE a profile on the
/// signed-in account. Gated on `NUVIO_GUEST_REVEAL_SCRATCH=1`, same pattern as
/// `ScratchServerSwitchTests` (pass `TEST_RUNNER_NUVIO_GUEST_REVEAL_SCRATCH=1` to xcodebuild, on a
/// THROWAWAY simulator only).
///
/// Delete this file once the shared fixture is restored — `TrailerSoakTests.
/// testColdStoreFirstDwellRevealProfile` is the permanent version of this profile.
final class GuestTrailerRevealScratchTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["NUVIO_GUEST_REVEAL_SCRATCH"] == "1" else {
            throw XCTSkip("guest-account scratch test — set TEST_RUNNER_NUVIO_GUEST_REVEAL_SCRATCH=1 on a throwaway simulator")
        }
    }

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

    func testGuestColdStoreFirstDwellReveal() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-inline_trailers_enabled", "YES",
            "-debug.trailerProbe", "YES",
            "-debug.trailerSmokeVideoId", "rNZ0xKaCdus",
            "-debug.resetTrailerZoomStore", "YES",
        ]
        app.launch()

        // State-driven landing (run 1/2 findings): a blank device shows the Welcome gate; a device
        // whose guest session RESTORES (guest re-auth works across launches) lands straight on the
        // profile picker.
        let guestButton = app.buttons["Continue as Guest"]
        let addProfile = app.buttons["Add Profile"]
        var waited: TimeInterval = 0
        while !guestButton.exists, !addProfile.exists, waited < 60 {
            pause(2)
            waited += 2
        }
        if guestButton.exists {
            // Fixed-press pattern to "Continue as Guest": down out of the QR card, clamp left,
            // two rights (Sign In with Email · Create Account · Continue as Guest · Connect to
            // a Server).
            press(.down, times: 2, gap: 0.6)
            press(.left, times: 4, gap: 0.5)
            press(.right, times: 2, gap: 0.6)
            shot(app, "guest_reveal_00_welcome_focus")
            remote.press(.select)
            pause(10)
        }

        // Empty picker → create the profile. Editor layout (run 2's tree dump): Name TextField on
        // top, avatar strip below (initial focus: 'Use color avatar'), Save at the bottom. tvOS
        // text entry needs the field SELECTED first (fullscreen keyboard) before typeText works.
        let guestTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Guest'")).firstMatch
        if !guestTile.exists, addProfile.waitForExistence(timeout: 30) {
            remote.press(.select) // the picker's only tile — opens the editor
            pause(4)
            shot(app, "guest_reveal_00b_profile_editor")
            let nameField = app.textFields.firstMatch
            if nameField.waitForExistence(timeout: 10) {
                press(.up, times: 2, gap: 0.6) // avatar strip → name field
                remote.press(.select)          // fullscreen keyboard
                pause(2)
                shot(app, "guest_reveal_00c_keyboard")
                app.typeText("Guest\n")
                pause(2)
            }
            let save = app.buttons["Save"]
            if save.waitForExistence(timeout: 10) {
                for _ in 1...8 where !save.hasFocus {
                    remote.press(.down)
                    pause(0.5)
                }
                remote.press(.select)
            }
            pause(8)
            shot(app, "guest_reveal_00d_after_save")
        }
        // Select the profile tile (fresh from Save, or already there on a restored launch).
        if guestTile.waitForExistence(timeout: 20) {
            press(.left, times: 4, gap: 0.5)
            remote.press(.select)
        }
        pause(15) // Home catalog fan-out on a cold guest account
        shot(app, "guest_reveal_01_home")

        press(.down, times: 4)
        shot(app, "guest_reveal_02_row_focused")

        for card in 1...3 {
            press(.right, times: 1, gap: 1.4) // clears the 1.0 s dwell + morph settle
            for frame in 1...12 {
                pause(0.4)
                shot(app, String(format: "guest_reveal_card%d_t%02d", card, frame))
            }
            pause(2.0)
        }
        XCTAssertTrue(app.state == .runningForeground, "app must survive the guest reveal walk")
    }
}
