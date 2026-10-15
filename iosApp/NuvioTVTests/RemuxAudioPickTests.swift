import XCTest
@testable import NuvioTV

/// The remux's automatic audio pick: the file's own main track, never a commentary, bit-exact when a
/// track of the same language can be stream-copied.
final class RemuxAudioPickTests: XCTestCase {

    private func track(_ index: Int, copy: Bool, transcode: Bool = false, isDefault: Bool = false,
                       commentary: Bool = false, language: String?) -> RemuxAudioCandidate {
        RemuxAudioCandidate(streamIndex: index, copyable: copy, transcodable: transcode || copy,
                            isDefault: isDefault, isCommentary: commentary, language: language)
    }

    func testTheDefaultTrackWinsOverTheFirstCopyableOne() {
        // [1] TrueHD eng (default), [2] AC-3 fra, [3] AC-3 commentary: the English track, not the first AC-3.
        let tracks = [
            track(1, copy: false, transcode: true, isDefault: true, language: "eng"),
            track(2, copy: true, language: "fra"),
            track(3, copy: true, commentary: true, language: "eng"),
        ]
        XCTAssertEqual(RemuxAudioCandidate.automaticPick(tracks), 1)
    }

    func testACopyOfTheSameLanguageBeatsATranscodeOfTheMainTrack() {
        let tracks = [
            track(1, copy: false, transcode: true, language: "eng"),
            track(2, copy: true, language: "fra"),
            track(3, copy: true, language: "eng"),
        ]
        XCTAssertEqual(RemuxAudioCandidate.automaticPick(tracks), 3)
    }

    func testACommentaryIsPickedOnlyWhenNothingElsePlays() {
        let onlyCommentary = [track(4, copy: true, commentary: true, language: "eng")]
        XCTAssertEqual(RemuxAudioCandidate.automaticPick(onlyCommentary), 4)
        let withMain = [track(4, copy: true, commentary: true, language: "eng"), track(5, copy: true, language: "eng")]
        XCTAssertEqual(RemuxAudioCandidate.automaticPick(withMain), 5)
    }

    func testUnplayableTracksAreSkippedAndNothingPlayableIsNil() {
        let tracks = [
            RemuxAudioCandidate(streamIndex: 1, copyable: false, transcodable: false, isDefault: true,
                                isCommentary: false, language: "eng"),
            track(2, copy: true, language: "eng"),
        ]
        XCTAssertEqual(RemuxAudioCandidate.automaticPick(tracks), 2)
        XCTAssertNil(RemuxAudioCandidate.automaticPick([tracks[0]]))
        XCTAssertNil(RemuxAudioCandidate.automaticPick([]))
    }

    func testTitlesThatNameACommentary() {
        XCTAssertTrue(RemuxAudioCandidate.looksLikeCommentary("Director's Commentary"))
        XCTAssertTrue(RemuxAudioCandidate.looksLikeCommentary("Commentaire audio"))
        XCTAssertFalse(RemuxAudioCandidate.looksLikeCommentary("Surround 5.1"))
        XCTAssertFalse(RemuxAudioCandidate.looksLikeCommentary(nil))
    }
}
