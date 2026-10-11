import XCTest
@testable import NuvioTV

/// The words for a media-server failure: a stream group's error line comes across the bridge as
/// Kotlin's English copy and must map back to the app's own (localized) text.
final class ServerFailureTextTests: XCTestCase {
    func testEveryKnownFailureMapsItsEnglishCopyBack() {
        let english: [String: String] = [
            "AUTH_REQUIRED": "Sign in to this server again in Settings.",
            "UNREACHABLE": "The server is unavailable.",
            "NOT_FOUND": "This item is no longer available on the server.",
            "INCOMPLETE": "Still checking this server's library. Try again in a moment.",
            "FORBIDDEN": "This user does not have access.",
            "UNSUPPORTED": "The server doesn't support this item.",
            "FAILED": "Could not connect to the server.",
        ]
        for (name, text) in english {
            XCTAssertEqual(ServerFailureText.localized(fallbackMessage: text), ServerFailureText.message(failure: name), name)
        }
    }

    func testAnUnknownMessageIsKeptAsItIs() {
        XCTAssertEqual(ServerFailureText.localized(fallbackMessage: "Timed out after 15 s"), "Timed out after 15 s")
    }

    func testAnUnknownFailureReadsAsAConnectionProblem() {
        XCTAssertEqual(ServerFailureText.message(failure: "SOMETHING_NEW"), ServerFailureText.message(failure: "FAILED"))
    }
}
