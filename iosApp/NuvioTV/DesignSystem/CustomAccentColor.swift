import Foundation

/// Pure colour maths behind the Custom theme editor (Settings > Appearance > Custom Color).
///
/// The editor offers hue / saturation / brightness pickers plus a hex field; this type converts
/// between a packed `0xRRGGBB` and HSB and parses what the user types. No UIKit/SwiftUI so it is
/// unit-testable. The shared Kotlin `CustomThemeColors` owns storage and the accent/focus pair;
/// this only drives the editor controls.
enum CustomAccentColor {

    /// Hue steps offered in the editor (degrees), saturation and brightness steps (percent).
    static let hueSteps: [Int] = Array(stride(from: 0, through: 350, by: 10))
    static let saturationSteps: [Int] = Array(stride(from: 0, through: 100, by: 5))
    static let brightnessSteps: [Int] = Array(stride(from: 10, through: 100, by: 5))

    /// Curated starting points shown above the pickers. Hex only: the localised names live with
    /// the theme labels, these are not themes.
    static let presets: [UInt32] = [
        0xE53935, 0xFF7043, 0xFFB300, 0xC0CA33, 0x43A047, 0x00ACC1,
        0x1E88E5, 0x3949AB, 0x8E24AA, 0xD81B60, 0xEC70A9, 0x8D6E63,
    ]

    struct HSB: Equatable {
        /// Degrees, 0..<360.
        var hue: Int
        /// Percent, 0...100.
        var saturation: Int
        /// Percent, 0...100.
        var brightness: Int
    }

    /// `#RRGGBB` / `RRGGBB` (any case, surrounding whitespace ignored) -> packed RGB, or nil.
    static func parse(hex text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return value
    }

    /// `#RRGGBB`, upper case.
    static func hexString(_ rgb: UInt32) -> String {
        String(format: "#%06X", rgb & 0xFFFFFF)
    }

    /// Packed RGB -> HSB with whole-number hue degrees and percentages.
    static func hsb(fromRGB rgb: UInt32) -> HSB {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxC == g {
                hue = 60.0 * (((b - r) / delta) + 2)
            } else {
                hue = 60.0 * (((r - g) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let saturation = maxC == 0 ? 0 : delta / maxC
        return HSB(
            hue: Int(hue.rounded()) % 360,
            saturation: Int((saturation * 100).rounded()),
            brightness: Int((maxC * 100).rounded())
        )
    }

    /// HSB -> packed RGB. Inputs are clamped (hue wraps).
    static func rgb(from hsb: HSB) -> UInt32 {
        let h = Double(((hsb.hue % 360) + 360) % 360)
        let s = Double(min(max(hsb.saturation, 0), 100)) / 100.0
        let v = Double(min(max(hsb.brightness, 0), 100)) / 100.0

        let c = v * s
        let x = c * (1 - abs((h / 60.0).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        let components: (Double, Double, Double)
        switch h {
        case ..<60:  components = (c, x, 0)
        case ..<120: components = (x, c, 0)
        case ..<180: components = (0, c, x)
        case ..<240: components = (0, x, c)
        case ..<300: components = (x, 0, c)
        default:     components = (c, 0, x)
        }
        let (r, g, b) = components

        func byte(_ channel: Double) -> UInt32 {
            UInt32(min(max(((channel + m) * 255.0).rounded(), 0), 255))
        }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    /// The step in `steps` closest to `value`, so a picker whose options are a coarse grid always
    /// holds a selection that is one of them.
    static func snap(_ value: Int, to steps: [Int]) -> Int {
        steps.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// `hsb(fromRGB:)` with every component snapped to the editor's grid.
    static func snappedHSB(fromRGB rgb: UInt32) -> HSB {
        let raw = hsb(fromRGB: rgb)
        return HSB(
            hue: snap(raw.hue, to: hueSteps),
            saturation: snap(raw.saturation, to: saturationSteps),
            brightness: snap(raw.brightness, to: brightnessSteps)
        )
    }
}
