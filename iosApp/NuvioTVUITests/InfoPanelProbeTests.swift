import XCTest

/// Ad-hoc probe (info-panel work): attaches to the already-running app (pre-warmed with
/// `debug.mpvSmokeURL` so the native player is on screen), opens the swipe-down panel with a Down
/// press and steps through the tabs, pausing so the shell can `simctl io screenshot` each state.
/// Skipped unless INFO_PANEL_PROBE=1 is in the environment.
final class InfoPanelProbeTests: XCTestCase {
    func testProbeInfoPanel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INFO_PANEL_PROBE"] == "1")
        let app = XCUIApplication()
        app.activate()
        sleep(3)
        let remote = XCUIRemote.shared
        remote.press(.down)     // open the panel (Info tab)
        sleep(7)
        remote.press(.right)    // next tab
        sleep(7)
        remote.press(.right)    // next tab
        sleep(7)
        remote.press(.left)
        remote.press(.left)
        sleep(2)
        remote.press(.menu)     // close the panel
        sleep(2)
    }
}
