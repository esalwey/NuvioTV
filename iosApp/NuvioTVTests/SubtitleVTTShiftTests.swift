import XCTest
@testable import NuvioTV

/// Unit tests for `SubtitleVTT.shift` (beta.15 §B3 re-timing) — the native-engine path that shifts
/// every cue of an already-converted WebVTT document by a delay offset. Pure string-in/string-out
/// logic (no mpv/AVPlayer dependency), so these run as plain XCTest against the real app target via
/// `@testable import NuvioTV` rather than through the UI-test bundle.
final class SubtitleVTTShiftTests: XCTestCase {

    // MARK: - Identity

    func testOffsetZeroIsIdentity() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello world\n"
        XCTAssertEqual(SubtitleVTT.shift(vtt, offsetMs: 0), vtt)
    }

    // MARK: - Positive shift

    func testPositiveShiftMovesBothEdgesLater() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello world\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 2000)
        XCTAssertTrue(shifted.contains("00:00:03.000 --> 00:00:05.000"), shifted)
        XCTAssertTrue(shifted.contains("Hello world"))
    }

    // MARK: - Negative shift with clamp-at-0 start

    func testNegativeShiftClampsStartAtZero() {
        // start=0.500 end=2.000, offset -1000ms: end lands at 1.000 (kept), start would go
        // negative (-0.500) and must clamp to 0 rather than render a negative timestamp.
        let vtt = "WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nClamped\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: -1000)
        XCTAssertTrue(shifted.contains("00:00:00.000 --> 00:00:01.000"), shifted)
        XCTAssertTrue(shifted.contains("Clamped"))
    }

    // MARK: - Cue dropped when end <= 0

    func testCueDroppedWhenShiftedEndIsAtOrBeforeZero() {
        // start=0.100 end=0.500, offset -1000ms: shifted end = -500ms <= 0 → the whole cue falls
        // off the front of the timeline and must be dropped entirely (not clamped, not kept).
        let vtt = "WEBVTT\n\n00:00:00.100 --> 00:00:00.500\nGone\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: -1000)
        XCTAssertFalse(shifted.contains("Gone"), shifted)
        XCTAssertFalse(shifted.contains("-->"), shifted)
    }

    // MARK: - Cue settings preserved

    func testCueSettingsPreservedAfterSpace() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000 line:90% align:middle\nHi\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 500)
        XCTAssertTrue(shifted.contains("00:00:01.500 --> 00:00:03.500 line:90% align:middle"), shifted)
    }

    func testCueSettingsPreservedAfterTab() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\tline:90% align:middle\nHi\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 500)
        XCTAssertTrue(shifted.contains("00:00:01.500 --> 00:00:03.500 line:90% align:middle"), shifted)
    }

    // MARK: - Header / NOTE / STYLE blocks untouched

    func testTimestampMapNoteAndStyleBlocksPassThroughUntouched() {
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        NOTE
        This is a note block, never touched by re-timing.

        STYLE
        ::cue { color: yellow; }

        00:00:01.000 --> 00:00:03.000
        Hello world
        """
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 1000)
        XCTAssertTrue(shifted.contains("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000"), shifted)
        XCTAssertTrue(shifted.contains("NOTE\nThis is a note block, never touched by re-timing."), shifted)
        XCTAssertTrue(shifted.contains("STYLE\n::cue { color: yellow; }"), shifted)
        XCTAssertTrue(shifted.contains("00:00:02.000 --> 00:00:04.000"), shifted)
    }

    // MARK: - Comma decimal separator tolerated (SRT leftovers)

    func testCommaDecimalSeparatorTolerated() {
        let vtt = "WEBVTT\n\n00:00:01,000 --> 00:00:03,000\nComma cue\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 1000)
        // Re-rendered timestamps always use the canonical dot separator.
        XCTAssertTrue(shifted.contains("00:00:02.000 --> 00:00:04.000"), shifted)
        XCTAssertTrue(shifted.contains("Comma cue"))
    }

    func testMillisFromVTTTimestampToleratesComma() {
        XCTAssertEqual(SubtitleVTT.millis(fromVTTTimestamp: "00:00:01,500"), 1500)
        XCTAssertEqual(SubtitleVTT.millis(fromVTTTimestamp: "00:00:01.500"), 1500)
    }

    // MARK: - Rendition language labels (LANG-07)

    func testBareCodeNameUsesCallerLabelAndNormalizedTag() {
        let subs = [SubtitleFile(url: "https://subs.example/a.srt", language: "fre", name: "fre")]
        let labels = ["fre": SubtitleLanguageLabel(tag: "fr", name: "français")]
        let renditions = SubtitleVTT.renditions(from: subs, labels: labels)
        XCTAssertEqual(renditions.count, 1)
        XCTAssertEqual(renditions.first?.name, "Français")
        XCTAssertEqual(renditions.first?.language, "fr")
    }

    func testDescriptiveNameIsKept() {
        let subs = [SubtitleFile(url: "https://subs.example/b.srt", language: "fre", name: "French (OpenSubtitles)")]
        let labels = ["fre": SubtitleLanguageLabel(tag: "fr", name: "Français")]
        let renditions = SubtitleVTT.renditions(from: subs, labels: labels)
        XCTAssertEqual(renditions.first?.name, "French (OpenSubtitles)")
        XCTAssertEqual(renditions.first?.language, "fr")
    }

    func testRenditionsCapAtMaxAddonRenditions() {
        let subs = (0..<40).map { SubtitleFile(url: "https://subs.example/\($0).srt", language: "en", name: "English \($0)") }
        XCTAssertEqual(SubtitleVTT.renditions(from: subs).count, SubtitleVTT.maxAddonRenditions)
    }

    // MARK: - Segment resume lookup (PLY-A5)

    private func sampleMap() -> SegmentMap {
        SegmentMap(segments: [
            .init(number: 1, startTicks: 0, durationSec: 6),
            .init(number: 2, startTicks: 6, durationSec: 4.5),
            .init(number: 3, startTicks: 10, durationSec: 6),
        ], totalDurationSec: 16.5)
    }

    func testSegmentNumberContainingTime() {
        let map = sampleMap()
        XCTAssertEqual(map.segmentNumber(containing: 0), 1)
        XCTAssertEqual(map.segmentNumber(containing: 5.99), 1)
        XCTAssertEqual(map.segmentNumber(containing: 6), 2)
        XCTAssertEqual(map.segmentNumber(containing: 10.6), 3)
        XCTAssertEqual(map.segmentNumber(containing: 99), 3)
        XCTAssertEqual(map.startSec(ofSegment: 3), 10.5)
    }

    func testMediaPlaylistCarriesStartOffsetOnlyWhenSet() {
        let map = sampleMap()
        XCTAssertFalse(map.mediaPlaylist().contains("EXT-X-START"))
        let withStart = map.mediaPlaylist(startOffsetSec: 12.25)
        XCTAssertTrue(withStart.contains("#EXT-X-START:TIME-OFFSET=12.250,PRECISE=YES"), withStart)
        // EXT-X-START precedes the init map and the first segment.
        let startIdx = withStart.range(of: "EXT-X-START")!.lowerBound
        let mapIdx = withStart.range(of: "EXT-X-MAP")!.lowerBound
        XCTAssertLessThan(startIdx, mapIdx)
    }
}
