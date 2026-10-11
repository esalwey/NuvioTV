import CoreMedia
import XCTest
@testable import NuvioTV

/// The subtitle look both engines are built from: the default style must describe the SAME picture
/// on mpv and on AVPlayer, and the native rule must always carry the full style (never "unset", which
/// let the system caption profile draw a dark box).
final class SubtitleRenderStyleTests: XCTestCase {

    func testDefaultStyleHasNoBoxAndAnOutline() {
        let style = SubtitleRenderStyle()
        XCTAssertFalse(style.drawsBox)
        XCTAssertEqual(style.mpvBorderStyle, "outline-and-shadow")
        XCTAssertEqual(style.mpvOutlineSize, 3)
        XCTAssertEqual(style.mpvFontSize, 36)
        XCTAssertEqual(style.heightPercent, 5, accuracy: 0.001)
        XCTAssertEqual(style.mpvSubPos, 95)
    }

    func testDefaultNativeRuleClearsEveryBackground() {
        let attributes = SubtitleRenderStyle().avTextMarkupAttributes()
        let characterBackground = attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [NSNumber]
        let background = attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] as? [NSNumber]
        XCTAssertEqual(characterBackground?.first?.doubleValue, 0)
        XCTAssertEqual(background?.first?.doubleValue, 0)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String,
                       kCMTextMarkupCharacterEdgeStyle_Uniform as String)
        XCTAssertNotNil(attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String])
        XCTAssertNotNil(attributes[kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String])
    }

    func testBoxOnlyWithoutOutlineAndWithVisibleBackground() {
        var style = SubtitleRenderStyle()
        style.backgroundARGB = 0x8000_0000
        XCTAssertFalse(style.drawsBox, "the outline wins, as on the Android player")
        style.outlineEnabled = false
        XCTAssertTrue(style.drawsBox)
        XCTAssertEqual(style.mpvBorderStyle, "opaque-box")
        XCTAssertEqual(style.mpvOutlineSize, 0)
        let attributes = style.avTextMarkupAttributes()
        let characterBackground = attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [NSNumber]
        XCTAssertEqual(characterBackground?.first?.doubleValue ?? 0, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String,
                       kCMTextMarkupCharacterEdgeStyle_None as String)
    }

    func testSizeAndPositionScaleFromTheSettings() {
        var style = SubtitleRenderStyle()
        style.fontSizeSp = 30
        XCTAssertEqual(style.mpvFontSize, 60)
        style.bottomOffset = 0
        XCTAssertEqual(style.mpvSubPos, 97)
        style.bottomOffset = 200
        XCTAssertEqual(style.mpvSubPos, 77)
    }

    func testMpvColorString() {
        XCTAssertEqual(SubtitleRenderStyle.mpvColor(0xFFFF_FF00), "#FFFFFF00")
        XCTAssertEqual(SubtitleRenderStyle.mpvColor(0x0000_0000), "#00000000")
    }
}
