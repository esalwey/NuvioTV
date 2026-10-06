import XCTest
@testable import NuvioTV

/// Unit tests for `PlayerPlaybackError` (`Screens/Player/PlayerErrorScreen.swift`, PLY-1): the HTTP
/// status behind an mpv load failure, read from FFmpeg's `HTTP error NNN …` log line, and the detail
/// line the error card shows.
@MainActor
final class PlayerPlaybackErrorTests: XCTestCase {

    func testReadsTheStatusOfAnFFmpegHttpErrorLine() {
        XCTAssertEqual(PlayerPlaybackError.httpStatus(inLogLine: "https: HTTP error 403 Forbidden\n"), 403)
        XCTAssertEqual(PlayerPlaybackError.httpStatus(inLogLine: "HTTP error 404 Not Found"), 404)
        XCTAssertEqual(PlayerPlaybackError.httpStatus(inLogLine: "HTTP error 503 Service Unavailable"), 503)
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(PlayerPlaybackError.httpStatus(inLogLine: "Opening done: https://example.com/a.mkv"))
        XCTAssertNil(PlayerPlaybackError.httpStatus(inLogLine: "HTTP error "))
        XCTAssertNil(PlayerPlaybackError.httpStatus(inLogLine: "HTTP error 30 Moved"))
        // Not an error status.
        XCTAssertNil(PlayerPlaybackError.httpStatus(inLogLine: "HTTP error 302 Found"))
    }

    func testDetailPrefersTheHttpStatusOverMpvsText() {
        XCTAssertEqual(PlayerPlaybackError.detail(httpStatus: nil, mpvError: "loading failed"), "mpv: loading failed")
        XCTAssertNil(PlayerPlaybackError.detail(httpStatus: nil, mpvError: nil))
        XCTAssertNil(PlayerPlaybackError.detail(httpStatus: nil, mpvError: ""))
        let refused = PlayerPlaybackError.detail(httpStatus: 403, mpvError: "loading failed")
        XCTAssertNotNil(refused)
        XCTAssertNotEqual(refused, "mpv: loading failed")
        XCTAssertTrue(refused?.contains("403") ?? false)
    }
}
