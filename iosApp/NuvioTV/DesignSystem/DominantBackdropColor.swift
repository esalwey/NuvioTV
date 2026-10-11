import CoreGraphics
import SwiftUI
import UIKit

/// The tint behind the detail page in "Dominant Color" mode: the colour that dominates the
/// backdrop, pulled toward the app's near-black background (upstream `dominantBackdropBlendColor`
/// blends 42%) and capped in brightness so white text stays legible on it.
///
/// The sampling is deliberately cheap — the cached, already downsampled backdrop is drawn into a
/// 32×18 bitmap and bucketed — and the maths lives in pure functions over an RGBA byte buffer so it
/// can be tested without an image.
nonisolated enum DominantBackdropColor {
    nonisolated struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    /// The app background (`Theme.Palette.background`, #0D0D0D) as components.
    static let background = RGB(r: 13.0 / 255.0, g: 13.0 / 255.0, b: 13.0 / 255.0)
    /// How far the tint travels from the background toward the dominant colour.
    static let blendFraction = 0.42
    /// Brightest the tint may be; a bright poster must not turn the page into a light surface.
    static let maxLuminance = 0.30

    private static let sampleWidth = 32
    private static let sampleHeight = 18

    /// The page tint for the backdrop at `url`, or nil when the image cannot be loaded or has no
    /// usable colour. Reads the shared artwork cache first, so a backdrop the page already shows
    /// costs no extra download.
    @MainActor
    static func tint(for url: URL) async -> Color? {
        let image: UIImage?
        if let cached = ArtworkStore.cached(url) {
            image = cached
        } else {
            image = try? await ArtworkStore.fetch(url)
        }
        // A 32x18 redraw of the already downsampled backdrop: a few milliseconds, no need to hop.
        guard let cgImage = image?.cgImage, let pixels = rgbaPixels(of: cgImage) else { return nil }
        return tint(fromRGBA: pixels)?.color
    }

    /// Dominant colour of an RGBA8 buffer, blended into the background and capped.
    nonisolated static func tint(fromRGBA pixels: [UInt8]) -> RGB? {
        guard let dominant = dominantColor(fromRGBA: pixels) else { return nil }
        return limited(blend(background, toward: dominant, fraction: blendFraction))
    }

    /// The colour that carries the most weight. Pixels are bucketed to 4 bits per channel; a pixel
    /// weighs more the more saturated it is, and near-black / near-white pixels barely count (a
    /// letterbox bar or a blown-out sky is not the picture's colour). Returns the mean of the
    /// winning bucket, or nil for an empty or fully transparent buffer.
    nonisolated static func dominantColor(fromRGBA pixels: [UInt8]) -> RGB? {
        guard pixels.count >= 4 else { return nil }
        nonisolated struct Bucket { var weight = 0.0; var r = 0.0; var g = 0.0; var b = 0.0; var count = 0.0 }
        var buckets: [Int: Bucket] = [:]
        var index = 0
        while index + 3 < pixels.count {
            let alpha = Double(pixels[index + 3]) / 255.0
            if alpha > 0.5 {
                let r = Double(pixels[index]) / 255.0
                let g = Double(pixels[index + 1]) / 255.0
                let b = Double(pixels[index + 2]) / 255.0
                let high = max(r, g, b)
                let low = min(r, g, b)
                let saturation = high == 0 ? 0 : (high - low) / high
                let brightnessWeight: Double = high < 0.08 || low > 0.92 ? 0.05 : 1
                let weight = (0.15 + saturation) * brightnessWeight
                let key = (Int(pixels[index]) >> 4) << 8 | (Int(pixels[index + 1]) >> 4) << 4 | (Int(pixels[index + 2]) >> 4)
                var bucket = buckets[key] ?? Bucket()
                bucket.weight += weight
                bucket.r += r
                bucket.g += g
                bucket.b += b
                bucket.count += 1
                buckets[key] = bucket
            }
            index += 4
        }
        guard let best = buckets.values.max(by: { $0.weight < $1.weight }), best.count > 0 else { return nil }
        return RGB(r: best.r / best.count, g: best.g / best.count, b: best.b / best.count)
    }

    nonisolated static func blend(_ from: RGB, toward target: RGB, fraction: Double) -> RGB {
        let f = min(max(fraction, 0), 1)
        return RGB(
            r: from.r + (target.r - from.r) * f,
            g: from.g + (target.g - from.g) * f,
            b: from.b + (target.b - from.b) * f
        )
    }

    /// Scales the colour down (keeping its hue) when it is brighter than `maxLuminance`.
    nonisolated static func limited(_ color: RGB) -> RGB {
        let luminance = color.luminance
        guard luminance > maxLuminance, luminance > 0 else { return color }
        let scale = maxLuminance / luminance
        return RGB(r: color.r * scale, g: color.g * scale, b: color.b * scale)
    }

    /// Draws `image` into a small premultiplied RGBA8 bitmap.
    private nonisolated static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = sampleWidth
        let height = sampleHeight
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }
}
