import XCTest

/// Pure-logic coverage for BUG-59's static-art letterbox scan — see
/// `ArtworkLetterbox.zoomFromScan(pixels:width:height:bytesPerRow:)` in
/// `NuvioTV/DesignSystem/ArtworkLetterbox.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` — these are plain, fast asserts against a
/// decision function, same shape as `StreamBadgeColorTests`.
///
/// Why this file mirrors the production logic instead of importing it: `NuvioTVUITests` is a
/// genuine UI-testing bundle with no `BUNDLE_LOADER`/`TEST_HOST`, so `@testable import NuvioTV`
/// would type-check but fail at link time — see `StreamBadgeColorTests`' type doc for the full
/// explanation and the standing instruction to move these into a real hosted unit-test target if
/// one ever exists. Keep this in sync BY HAND with `ArtworkLetterbox.zoomFromScan` (and the
/// `TrailerLetterboxProbe` constants it reads: `blackLuma`, `maxBarFraction`, `minBarFraction`,
/// `maxZoom`) whenever that logic changes.
///
/// What the cases pin down, in the order the tester's evidence produced them:
///   * symmetric baked letterbox bars → the exact crop, not the 1.08 parity floor (UX-9);
///   * genuinely dark art — dark top edge only, or dark through the middle — is NEVER cropped
///     (the *Idaho Murders* frame from the p4afwfo video read: dark night sky above, dark lawn
///     below, and the art fills the tile);
///   * encoder-rounding hairlines below `minBarFraction` are ignored;
///   * a measurement past the physical ceiling clamps to `maxZoom` instead of over-cropping.
final class ArtworkLetterboxTests: XCTestCase {

    // MARK: - Mirror of the production constants

    private let blackLuma: Double = 16          // TrailerLetterboxProbe.blackLuma
    private let maxBarFraction: Double = 0.25   // TrailerLetterboxProbe.maxBarFraction
    private let minBarFraction: Double = 0.01   // TrailerLetterboxProbe.minBarFraction
    private let maxZoom: CGFloat = 1.45         // TrailerLetterboxProbe.maxZoom
    private let maxAsymmetry: Double = 0.02     // ArtworkLetterbox.maxAsymmetry
    private let samplesPerLine = 32             // ArtworkLetterbox.samplesPerLine

    // MARK: - Mirror of ArtworkLetterbox.zoomFromScan

    private func zoomFromScan(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGFloat? {
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
            return count > 0 && sum / Double(count) <= blackLuma
        }
        func isBlackColumn(_ x: Int) -> Bool {
            let step = max(1, height / samplesPerLine)
            var sum = 0.0
            var count = 0
            var y = step / 2
            while y < height { sum += luma(x, y); count += 1; y += step }
            return count > 0 && sum / Double(count) <= blackLuma
        }

        guard !isBlackRow(height / 2), !isBlackColumn(width / 2) else { return nil }

        let rowLimit = Int(Double(height) * maxBarFraction)
        let columnLimit = Int(Double(width) * maxBarFraction)
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

        func pairedBar(_ a: Double, _ b: Double) -> Double {
            guard a >= minBarFraction, b >= minBarFraction, abs(a - b) <= maxAsymmetry else { return 0 }
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
        return min(CGFloat(measured), maxZoom)
    }

    // MARK: - Pixel synthesis

    /// RGBA buffer: `contentLuma` gray everywhere, `barLuma` gray in the requested edge bands.
    private func makePixels(
        width: Int, height: Int,
        barTop: Int = 0, barBottom: Int = 0, barLeft: Int = 0, barRight: Int = 0,
        contentLuma: UInt8 = 128, barLuma: UInt8 = 0
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let isBar = y < barTop || y >= height - barBottom || x < barLeft || x >= width - barRight
                let value = isBar ? barLuma : contentLuma
                let p = (y * width + x) * 4
                pixels[p] = value       // R
                pixels[p + 1] = value   // G
                pixels[p + 2] = value   // B
                pixels[p + 3] = 255     // A
            }
        }
        return pixels
    }

    private func scan(_ pixels: [UInt8], width: Int, height: Int) -> CGFloat? {
        zoomFromScan(pixels: pixels, width: width, height: height, bytesPerRow: width * 4)
    }

    // MARK: - Cases

    /// A 2.39:1 picture letterboxed inside 16:9 (the UX-9 filing case): 13-row bars on a 108-row
    /// frame → zoom 1/(1 − 26/108) ≈ 1.317.
    func testSymmetricLetterboxMeasuresItsExactCrop() {
        let pixels = makePixels(width: 192, height: 108, barTop: 13, barBottom: 13)
        let zoom = scan(pixels, width: 192, height: 108)
        XCTAssertNotNil(zoom)
        XCTAssertEqual(Double(zoom ?? 0), 1.0 / (1.0 - 26.0 / 108.0), accuracy: 0.001)
    }

    func testSymmetricPillarboxMeasuresItsExactCrop() {
        let pixels = makePixels(width: 192, height: 108, barLeft: 20, barRight: 20)
        let zoom = scan(pixels, width: 192, height: 108)
        XCTAssertNotNil(zoom)
        XCTAssertEqual(Double(zoom ?? 0), 1.0 / (1.0 - 40.0 / 192.0), accuracy: 0.001)
    }

    /// The Idaho Murders shape: a dark band on ONE edge is content (night sky), never a bar.
    func testDarkTopEdgeAloneIsNeverCropped() {
        let pixels = makePixels(width: 192, height: 108, barTop: 13)
        XCTAssertNil(scan(pixels, width: 192, height: 108))
    }

    /// Both edges dark but visibly unequal (13 vs 6 rows ≈ 0.12 vs 0.056 of the frame — well past
    /// `maxAsymmetry`): dark content coincidence, not a baked bar.
    func testAsymmetricDarkEdgesAreNeverCropped() {
        let pixels = makePixels(width: 192, height: 108, barTop: 13, barBottom: 6)
        XCTAssertNil(scan(pixels, width: 192, height: 108))
    }

    /// Black through its own middle → a mostly-black poster / fade frame, unusable.
    func testBlackCenterRejectsTheWholeImage() {
        let pixels = makePixels(width: 192, height: 108, barTop: 13, barBottom: 13, contentLuma: 8)
        XCTAssertNil(scan(pixels, width: 192, height: 108))
    }

    func testBarlessImageIsUntouched() {
        let pixels = makePixels(width: 192, height: 108)
        XCTAssertNil(scan(pixels, width: 192, height: 108))
    }

    /// One-row hairlines (1/108 ≈ 0.009 < `minBarFraction`) are encoder rounding.
    func testHairlineBarsBelowMinimumAreIgnored() {
        let pixels = makePixels(width: 192, height: 108, barTop: 1, barBottom: 1)
        XCTAssertNil(scan(pixels, width: 192, height: 108))
    }

    /// Bars past `maxBarFraction` per edge: the walk stops at the 25 % limit on both sides
    /// (symmetric by construction), the implied 2.0× measurement clamps to the physical ceiling.
    func testOversizedBarsClampToMaxZoom() {
        let pixels = makePixels(width: 192, height: 108, barTop: 40, barBottom: 40)
        let zoom = scan(pixels, width: 192, height: 108)
        XCTAssertEqual(zoom, maxZoom)
    }

    /// The luma threshold is a TRUE-black test: a bar-shaped band at luma 24 (above
    /// `blackLuma` = 16 — e.g. a dark gradient) is content.
    func testDimButNotBlackBandsAreContent() {
        let pixels = makePixels(width: 192, height: 108, barTop: 13, barBottom: 13, barLuma: 24)
        XCTAssertNil(scan(pixels, width: 192, height: 108))
    }

    /// …while a band at exactly `blackLuma` still reads as a bar (the ≤ boundary).
    func testBarAtThresholdLumaStillCounts() {
        let pixels = makePixels(width: 192, height: 108, barTop: 13, barBottom: 13, barLuma: 16)
        XCTAssertNotNil(scan(pixels, width: 192, height: 108))
    }
}
