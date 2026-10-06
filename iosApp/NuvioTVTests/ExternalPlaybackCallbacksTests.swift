import XCTest
@testable import NuvioTV

/// `ExternalPlaybackCallbacks.reportsSameFile` (Infuse's x-success return trip, upstream 99ced26a4):
/// the `lastPlayedUrl` Infuse sends back names the handed-off file even when re-encoded on the way,
/// and a file the viewer went on to play in Infuse is told apart.
@MainActor
final class ExternalPlaybackCallbacksTests: XCTestCase {
    private let launched = "https://cdn.example.com/d/AbC%2Fx/Show.S01E02.mkv?token=a%2Bb"

    func testTheSameUrlMatches() {
        XCTAssertTrue(ExternalPlaybackCallbacks.reportsSameFile(launched, as: launched))
    }

    func testAReEncodedUrlMatches() {
        XCTAssertTrue(ExternalPlaybackCallbacks.reportsSameFile(
            "https://CDN.example.com/d/AbC%2fx/Show.S01E02.mkv?token=a+b", as: launched))
    }

    func testAnotherFileDoesNotMatch() {
        XCTAssertFalse(ExternalPlaybackCallbacks.reportsSameFile(
            "https://cdn.example.com/d/Other/Show.S01E03.mkv", as: launched))
        XCTAssertFalse(ExternalPlaybackCallbacks.reportsSameFile(
            "https://other.example.com/d/AbC%2Fx/Show.S01E02.mkv?token=a%2Bb", as: launched))
    }

    func testNoReportedUrlLeavesItToTheLaunchId() {
        XCTAssertTrue(ExternalPlaybackCallbacks.reportsSameFile(nil, as: launched))
        XCTAssertTrue(ExternalPlaybackCallbacks.reportsSameFile("", as: launched))
    }
}
