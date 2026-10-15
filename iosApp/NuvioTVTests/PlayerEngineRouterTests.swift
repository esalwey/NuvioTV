import XCTest
@testable import NuvioTV

/// The engine router: native first, mpv for what AVPlayer cannot play, the Player preference, the
/// Dolby Vision handling. Canned probe results stand in for streams. The same cases run as the DEBUG
/// self-check at first playback (`PlayerEngineRouter.selfCheckFailures`).
final class PlayerEngineRouterTests: XCTestCase {

    // MARK: Helpers

    private func probe(video: String = "hevc", dv: DolbyVisionInfo? = nil, hdr: HDRFormat = .sdr,
                       audio: [String] = ["eac3"], seekable: Bool = true,
                       container: String = "matroska,webm", videoStreams: Int = 1,
                       profile: Int32 = 0, fieldOrder: Int32 = 0, bitDepth: Int32 = 0,
                       width: Int32 = 0, height: Int32 = 0, level: Int32 = -99) -> ProbeResult {
        ProbeResult(
            container: container, videoCodec: video, videoProfile: profile, hdr: hdr, dolbyVision: dv,
            audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
            subtitles: [], durationSec: 3600, seekable: seekable, videoStreamCount: videoStreams,
            videoWidth: width, videoHeight: height, videoLevel: level, videoBitDepth: bitDepth,
            videoFieldOrder: fieldOrder
        )
    }

    private func route(_ probe: ProbeResult?, preference: PlayerEnginePreference = .automatic,
                       felToMpv: Bool = false, strip: Bool = false, av1: Bool = false) -> EngineDecision {
        PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv,
                                 stripDolbyVision: strip,
                                 options: RoutingOptions(enginePreference: preference, hardwareAV1: av1))
    }

    private let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
    private let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
    private let p9 = DolbyVisionInfo(profile: 9, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 2)
    private func p7(_ kind: DVELKind?) -> DolbyVisionInfo {
        DolbyVisionInfo(profile: 7, level: 6, blPresent: true, elPresent: true, rpuPresent: true,
                        compatId: 0, elKind: kind)
    }

    // MARK: Native first

    func testCommonFilesGoNative() {
        XCTAssertEqual(route(probe()).engine, .native)
        XCTAssertEqual(route(probe(video: "h264", profile: 100)).engine, .native)
        XCTAssertEqual(route(probe(hdr: .hdr10, profile: 2, bitDepth: 10, width: 3840, height: 2160, level: 153)).engine, .native)
        XCTAssertEqual(route(probe(container: "mov,mp4,m4a,3gp,3g2,mj2")).engine, .native)
    }

    func testWhatAVPlayerCannotDecodeGoesToMpv() {
        XCTAssertEqual(route(probe(video: "vp9")).engine, .mpv)
        XCTAssertEqual(route(probe(video: "mpeg2video")).engine, .mpv)
        XCTAssertEqual(route(probe(video: "h264", profile: 110)).engine, .mpv)
        XCTAssertEqual(route(probe(video: "h264", profile: 244)).engine, .mpv)
        XCTAssertEqual(route(probe(container: "avi")).engine, .mpv)
        XCTAssertEqual(route(probe(container: "mpegts")).engine, .mpv)
        XCTAssertEqual(route(probe(seekable: false)).engine, .mpv)
    }

    func testHEVCTheAppleTVCannotDecodeGoesToMpv() {
        XCTAssertEqual(route(probe(profile: 4)).engine, .mpv, "RExt: 4:2:2, 4:4:4, 12-bit")
        XCTAssertEqual(route(probe(profile: 2, bitDepth: 12)).engine, .mpv)
        XCTAssertEqual(route(probe(profile: 2, width: 7680, height: 4320)).engine, .mpv, "8K")
        XCTAssertEqual(route(probe(profile: 2, level: 186)).engine, .mpv, "level 6.2")
        XCTAssertEqual(route(probe(profile: 2, width: 2160, height: 3840)).engine, .native, "portrait 4K")
        XCTAssertEqual(route(probe(profile: 2, level: 156)).engine, .native, "level 5.2 is AVPlayer's to refuse")
        XCTAssertEqual(route(probe(profile: -99)).engine, .native, "an unknown profile passes")
        XCTAssertNotNil(PlayerEngineRouter.unsupportedHEVCReason(probe(profile: 4)))
        XCTAssertNil(PlayerEngineRouter.unsupportedHEVCReason(probe(profile: 1, bitDepth: 8, width: 1920, height: 1080)))
    }

    func testInterlacedVideoGoesToMpvUnlessNativeIsPreferred() {
        let interlaced = probe(video: "h264", fieldOrder: 2)
        XCTAssertEqual(route(interlaced).engine, .mpv)
        XCTAssertEqual(route(interlaced, preference: .preferNative).engine, .native)
        XCTAssertEqual(route(probe(video: "h264", fieldOrder: 1)).engine, .native, "progressive")
        XCTAssertEqual(route(probe(video: "h264", fieldOrder: 0)).engine, .native, "unknown")
        XCTAssertTrue(PlayerEngineRouter.isInterlaced(probe(fieldOrder: 5)))
        XCTAssertFalse(PlayerEngineRouter.isInterlaced(probe(fieldOrder: 1)))
    }

    func testAudioTheRemuxCanDecodeNoLongerSendsAFileToMpv() {
        for codec in ["truehd", "dts", "opus", "vorbis", "pcm_s16le", "pcm_bluray", "mp2", "mp3"] {
            XCTAssertEqual(route(probe(audio: [codec])).engine, .native, codec)
        }
        XCTAssertEqual(route(probe(audio: ["wmav2"])).engine, .mpv, "no one asked libavcodec")
        XCTAssertEqual(route(probe(audio: [])).engine, .native, "video only")
    }

    func testAnAudioTrackLibavcodecCanDecodeCountsWhateverItsName() {
        var track = AudioStreamInfo(index: 0, codec: "wmav2", channels: 2, language: "eng")
        track.decodable = true
        var file = probe(audio: [])
        file.audio = [track]
        XCTAssertEqual(route(file).engine, .native)
        file.audio[0].decodable = false
        XCTAssertEqual(route(file).engine, .mpv)
    }

    func testAnUnreadableStreamIsMpvUnlessNativeIsPreferred() {
        XCTAssertEqual(route(nil).engine, .mpv)
        XCTAssertEqual(route(nil, preference: .preferNative).engine, .native)
        XCTAssertEqual(PlayerEngineRouter.route(probe: nil, nativeDVEnabled: false,
                                                options: RoutingOptions(enginePreference: .preferNative)).engine, .mpv)
    }

    // MARK: Spatial audio and the native-first rules together

    func testSpatialAudioLabelsARemuxedNativeDecisionOnly() {
        var atmos = probe(hdr: .hdr10, audio: ["truehd", "ac3"])
        atmos.audio[0].profile = Int32(FFmpegAudioProfile.trueHDAtmos)
        let remuxed = PlayerEngineRouter.route(probe: atmos, nativeDVEnabled: true, spatialAudio: true)
        XCTAssertEqual(remuxed.engine, .native)
        XCTAssertEqual(remuxed.delivery, .remux)
        XCTAssertEqual(remuxed.spatialAudio, .trueHDAtmos)
        // The Player preference is explicit and wins over the audio format.
        let preferMpv = PlayerEngineRouter.route(probe: atmos, nativeDVEnabled: true, spatialAudio: true,
                                                 options: RoutingOptions(enginePreference: .preferMpv))
        XCTAssertEqual(preferMpv.engine, .mpv)
        XCTAssertNil(preferMpv.spatialAudio)
        // An HLS stream AVPlayer opens itself has no APAC conversion.
        var hls = probe(video: "h264", audio: ["eac3", "truehd"], container: "hls")
        hls.audio[1].profile = Int32(FFmpegAudioProfile.trueHDAtmos)
        let direct = PlayerEngineRouter.route(probe: hls, nativeDVEnabled: true, spatialAudio: true)
        XCTAssertEqual(direct.delivery, .directHLS)
        XCTAssertNil(direct.spatialAudio)
    }

    // MARK: Dolby Vision

    func testDolbyVisionThatPlaysAsDolbyVisionStaysNative() {
        for dv in [p5, p81, p7(.mel), p7(.fel)] {
            let decision = route(probe(dv: dv))
            XCTAssertEqual(decision.engine, .native)
            XCTAssertEqual(decision.dvHandling, .passthrough)
        }
        XCTAssertEqual(route(probe(dv: p7(.fel)), felToMpv: true).engine, .mpv, "FEL fidelity")
        XCTAssertEqual(route(probe(dv: p7(.mel)), felToMpv: true).engine, .native)
    }

    func testDolbyVisionThatCannotBePlayedAsSuchPlaysNativelyAsItsBaseLayer() {
        let stripped: [(String, ProbeResult)] = [
            ("two-track P7", probe(dv: p7(.mel), videoStreams: 2)),
            ("P7 without RPUs", probe(dv: p7(.missing))),
            ("P7 unparseable RPU", probe(dv: p7(.unsupported))),
            ("P7 unclassified", probe(dv: p7(nil))),
            ("P9", probe(video: "h264", dv: p9)),
        ]
        for (name, file) in stripped {
            let decision = route(file)
            XCTAssertEqual(decision.engine, .native, name)
            XCTAssertEqual(decision.dvHandling, .stripToBase, name)
        }
    }

    func testHDR10OnlyStripsEveryDolbyVisionFileButProfile5() {
        let p81Decision = route(probe(dv: p81), strip: true)
        XCTAssertEqual(p81Decision.engine, .native)
        XCTAssertEqual(p81Decision.dvHandling, .stripToBase)
        XCTAssertEqual(route(probe(dv: p7(.mel)), strip: true).dvHandling, .stripToBase)
        let p5Decision = route(probe(dv: p5), strip: true)
        XCTAssertEqual(p5Decision.engine, .native)
        XCTAssertEqual(p5Decision.dvHandling, .passthrough, "Profile 5 has no base layer")
        XCTAssertEqual(route(probe(hdr: .hdr10), strip: true).dvHandling, .passthrough)
    }

    func testTheDolbyVisionProfileTravelsWithEveryDecision() {
        let p5OnMpv = route(probe(dv: p5, seekable: false))
        XCTAssertEqual(p5OnMpv.engine, .mpv)
        XCTAssertTrue(p5OnMpv.needsDVReshapeOnMPV)
        XCTAssertFalse(route(probe(dv: p81)).needsDVReshapeOnMPV)
    }

    // MARK: HLS

    func testHLSIsOpenedByAVPlayerItself() {
        let hls = route(probe(video: "h264", audio: ["aac"], seekable: false, container: "hls"))
        XCTAssertEqual(hls.engine, .native)
        XCTAssertEqual(hls.delivery, .directHLS)
        XCTAssertEqual(route(probe(video: "vp9", audio: ["aac"], container: "hls")).engine, .mpv)
        XCTAssertEqual(route(probe(video: "h264", audio: ["dts"], container: "hls")).engine, .mpv)
        XCTAssertEqual(route(probe(video: "h264", audio: ["aac"], container: "hls"), preference: .preferMpv).engine, .mpv)
    }

    func testAPlaylistURLNeedsNoProbe() {
        XCTAssertTrue(PlayerEngineRouter.isHLSURL(URL(string: "https://media.example.com/jellyfin/videos/1/master.m3u8?MediaSourceId=1")!))
        XCTAssertTrue(PlayerEngineRouter.isHLSURL(URL(string: "https://example.com/live/index.M3U8")!))
        XCTAssertFalse(PlayerEngineRouter.isHLSURL(URL(string: "https://example.com/movie.mkv")!))
        XCTAssertFalse(PlayerEngineRouter.isHLSURL(URL(string: "https://example.com/stream?playlist=a.m3u8")!))
        let decision = PlayerEngineRouter.routeHLS(nativeDVEnabled: true)
        XCTAssertEqual(decision.engine, .native)
        XCTAssertEqual(decision.delivery, .directHLS)
        XCTAssertEqual(PlayerEngineRouter.routeHLS(nativeDVEnabled: false).engine, .mpv)
        XCTAssertEqual(PlayerEngineRouter.routeHLS(nativeDVEnabled: true,
                                                   options: RoutingOptions(enginePreference: .preferMpv)).engine, .mpv)
    }

    // MARK: AV1

    func testAV1GoesNativeOnlyWithAHardwareDecoder() {
        XCTAssertEqual(route(probe(video: "av1")).engine, .mpv)
        XCTAssertEqual(route(probe(video: "av1"), av1: true).engine, .native)
    }

    // MARK: The Player preference

    func testPreferMpvKeepsOnlyTrueDolbyVisionNative() {
        XCTAssertEqual(route(probe(), preference: .preferMpv).engine, .mpv)
        XCTAssertEqual(route(probe(hdr: .hdr10), preference: .preferMpv).engine, .mpv)
        XCTAssertEqual(route(probe(dv: p81), preference: .preferMpv).engine, .native)
        XCTAssertEqual(route(probe(dv: p81), preference: .preferMpv, strip: true).engine, .mpv)
        XCTAssertEqual(route(probe(dv: p7(.mel), videoStreams: 2), preference: .preferMpv).engine, .mpv)
    }

    func testTheNativePlayerStaysPossibleWhateverThePreference() {
        let mpvPreferred = RoutingOptions(enginePreference: .preferMpv)
        XCTAssertTrue(PlayerEngineRouter.nativeCouldPlay(probe: probe(), options: mpvPreferred))
        XCTAssertFalse(PlayerEngineRouter.nativeCouldPlay(probe: probe(video: "vp9"), options: mpvPreferred))
        XCTAssertTrue(PlayerEngineRouter.nativeCouldPlay(probe: nil, options: mpvPreferred))
    }

    func testThePreferenceIsStoredAndAbsentMeansAutomatic() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PlayerTuning.enginePreferenceKey)
        defer {
            if let saved { defaults.set(saved, forKey: PlayerTuning.enginePreferenceKey) }
            else { defaults.removeObject(forKey: PlayerTuning.enginePreferenceKey) }
        }
        defaults.removeObject(forKey: PlayerTuning.enginePreferenceKey)
        XCTAssertEqual(PlayerEnginePreference.current, .automatic)
        for preference in PlayerEnginePreference.allCases {
            preference.store()
            XCTAssertEqual(PlayerEnginePreference.current, preference)
        }
        defaults.set("nonsense", forKey: PlayerTuning.enginePreferenceKey)
        XCTAssertEqual(PlayerEnginePreference.current, .automatic)
    }

    func testEveryPreferenceHasATitleAndADetail() {
        for preference in PlayerEnginePreference.allCases {
            XCTAssertFalse(preference.title.isEmpty)
            XCTAssertFalse(preference.detail(nativeEngineEnabled: true).isEmpty)
        }
        XCTAssertNotEqual(PlayerEnginePreference.automatic.detail(nativeEngineEnabled: true),
                          PlayerEnginePreference.automatic.detail(nativeEngineEnabled: false))
    }
}
