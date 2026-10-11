import XCTest
@testable import NuvioTV

/// The main-thread stall watchdog's call tracking: a libmpv call on the main thread is a violation
/// (the main thread never calls libmpv synchronously), one on another thread is not, and the slowest
/// call is remembered either way. The watchdog only runs in DEBUG builds (or with the Developer pane
/// unlocked), so each test skips itself otherwise.
@MainActor
final class MainThreadStallMonitorTests: XCTestCase {

    func testACallOnTheMainThreadIsCountedAsAViolation() throws {
        try XCTSkipUnless(MainThreadStallMonitor.isAllowed)
        let monitor = MainThreadStallMonitor.shared
        monitor.reset()
        monitor.beginSession()
        defer { monitor.endSession(); monitor.reset() }

        let value = monitor.run("get time-pos") { 42 }

        XCTAssertEqual(value, 42)
        let report = monitor.snapshot()
        XCTAssertEqual(report.mainThreadCalls, 1)
        XCTAssertEqual(report.firstMainThreadCall, "get time-pos")
    }

    func testACallOffTheMainThreadIsNotAViolation() throws {
        try XCTSkipUnless(MainThreadStallMonitor.isAllowed)
        let monitor = MainThreadStallMonitor.shared
        monitor.reset()
        monitor.beginSession()
        defer { monitor.endSession(); monitor.reset() }

        let done = expectation(description: "call finished")
        DispatchQueue.global().async {
            _ = monitor.run("get track-list") { Thread.sleep(forTimeInterval: 0.02) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let report = monitor.snapshot()
        XCTAssertEqual(report.mainThreadCalls, 0)
        XCTAssertEqual(report.slowestCallName, "get track-list")
        XCTAssertGreaterThanOrEqual(report.slowestCallMs, 10)
    }

    func testResetClearsTheReadout() throws {
        try XCTSkipUnless(MainThreadStallMonitor.isAllowed)
        let monitor = MainThreadStallMonitor.shared
        monitor.reset()
        monitor.beginSession()
        defer { monitor.endSession(); monitor.reset() }

        _ = monitor.run("set pause") { 0 }
        XCTAssertFalse(monitor.snapshot().isEmpty)

        monitor.reset()
        XCTAssertTrue(monitor.snapshot().isEmpty)
    }

    func testCallsAreNotTrackedWithoutASession() {
        let monitor = MainThreadStallMonitor.shared
        monitor.reset()
        _ = monitor.run("get duration") { 1 }
        XCTAssertTrue(monitor.snapshot().isEmpty)
    }
}
