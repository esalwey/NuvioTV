import CoreMedia
import Foundation
import SharedCore

/// The one description of how subtitles look, built from the Settings > Playback > Subtitles style
/// (`SubtitleStyleState`) and read by BOTH engines, so the same inputs can never render two
/// different looks again (polish pass: a dark box behind the text on the native player, none on
/// mpv, because the native rule only carried the values that differed from the defaults and left
/// the rest to the system caption profile).
///
/// Layering, as Apple does it: the system caption appearance (Settings > Accessibility > Subtitles &
/// Captioning) is the base, the explicit app choices described here override it, and the values the
/// viewer marked "override" in the system profile win over both. The native engine gets the last
/// step from AVFoundation itself; mpv does it in `SystemCaptionStyle`.
///
/// Every field is resolved explicitly (no "unset"): a transparent background is a transparent
/// background, not "whatever the system profile says". The mpv mapping lives here as plain numbers
/// (`mpv*`), the AVPlayer mapping as one `AVTextStyleRule` attribute set (`avTextMarkupAttributes`).
struct SubtitleRenderStyle: Equatable {
    /// Colours are `SubtitleColor` argb longs (0xAARRGGBB), as stored by the shared settings.
    var textARGB: Int64 = 0xFFFF_FFFF
    var backgroundARGB: Int64 = 0x0000_0000
    var outlineARGB: Int64 = 0xFF00_0000
    var outlineEnabled = true
    var outlineWidth = 2
    var bold = false
    var fontSizeSp = Self.defaultFontSizeSp
    /// Shared setting units (0...200, default 20); one unit is a tenth of a percent of the height.
    var bottomOffset = Self.defaultBottomOffset

    static let defaultFontSizeSp = 18
    static let defaultBottomOffset = 20

    init() {}

    init(_ state: SubtitleStyleState) {
        textARGB = state.textColor
        backgroundARGB = state.backgroundColor
        outlineARGB = state.outlineColor
        outlineEnabled = state.outlineEnabled
        outlineWidth = Int(state.outlineWidth)
        bold = state.bold
        fontSizeSp = Int(state.fontSizeSp)
        bottomOffset = Int(state.bottomOffset)
    }

    /// The settings may not have hydrated yet when a player starts: the shared defaults then.
    init(_ state: SubtitleStyleState?) {
        if let state { self.init(state) } else { self.init() }
    }

    // MARK: - Shared decisions

    var backgroundAlpha: Int64 { (backgroundARGB >> 24) & 0xFF }

    /// A box is drawn behind the text only when the outline is off and the background is visible
    /// (the Android player's rule, kept on both engines). Otherwise the text sits on the picture
    /// with its outline, and the background is explicitly cleared.
    var drawsBox: Bool { !outlineEnabled && backgroundAlpha > 0 }

    /// Line height as a percentage of the picture height: the default size (18 sp) is 5 %, the
    /// 54 pt line of spec 8.3 at 1080p. The system "Large Text" caption style scales it on top.
    var heightPercent: Double { Double(mpvFontSize) / 720 * 100 }

    // MARK: - mpv

    /// `sub-font-size`, in mpv's 720-line reference pixels (2 per sp: 18 sp = 36 = 5 % of the height,
    /// the spec 8.3 default, shared with the native engine's relative size). The ceiling is the one
    /// mpv always had (122), so a large-text setting is not capped below what it used to reach.
    var mpvFontSize: Int64 { Int64(max(20, min(122, fontSizeSp * 2))) }

    var mpvBorderStyle: String { drawsBox ? "opaque-box" : "outline-and-shadow" }

    var mpvOutlineSize: Int64 {
        guard outlineEnabled else { return 0 }
        return Int64(max(1, Int(Double(outlineWidth) * 1.5)))
    }

    /// Bottom margin of the subtitle block in percent of the picture height: 5 % by default (about the
    /// 60 pt safe-area margin of spec 8.3, where the native player puts its captions), +/- a tenth
    /// of a percent per setting unit away from the default.
    var bottomMarginPercent: Int {
        max(0, min(30, 5 + (bottomOffset - Self.defaultBottomOffset) / 10))
    }

    /// `sub-pos`: 100 is the bottom edge.
    var mpvSubPos: Int64 { Int64(100 - bottomMarginPercent) }

    /// Height of the transport chrome (title, scrubber, times, buttons, tabs) in percent of the picture
    /// height. While it is on screen the captions ride above it, as the system player lifts them
    /// (spec 8.3: "raised to clear the chrome while the chrome is visible").
    static let chromeClearancePercent = 27

    /// `sub-pos` while the chrome is up: never lower than the resting position's own margin.
    var mpvSubPosWithChrome: Int64 { min(mpvSubPos, Int64(100 - Self.chromeClearancePercent)) }

    /// While the content tabs' view is up (the pills and the panel take the middle of the picture) the
    /// captions ride above it, around a quarter of the way down the picture. [observed: owner video
    /// 2026-10-16] they jump from just over the bar to 23 % from the top at 29.523 s, as the tab view
    /// comes in, and stay there while it is open (29.8 to 36.0 s).
    static let tabsClearancePercent = 70

    /// `sub-pos` while the tab view is up.
    var mpvSubPosWithTabs: Int64 { min(mpvSubPos, Int64(100 - Self.tabsClearancePercent)) }

    /// "#AARRGGBB" for `sub-color` and friends.
    static func mpvColor(_ argb: Int64) -> String {
        let a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }

    // MARK: - AVPlayer

    /// The `AVTextStyleRule` attributes. Complete on purpose: with a rule that only carries the
    /// non-default values, AVPlayer falls back to the system caption profile for everything else
    /// (which can draw a dark background box and its own edge style). The outline colour has no
    /// CoreMedia equivalent (the edge is always dark), so only black outlines match mpv exactly.
    func avTextMarkupAttributes() -> [String: Any] {
        var attributes: [String: Any] = [:]
        attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] = Self.argbComponents(textARGB)
        // Character background = the box behind the glyphs; background = the window behind the
        // whole caption. Both stay clear unless the app style asks for a box.
        let clear = Self.argbComponents(0)
        attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] =
            drawsBox ? Self.argbComponents(backgroundARGB) : clear
        attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] = clear
        attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
            (outlineEnabled ? kCMTextMarkupCharacterEdgeStyle_Uniform : kCMTextMarkupCharacterEdgeStyle_None) as String
        attributes[kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String] =
            NSNumber(value: heightPercent)
        if bold {
            attributes[kCMTextMarkupAttribute_BoldStyle as String] = true
        }
        return attributes
    }

    /// 0xAARRGGBB -> [A, R, G, B] in 0...1, the form CoreMedia's text-markup colour attributes take.
    static func argbComponents(_ argb: Int64) -> [NSNumber] {
        let a = Double((argb >> 24) & 0xFF) / 255, r = Double((argb >> 16) & 0xFF) / 255
        let g = Double((argb >> 8) & 0xFF) / 255, b = Double(argb & 0xFF) / 255
        return [a, r, g, b].map { NSNumber(value: $0) }
    }
}
