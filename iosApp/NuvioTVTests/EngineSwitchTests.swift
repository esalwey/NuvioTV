import XCTest
@testable import NuvioTV

/// Switching the player engine by hand: when the choice is offered, which engine it leads to, what
/// the transport bar and the Stream Info row show.
@MainActor
final class EngineSwitchTests: XCTestCase {

    private func engineSwitch(current: PlaybackEngine, nativeAvailable: Bool,
                              perform: @escaping (PlaybackEngine, Double) -> Void = { _, _ in }) -> PlayerEngineSwitch {
        PlayerEngineSwitch(current: current, nativeAvailable: nativeAvailable, perform: perform)
    }

    // MARK: - Availability

    func testTheNativePlayerAlwaysHasMpvToSwitchTo() {
        let native = engineSwitch(current: .native, nativeAvailable: false)
        XCTAssertTrue(native.canSwitch)
        XCTAssertEqual(native.alternative, .mpv)
    }

    func testMpvOffersNativeOnlyWhenNativeCanTakeTheStream() {
        let possible = engineSwitch(current: .mpv, nativeAvailable: true)
        XCTAssertTrue(possible.canSwitch)
        XCTAssertEqual(possible.alternative, .native)

        let ruledOut = engineSwitch(current: .mpv, nativeAvailable: false)
        XCTAssertFalse(ruledOut.canSwitch)
        XCTAssertNil(ruledOut.alternative)
    }

    func testPerformHandsTheStreamOverAtThePosition() {
        var handedOver: (PlaybackEngine, Double)?
        let action = engineSwitch(current: .mpv, nativeAvailable: true) { engine, position in
            handedOver = (engine, position)
        }
        action.perform(.native, 1_234.5)
        XCTAssertEqual(handedOver?.0, .native)
        XCTAssertEqual(handedOver?.1, 1_234.5)
    }

    // MARK: - Override

    func testAFallbackPinsMpvAndAManualChoicePinsTheEngineAskedFor() {
        XCTAssertEqual(PlayerEngineOverride.fallback.engine, .mpv)
        XCTAssertEqual(PlayerEngineOverride.manual(.mpv).engine, .mpv)
        XCTAssertEqual(PlayerEngineOverride.manual(.native).engine, .native)
    }

    func testTheStreamInfoRowNamesTheEngineAndWhyItIsThere() {
        let notes = [PlayerEngineOverride.fallback.note,
                     PlayerEngineOverride.manual(.native).note,
                     PlayerEngineOverride.manual(.mpv).note]
        XCTAssertEqual(Set(notes).count, 3)
        XCTAssertTrue(PlayerEngineOverride.manual(.mpv).note.contains("mpv"))
        XCTAssertTrue(PlayerEngineOverride.fallback.note.contains("mpv"))
    }

    func testEnginesHaveDistinctMenuTitles() {
        XCTAssertNotEqual(PlaybackEngine.native.menuTitle, PlaybackEngine.mpv.menuTitle)
        XCTAssertEqual(PlaybackEngine.mpv.menuTitle, "mpv")
    }

    // MARK: - Transport bar

    func testThePlayerEngineItemIsOfferedOnlyOnRequestAndComesLastOfTheAppItems() {
        let without = PlayerTransportMenus.customItems(canChooseSource: true, supportsSubtitleDelay: true)
        XCTAssertFalse(without.contains(.engine))

        let with = PlayerTransportMenus.customItems(canChooseSource: true, supportsSubtitleDelay: true,
                                                    canSwitchEngine: true)
        XCTAssertEqual(with.last, .engine)
        XCTAssertEqual(Array(with.dropLast()), without)
    }

    func testTheSystemSubtitlesAndAudioButtonsStillEndTheBar() {
        let items = PlayerTransportMenus.items(canChooseSource: false, supportsSubtitleDelay: false,
                                               canSwitchEngine: true)
        XCTAssertEqual(Array(items.suffix(3)), [.engine, .subtitles, .audio])
        XCTAssertFalse(PlayerTransportItem.engine.isSystemItem)
    }

    func testThePlayerEngineItemHasATitleAndASymbol() {
        XCTAssertFalse(PlayerTransportItem.engine.title.isEmpty)
        XCTAssertFalse(PlayerTransportItem.engine.symbol.isEmpty)
        XCTAssertNotEqual(PlayerTransportItem.engine.title, PlayerTransportItem.aspect.title)
    }
}
