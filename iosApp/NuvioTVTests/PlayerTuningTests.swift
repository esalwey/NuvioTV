import XCTest
@testable import NuvioTV

/// The pure parts of the mpv audio/video tuning and the Dolby Vision picker: how stored values map
/// to modes, and which mpv options and filters they become. The defaults must equal what the player
/// wrote out before these settings existed.
final class PlayerTuningTests: XCTestCase {

    // MARK: Dolby Vision mode

    func testDolbyVisionModeFollowsTheLegacySwitches() {
        XCTAssertEqual(DolbyVisionMode.resolve(nativeEnabled: true, p7FelToMpv: false, hdr10Only: false), .automatic)
        XCTAssertEqual(DolbyVisionMode.resolve(nativeEnabled: true, p7FelToMpv: true, hdr10Only: false), .hdr10Fel)
        XCTAssertEqual(DolbyVisionMode.resolve(nativeEnabled: false, p7FelToMpv: false, hdr10Only: false), .off)
        XCTAssertEqual(DolbyVisionMode.resolve(nativeEnabled: false, p7FelToMpv: true, hdr10Only: true), .off)
        XCTAssertEqual(DolbyVisionMode.resolve(nativeEnabled: true, p7FelToMpv: false, hdr10Only: true), .hdr10Only)
    }

    func testDolbyVisionModeRoutingFlags() {
        XCTAssertTrue(DolbyVisionMode.automatic.nativeEngineEnabled)
        XCTAssertFalse(DolbyVisionMode.automatic.sendsP7FelToMpv)
        XCTAssertTrue(DolbyVisionMode.hdr10Fel.sendsP7FelToMpv)
        XCTAssertTrue(DolbyVisionMode.hdr10Only.stripsDolbyVision)
        XCTAssertFalse(DolbyVisionMode.hdr10Only.playsDolbyVision)
        XCTAssertFalse(DolbyVisionMode.off.nativeEngineEnabled)
        XCTAssertTrue(DolbyVisionMode.hdr10Fel.playsDolbyVision)
    }

    // MARK: Audio

    func testAudioOutputLayouts() {
        XCTAssertEqual(AudioOutputMode.auto.mpvChannels, "auto")
        XCTAssertEqual(AudioOutputMode.stereo.mpvChannels, "stereo")
        XCTAssertEqual(AudioOutputMode.surround51.mpvChannels, "5.1,stereo")
        XCTAssertEqual(AudioOutputMode.surround71.mpvChannels, "7.1,5.1,stereo")
        XCTAssertFalse(AudioOutputMode.auto.normalizesDownmix)
        XCTAssertTrue(AudioOutputMode.stereo.normalizesDownmix)
    }

    func testVolumeBoostIsUnityAtZeroAndDoublesAtSixDecibels() {
        XCTAssertEqual(MPVAudioSettings.volumePercent(gainDb: 0), 100, accuracy: 0.001)
        XCTAssertEqual(MPVAudioSettings.volumePercent(gainDb: 6), 199.526, accuracy: 0.01)
        XCTAssertLessThan(MPVAudioSettings.volumePercent(gainDb: 10), Double(MPVAudioSettings.volumeMaxPercent))
    }

    func testDialogueBoostFilter() {
        XCTAssertEqual(MPVAudioSettings.audioFilter(dialogueDb: 0, stereoOutput: true), "")
        XCTAssertEqual(MPVAudioSettings.audioFilter(dialogueDb: 6, stereoOutput: false), "")
        let filter = MPVAudioSettings.audioFilter(dialogueDb: 6, stereoOutput: true)
        XCTAssertTrue(filter.hasPrefix("lavfi=[aresample="))
        XCTAssertTrue(filter.contains("out_chlayout=stereo"))
        XCTAssertTrue(filter.contains("center_mix_level=1.411"))
    }

    // MARK: Video

    func testVideoDefaultsMatchThePreviousHardcodedOptions() {
        let options = MPVVideoSettings().startupOptions().map { "\($0.0)=\($0.1)" }
        XCTAssertEqual(options, ["hwdec=videotoolbox", "tone-mapping=auto", "hdr-compute-peak=yes"])
        XCTAssertTrue(MPVVideoSettings().isDefault)
    }

    func testVideoOptionsForCustomValues() {
        var settings = MPVVideoSettings()
        settings.toneMapping = .bt2390
        settings.hardwareDecoding = .software
        settings.hdrPeakDetection = false
        settings.deband = true
        settings.interpolation = true
        settings.brightness = -10
        settings.gamma = 20
        let options = settings.startupOptions().map { "\($0.0)=\($0.1)" }
        XCTAssertEqual(options, [
            "hwdec=no", "tone-mapping=bt.2390", "hdr-compute-peak=no", "deband=yes",
            "video-sync=display-resample", "interpolation=yes", "brightness=-10", "gamma=20",
        ])
        XCTAssertFalse(settings.isDefault)
    }
}
