import UIKit

/// BUG-59 (reveal-gate wave): measures letterbox/pillarbox bars baked into STATIC ARTWORK — the
/// landscape key art an inline trailer tile shows from the moment it expands until playback is
/// revealed (up to 15 s on a cold extraction). TMDB backdrops are sometimes trailer stills with
/// the trailer's own bars baked in, and with the video side now bar-proof (`TrailerLetterboxProbe`
/// + the reveal gate), the art is the only surface left that can put a black bar on a focus tile.
///
/// Shares `TrailerLetterboxProbe`'s thresholds (`blackLuma`, `maxBarFraction`, `minBarFraction`,
/// `maxZoom`) so "black bar" means one thing across the whole tile, but is deliberately STRICTER
/// in one way: a bar edge only counts if its opposite edge matches within `maxAsymmetry`. The
/// probe gets to average away content-dark frames across samples; a still image is one sample, and
/// genuinely dark art — a night sky above, a dark lawn below (the reporter's *Idaho Murders* frame,
/// which reads as "bars" but IS the picture) — must never be cropped. Real baked bars are
/// symmetric; dark content almost never is, and when it is, it still has to pass the ≤16-luma
/// true-black test on BOTH edges plus the not-black-through-the-middle test.
///
/// Scan cost: one downscaled draw (≤192 px wide, aspect preserved — the draw itself can never
/// manufacture bars) plus a sparse 32-point row/column walk — single-digit milliseconds, done once
/// per URL and memoized. Callers run it off the main actor (`CachedAsyncImage`'s `.task`).
///
/// Mirrored by `ArtworkLetterboxTests` in `NuvioTVUITests` (a UI-test bundle can't link app code —
/// see `StreamBadgeColorTests`' type doc for the precedent). Keep the two in sync by hand.
enum ArtworkLetterbox {
    /// Width of the scan bitmap. The height is derived from the image's own aspect, so the
    /// downscale can never introduce the bars it is looking for (the same trap
    /// `TrailerLetterboxProbe.bars(in:)` documents for `AVPlayerItemVideoOutput`).
    private static let scanWidth = 192
    /// Sample points per scanned row/column — same sparse grid as the probe's pixel scan.
    private static let samplesPerLine = 32
    /// Art-only guard (see the type doc): the top/bottom (or left/right) bar fractions must agree
    /// within this much of the frame for the pair to count as a baked bar at all.
    static let maxAsymmetry: Double = 0.02

    /// One measured zoom per artwork URL, process-lifetime. Values are tiny; 500 entries is a
    /// long browsing session.
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 500
        return cache
    }()

    /// Synchronous memoized lookup, safe from any thread (NSCache locks internally) — lets the
    /// view seed its first frame without an async hop when this URL was already measured.
    static func cachedZoom(forKey key: String) -> CGFloat? {
        cache.object(forKey: key as NSString).map { CGFloat(truncating: $0) }
    }

    /// The zoom that crops `image`'s baked bars (1.0 when it has none), memoized under `cacheKey`.
    /// Blocking for a few ms — call off the main actor.
    static func zoom(for image: UIImage, cacheKey: String) -> CGFloat {
        if let hit = cachedZoom(forKey: cacheKey) { return hit }
        let zoom = measuredZoom(of: image) ?? 1.0
        cache.setObject(NSNumber(value: Double(zoom)), forKey: cacheKey as NSString)
        return zoom
    }

    /// The measurement itself: nil (treated as 1.0 by `zoom(for:cacheKey:)`) whenever the image
    /// can't be read or shows nothing that passes every bar test.
    static func measuredZoom(of image: UIImage) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 32, sourceHeight > 32 else { return nil }

        // Downscale preserving the image's exact aspect (see `scanWidth`).
        let width = min(scanWidth, sourceWidth)
        let height = max(32, Int((Double(width) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }

        return zoomFromScan(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// The scan + decision, split from the bitmap draw so the mirror test exercises the exact
    /// logic against synthesized pixel arrays.
    static func zoomFromScan(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGFloat? {
        // RGBA (the context above), Rec.709 luma — same coefficients as the probe's BGRA scan.
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = y * bytesPerRow + x * 4
            return 0.2126 * Double(pixels[p]) + 0.7152 * Double(pixels[p + 1]) + 0.0722 * Double(pixels[p + 2])
        }
        func isBlackRow(_ y: Int) -> Bool {
            let step = max(1, width / samplesPerLine)
            var sum = 0.0
            var count = 0
            var x = step / 2
            while x < width { sum += luma(x, y); count += 1; x += step }
            return count > 0 && sum / Double(count) <= TrailerLetterboxProbe.blackLuma
        }
        func isBlackColumn(_ x: Int) -> Bool {
            let step = max(1, height / samplesPerLine)
            var sum = 0.0
            var count = 0
            var y = step / 2
            while y < height { sum += luma(x, y); count += 1; y += step }
            return count > 0 && sum / Double(count) <= TrailerLetterboxProbe.blackLuma
        }

        // Black through its own middle: a poster that is mostly black canvas, not a barred image.
        guard !isBlackRow(height / 2), !isBlackColumn(width / 2) else { return nil }

        let rowLimit = Int(Double(height) * TrailerLetterboxProbe.maxBarFraction)
        let columnLimit = Int(Double(width) * TrailerLetterboxProbe.maxBarFraction)
        var top = 0
        while top < rowLimit, isBlackRow(top) { top += 1 }
        var bottom = 0
        while bottom < rowLimit, isBlackRow(height - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < columnLimit, isBlackColumn(left) { left += 1 }
        var right = 0
        while right < columnLimit, isBlackColumn(width - 1 - right) { right += 1 }

        let topFraction = Double(top) / Double(height)
        let bottomFraction = Double(bottom) / Double(height)
        let leftFraction = Double(left) / Double(width)
        let rightFraction = Double(right) / Double(width)

        // A pair of edges counts only when BOTH clear the encoder-rounding floor AND they agree
        // (the symmetry guard this type exists for — see the type doc).
        func pairedBar(_ a: Double, _ b: Double) -> Double {
            guard a >= TrailerLetterboxProbe.minBarFraction,
                  b >= TrailerLetterboxProbe.minBarFraction,
                  abs(a - b) <= maxAsymmetry else { return 0 }
            return a + b
        }
        let verticalBars = pairedBar(topFraction, bottomFraction)
        let horizontalBars = pairedBar(leftFraction, rightFraction)
        guard verticalBars > 0 || horizontalBars > 0 else { return nil }

        let verticalContent = 1 - verticalBars
        let horizontalContent = 1 - horizontalBars
        guard verticalContent > 0, horizontalContent > 0 else { return nil }
        let measured = max(1 / verticalContent, 1 / horizontalContent)
        guard measured > 1 else { return nil }
        // No parity floor here (that is a video-surface upstream-parity concern): the art zooms by
        // exactly what its bars demand, clamped by the same physical ceiling as the probe.
        return min(CGFloat(measured), TrailerLetterboxProbe.maxZoom)
    }
}
