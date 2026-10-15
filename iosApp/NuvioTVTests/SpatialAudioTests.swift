import XCTest
@testable import NuvioTV

/// Spatial audio (TrueHD Atmos / DTS:X as Dolby Atmos through APAC) and the lossless / HDR10+ pieces
/// that came with it: the pure parts, which need no SpatialAudioBridge session, device or media.
/// The segment grid and the playlists are what AVPlayer sees, so an off-by-one here is a stall or an
/// audio offset on a device.
final class SpatialAudioTests: XCTestCase {

    // MARK: - Segment grid

    func testSegmentsAreTwoApacSyncPeriods() {
        // 2 sync periods x 75 packets x 1024 frames.
        XCTAssertEqual(SpatialGrid.segmentFrames, 153_600)
        XCTAssertEqual(SpatialGrid.segmentSeconds, 3.2, accuracy: 1e-9)
    }

    func testSegmentCountAndIndex() {
        let total = SpatialGrid.totalFrames(durationSec: 10)
        XCTAssertEqual(total, 480_000)
        XCTAssertEqual(SpatialGrid.segmentCount(totalFrames: total), 4)
        XCTAssertEqual(SpatialGrid.index(atSeconds: 0, totalFrames: total), 0)
        XCTAssertEqual(SpatialGrid.index(atSeconds: 3.19, totalFrames: total), 0)
        XCTAssertEqual(SpatialGrid.index(atSeconds: 3.2, totalFrames: total), 1)
        XCTAssertEqual(SpatialGrid.index(atSeconds: 9.99, totalFrames: total), 3)
        // Past the end and before the start clamp into the stream.
        XCTAssertEqual(SpatialGrid.index(atSeconds: 1e6, totalFrames: total), 3)
        XCTAssertEqual(SpatialGrid.index(atSeconds: -4, totalFrames: total), 0)
        XCTAssertEqual(SpatialGrid.segmentCount(totalFrames: 0), 0)
        XCTAssertEqual(SpatialGrid.totalFrames(durationSec: .nan), 0)
    }

    func testMediaPlaylistListsFixedSegmentsAndAShorterLastOne() {
        let total = SpatialGrid.totalFrames(durationSec: 10)
        let playlist = SpatialGrid.mediaPlaylist(stream: 3, totalFrames: total, startOffsetSec: 12.5)
        let lines = playlist.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertTrue(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(lines.contains("#EXT-X-TARGETDURATION:4"))
        XCTAssertTrue(lines.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(lines.contains("#EXT-X-MAP:URI=\"aud-3-init.mp4\""))
        XCTAssertTrue(lines.contains { $0.hasPrefix("#EXT-X-START:TIME-OFFSET=12.500") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("#EXTINF:") },
                       ["#EXTINF:3.200000,", "#EXTINF:3.200000,", "#EXTINF:3.200000,", "#EXTINF:0.400000,"])
        XCTAssertEqual(lines.filter { !$0.hasPrefix("#") },
                       ["aud-3-00001.m4s", "aud-3-00002.m4s", "aud-3-00003.m4s", "aud-3-00004.m4s"])
        XCTAssertEqual(lines.last, "#EXT-X-ENDLIST")
    }

    func testRenditionFileNamesAreTheOnesTheServerRoutesOnRemuxAudioNames() {
        let initParsed = RemuxAudioTrack.parseFileName(SpatialGrid.initName(stream: 7))
        XCTAssertEqual(initParsed?.track, 7)
        XCTAssertNil(initParsed?.segment)
        let segment = RemuxAudioTrack.parseFileName(SpatialGrid.segmentName(stream: 7, number: 12))
        XCTAssertEqual(segment?.track, 7)
        XCTAssertEqual(segment?.segment, 12)
    }

    // MARK: - Which tracks are candidates

    func testAnnouncedKinds() {
        XCTAssertEqual(SpatialAudioPolicy.announcedKind(codec: "truehd", profile: 30, title: nil), .trueHDAtmos)
        XCTAssertEqual(SpatialAudioPolicy.announcedKind(codec: "truehd", profile: -99, title: "English TrueHD Atmos 7.1"),
                       .trueHDAtmos)
        XCTAssertNil(SpatialAudioPolicy.announcedKind(codec: "truehd", profile: -99, title: "English 7.1"))
        XCTAssertEqual(SpatialAudioPolicy.announcedKind(codec: "dts", profile: 61, title: nil), .dtsX)
        XCTAssertEqual(SpatialAudioPolicy.announcedKind(codec: "dts", profile: 62, title: nil), .dtsX)
        XCTAssertEqual(SpatialAudioPolicy.announcedKind(codec: "dts", profile: 60, title: "DTS:X 7.1"), .dtsX)
        XCTAssertNil(SpatialAudioPolicy.announcedKind(codec: "dts", profile: 60, title: "DTS-HD MA 5.1"))
        // Dolby Digital Plus Atmos is played as is by AVPlayer: not a candidate.
        XCTAssertNil(SpatialAudioPolicy.announcedKind(codec: "eac3", profile: 30, title: "Atmos"))
    }

    func testTheTrackTheViewerStartsOnIsProbedUnlessKnownToBeLossy() {
        XCTAssertEqual(SpatialAudioPolicy.probeKind(codec: "truehd", profile: -99), .trueHDAtmos)
        XCTAssertEqual(SpatialAudioPolicy.probeKind(codec: "dts", profile: FFmpegAudioProfile.dtsHDMA), .dtsX)
        XCTAssertEqual(SpatialAudioPolicy.probeKind(codec: "dts", profile: FFmpegAudioProfile.unknown), .dtsX)
        XCTAssertNil(SpatialAudioPolicy.probeKind(codec: "dts", profile: 20), "DTS core is lossy")
        XCTAssertNil(SpatialAudioPolicy.probeKind(codec: "dts", profile: 50), "DTS-HD High Resolution is lossy")
        XCTAssertNil(SpatialAudioPolicy.probeKind(codec: "aac", profile: 1))
    }

    func testTheRouterLabelsAnnouncedAtmosWithoutChangingTheEngine() {
        let atmos = AudioStreamInfo(index: 1, codec: "truehd", channels: 8, language: "eng", profile: 30, title: nil)
        let probe = ProbeResult(container: "matroska,webm", videoCodec: "hevc", videoProfile: 2, hdr: .hdr10,
                                dolbyVision: nil, audio: [atmos], subtitles: [], durationSec: 7200, seekable: true,
                                videoStreamCount: 1)
        let on = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, spatialAudio: true)
        XCTAssertEqual(on.engine, .native)
        XCTAssertEqual(on.spatialAudio, .trueHDAtmos)
        XCTAssertTrue(on.displayNote.hasSuffix("Atmos"))
        let off = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, spatialAudio: false)
        XCTAssertEqual(off.engine, .native)
        XCTAssertNil(off.spatialAudio)
        // The viewer's own choice of mpv is not overridden.
        XCTAssertEqual(PlayerEngineRouter.route(probe: probe, nativeDVEnabled: false, spatialAudio: true).engine, .mpv)
    }

    #if DEBUG
    func testRouterSelfChecksPass() {
        XCTAssertEqual(PlayerEngineRouter.selfCheckFailures(), [])
    }
    #endif

    // MARK: - What the viewer reads

    /// The sentence around the format names is translated, the names are not, so these check the names.
    func testDeliveredFormatDescriptions() {
        let atmos = SpatialAudioPolicy.deliveredDescription(for: .trueHDAtmos)
        XCTAssertTrue(atmos.contains("APAC 7.1.4") && atmos.contains("TrueHD Atmos"), atmos)
        let dtsX = SpatialAudioPolicy.deliveredDescription(for: .dtsX)
        XCTAssertTrue(dtsX.contains("APAC 7.1.4") && dtsX.contains("DTS:X"), dtsX)
        let flac = AudioTranscoder.deliveredFormatDescription(codec: "truehd", channels: 8, transcodes: true,
                                                              lossless: true)
        XCTAssertTrue(flac.contains("FLAC 7.1") && flac.contains("Dolby TrueHD 7.1"), flac)
        XCTAssertEqual(AudioTranscoder.deliveredFormatDescription(codec: "eac3", channels: 6, transcodes: false),
                       "Dolby Digital Plus 5.1")
    }

    func testTheMenuNamesWhatThePlayerGets() {
        XCTAssertEqual(SpatialAudioKind.trueHDAtmos.menuName, "Dolby Atmos")
        XCTAssertEqual(SpatialAudioKind.dtsX.menuName, "DTS:X")
        XCTAssertEqual(SpatialAudioKind.trueHDAtmos.sourceName, "TrueHD Atmos")
    }

    func testLosslessBitrateScalesWithChannels() {
        XCTAssertEqual(AudioTranscoder.losslessBitrate(sourceChannels: 8), 9_600_000)
        XCTAssertEqual(AudioTranscoder.losslessBitrate(sourceChannels: 6), 7_200_000)
    }

    // MARK: - Master playlist

    private func map() -> SegmentMap {
        SegmentMap.build(keyframeTicks: [0, 6_000, 12_000], timeBaseNum: 1, timeBaseDen: 1_000,
                         totalDurationSec: 18, segDurSec: 6)!
    }

    func testTheMasterListsTheApacRenditionAndDeclaresHdr10Plus() {
        var signaling = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: nil, videoRange: "PQ")
        signaling.hdr10Plus = true
        let renditions = [
            AudioRendition(streamIndex: 1, name: "English \u{00B7} Dolby Atmos", language: "en", channels: 12,
                           codecToken: "apac.31.03", isDefault: true, isSpatial: true),
            AudioRendition(streamIndex: 2, name: "French \u{00B7} Dolby Digital 5.1", language: "fr", channels: 6,
                           codecToken: "ac-3", isDefault: false),
        ]
        let master = map().masterPlaylist(signaling: signaling, audioRenditions: renditions, bandwidth: 20_000_000)
        XCTAssertTrue(master.contains("CODECS=\"hvc1.2.4.L153.B0,apac.31.03,ac-3\""))
        XCTAssertTrue(master.contains("CHANNELS=\"12\",URI=\"aud-1.m3u8\""))
        XCTAssertTrue(master.contains("SUPPLEMENTAL-CODECS=\"hvc1.2.4.L153.B0/cdm4\""))
        XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"))
    }

    func testDolbyVisionKeepsTheSupplementalSlotAndAPlainStreamDeclaresNothing() {
        var signaling = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: "dvh1.08.06/db1p", videoRange: "PQ")
        signaling.hdr10Plus = true
        let dv = map().masterPlaylist(signaling: signaling, audioRenditions: [], bandwidth: 20_000_000)
        XCTAssertTrue(dv.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        XCTAssertFalse(dv.contains("cdm4"))

        let plain = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: nil, videoRange: "PQ")
        XCTAssertFalse(map().masterPlaylist(signaling: plain, audioRenditions: [], bandwidth: 20_000_000)
            .contains("SUPPLEMENTAL-CODECS"))

        // HDR10+ on an SDR or H.264 stream is not a thing the master declares.
        var sdr = VideoSignaling(codecs: "avc1.640028", supplementalCodecs: nil, videoRange: nil)
        sdr.hdr10Plus = true
        XCTAssertFalse(map().masterPlaylist(signaling: sdr, audioRenditions: [], bandwidth: 20_000_000)
            .contains("SUPPLEMENTAL-CODECS"))
    }

    // MARK: - HDR10+ detection

    /// A length-prefixed HEVC NAL unit (4-byte prefix) of the given type with a payload after the two
    /// header bytes.
    private func nal(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var unit: [UInt8] = [type << 1, 0x01]
        unit.append(contentsOf: payload)
        var out: [UInt8] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8((unit.count >> shift) & 0xFF))
        }
        out.append(contentsOf: unit)
        return out
    }

    func testDetectsTheSt209440MessageInAPrefixSEI() {
        let t35: [UInt8] = Hdr10PlusDetector.t35Header + [0x01, 0x00, 0x00, 0x00]
        let sei: [UInt8] = [0x04, UInt8(t35.count)] + t35 + [0x80]
        let slice = nal(1, [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertTrue(Hdr10PlusDetector.containsHdr10Plus(packet: nal(39, sei) + slice, nalLengthSize: 4))
        // The message after other NAL units of the access unit, and in a suffix SEI.
        XCTAssertTrue(Hdr10PlusDetector.containsHdr10Plus(packet: nal(35, [0x10]) + nal(39, sei) + slice, nalLengthSize: 4))
        XCTAssertTrue(Hdr10PlusDetector.containsHdr10Plus(packet: slice + nal(40, sei), nalLengthSize: 4))
    }

    func testIgnoresOtherMessagesAndMalformedPackets() {
        // ATSC A/53 closed captions are a T.35 message too (provider 0x0031), but not HDR10+.
        let captions: [UInt8] = [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03]
        XCTAssertFalse(Hdr10PlusDetector.containsHdr10Plus(
            packet: nal(39, [0x04, UInt8(captions.count)] + captions + [0x80]), nalLengthSize: 4))
        // Not a registered-user-data message.
        XCTAssertFalse(Hdr10PlusDetector.containsHdr10Plus(
            packet: nal(39, [0x05, 0x04, 0x01, 0x02, 0x03, 0x04, 0x80]), nalLengthSize: 4))
        // Not an SEI NAL unit.
        let t35: [UInt8] = Hdr10PlusDetector.t35Header + [0x01]
        XCTAssertFalse(Hdr10PlusDetector.containsHdr10Plus(
            packet: nal(1, [0x04, UInt8(t35.count)] + t35), nalLengthSize: 4))
        // A length prefix that runs past the packet, an empty packet, a bad prefix size.
        XCTAssertFalse(Hdr10PlusDetector.containsHdr10Plus(packet: [0x00, 0x00, 0x00, 0x20, 0x4E], nalLengthSize: 4))
        XCTAssertFalse(Hdr10PlusDetector.containsHdr10Plus(packet: [], nalLengthSize: 4))
        XCTAssertFalse(Hdr10PlusDetector.containsHdr10Plus(packet: nal(39, [0x04]), nalLengthSize: 5))
    }

    // MARK: - Notices page

    func testNoticeChunksKeepAllTheText() {
        let text = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let chunks = NoticeChunk.split(text, linesPerChunk: 10)
        XCTAssertEqual(chunks.map(\.text).joined(separator: "\n"), text)
        XCTAssertEqual(chunks.map(\.id), Array(0..<chunks.count))
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty })
        // A blank line after a full chunk ends it there, so paragraphs stay whole.
        let paragraphs = (0..<5).map { index in (0..<12).map { "p\(index) l\($0)" }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        let cut = NoticeChunk.split(paragraphs, linesPerChunk: 12)
        XCTAssertEqual(cut.count, 5)
        XCTAssertTrue(cut.allSatisfy { $0.text.split(separator: "\n").count == 12 })
    }
}
