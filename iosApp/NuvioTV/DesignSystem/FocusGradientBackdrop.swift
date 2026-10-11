import Combine
import CoreGraphics
import SharedCore
import SwiftUI
import UIKit

/// Settings > Home Screen > Focused Item Gradient. Device-local and off by default: the Home
/// background is a flat dark unless the viewer asks for the focused title's colors to tint it.
enum FocusGradientSetting {
    static let defaultsKey = "classic_focus_gradient_enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// The artwork a gradient is derived from: the focused title's image, and a seed (its id) to fall
/// back on when the image can not be read, so the same title always gets the same color.
struct FocusGradientArtwork: Equatable {
    let imageURL: String?
    let seed: String

    var cacheKey: String { "\(imageURL ?? "")|\(seed)" }

    init(imageURL: String?, seed: String) {
        let trimmed = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageURL = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.seed = seed
    }

    /// The Home hero's backdrop chain, then the poster.
    init(_ item: MetaPreview) {
        self.init(imageURL: heroBackdropURL(for: item), seed: item.id)
    }
}

/// A color as three 0...1 channels. A plain value so the color rules are testable without SwiftUI.
nonisolated struct FocusGradientRGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    static let white = FocusGradientRGB(r: 1, g: 1, b: 1)
    static let black = FocusGradientRGB(r: 0, g: 0, b: 0)

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Picks one calm color for a piece of artwork. The rules are the Android TV Classic home's: weight
/// each sampled pixel by how saturated and bright it is so the dominant hue wins over grey
/// shadows, then keep the result away from near-black and near-white so the wash stays visible but
/// never harsh.
nonisolated enum FocusGradientColor {
    /// Samples taken per side; the image is drawn into a square this size first.
    static let sampleSide = 16

    /// Relative luminance (0...1) after the sRGB transfer curve is removed.
    static func luminance(_ c: FocusGradientRGB) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func mix(_ a: FocusGradientRGB, _ b: FocusGradientRGB, _ t: Double) -> FocusGradientRGB {
        FocusGradientRGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    /// Lifts a very dark color and tames a very light one.
    static func stabilize(_ c: FocusGradientRGB) -> FocusGradientRGB {
        let l = luminance(c)
        if l < 0.16 { return mix(c, .white, 0.34) }
        if l > 0.72 { return mix(c, .black, 0.32) }
        return c
    }

    /// The prominent color of a premultiplied RGBA8 bitmap, or nil when it has nothing to weigh
    /// (fully transparent or near black throughout).
    static func prominent(rgba: [UInt8], width: Int, height: Int) -> FocusGradientRGB? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in 0..<(width * height) {
            let offset = index * 4
            let alpha = Double(rgba[offset + 3]) / 255
            if alpha < 0.35 { continue }
            // Undo the premultiplication so a translucent edge keeps its true color.
            let r = min(Double(rgba[offset]) / 255 / alpha, 1)
            let g = min(Double(rgba[offset + 1]) / 255 / alpha, 1)
            let b = min(Double(rgba[offset + 2]) / 255 / alpha, 1)
            let top = max(r, g, b)
            let bottom = min(r, g, b)
            if top < 0.08 { continue }
            let saturation = top == 0 ? 0 : (top - bottom) / top
            let weight = alpha * (0.35 + saturation * 1.65) * (0.5 + top)
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return nil }
        return stabilize(FocusGradientRGB(r: red / total, g: green / total, b: blue / total))
    }

    /// The color for an image that could not be read: a hue picked by the seed, blended with the
    /// neutral base so it stays quiet. Same seed, same color, on every launch.
    static func seedColor(seed: String, base: FocusGradientRGB) -> FocusGradientRGB {
        guard !seed.isEmpty else { return stabilize(base) }
        let hue = Double(stableHash(seed) % 360)
        return stabilize(mix(base, hsv(hue: hue, saturation: 0.58, value: 0.82), 0.58))
    }

    /// Java's `String.hashCode` over UTF-16 units, as an unsigned 32-bit value: the same hue the
    /// Android TV app picks for a seed.
    static func stableHash(_ text: String) -> UInt32 {
        var hash: Int32 = 0
        for unit in text.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        return UInt32(bitPattern: hash)
    }

    static func hsv(hue: Double, saturation: Double, value: Double) -> FocusGradientRGB {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let sector = Int(h)
        let fraction = h - Double(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return FocusGradientRGB(r: value, g: t, b: p)
        case 1: return FocusGradientRGB(r: q, g: value, b: p)
        case 2: return FocusGradientRGB(r: p, g: value, b: t)
        case 3: return FocusGradientRGB(r: p, g: q, b: value)
        case 4: return FocusGradientRGB(r: t, g: p, b: value)
        default: return FocusGradientRGB(r: value, g: p, b: q)
        }
    }

    /// Draws `image` into a small square and reads the prominent color from it.
    static func sample(cgImage: CGImage) -> FocusGradientRGB? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return prominent(rgba: pixels, width: side, height: side)
    }
}

/// A small least-recently-used cache of resolved colors (the Android TV size: 256).
nonisolated struct FocusGradientColorCache: Equatable, Sendable {
    static let capacity = 256

    private var order: [String] = []
    private var storage: [String: FocusGradientRGB] = [:]

    var count: Int { storage.count }

    mutating func value(for key: String) -> FocusGradientRGB? {
        guard let hit = storage[key] else { return nil }
        touch(key)
        return hit
    }

    mutating func set(_ value: FocusGradientRGB, for key: String) {
        storage[key] = value
        touch(key)
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            storage[oldest] = nil
        }
    }

    private mutating func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// Resolves the focused artwork to a color, off the main thread, a beat after focus settles.
@MainActor
final class FocusGradientModel: ObservableObject {
    struct Layer: Equatable, Identifiable {
        let id: Int
        let color: FocusGradientRGB
    }

    /// The wash on screen, or nil for none. A new `id` per color, so the view cross-fades.
    @Published private(set) var layer: Layer?

    /// Wait for focus to settle before reading artwork, so a swipe across a row does not decode a
    /// color for every card it passes.
    static let debounce: Duration = .milliseconds(140)
    /// One retry for an image that was still downloading.
    static let retryDelay: Duration = .milliseconds(360)

    private var cache = FocusGradientColorCache()
    private var task: Task<Void, Never>?
    private var serial = 0
    private let base: FocusGradientRGB

    init(base: FocusGradientRGB = FocusGradientRGB(r: 0.14, g: 0.14, b: 0.14)) {
        self.base = base
    }

    func update(_ artwork: FocusGradientArtwork?) {
        task?.cancel()
        guard let artwork else {
            apply(nil)
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let color = await self?.resolve(artwork), !Task.isCancelled else { return }
            self?.apply(color)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ color: FocusGradientRGB?) {
        guard layer?.color != color else { return }
        guard let color else {
            layer = nil
            return
        }
        serial += 1
        layer = Layer(id: serial, color: color)
    }

    private func resolve(_ artwork: FocusGradientArtwork) async -> FocusGradientRGB {
        let key = artwork.cacheKey
        if let hit = cache.value(for: key) { return hit }
        let fallback = FocusGradientColor.seedColor(seed: artwork.seed, base: base)
        guard let string = artwork.imageURL, let url = URL(string: string) else {
            cache.set(fallback, for: key)
            return fallback
        }
        var image = try? await ArtworkStore.fetch(url)
        if image == nil {
            try? await Task.sleep(for: Self.retryDelay)
            if Task.isCancelled { return fallback }
            image = try? await ArtworkStore.fetch(url)
        }
        // Not cached on a failed read, so the next focus on this title tries the image again.
        guard let cgImage = image?.cgImage else { return fallback }
        let sampled = await Task.detached(priority: .utility) {
            FocusGradientColor.sample(cgImage: cgImage)
        }.value
        let color = sampled ?? fallback
        cache.set(color, for: key)
        return color
    }
}

/// The artwork-derived wash behind Home and collection folders: a diagonal gradient from nothing on
/// the left to the focused title's color at the bottom right, over the flat dark background. It
/// paints nothing while `artwork` is nil, and cross-fades between colors as focus moves.
struct FocusGradientBackdrop: View {
    let artwork: FocusGradientArtwork?

    @StateObject private var model = FocusGradientModel()

    var body: some View {
        ZStack {
            if let layer = model.layer {
                FocusGradientWash(color: layer.color.color)
                    .id(layer.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.layer)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Decoration only; the focused title is already announced by its card.
        .accessibilityHidden(true)
        .onAppear { model.update(artwork) }
        .onChange(of: artwork) { _, next in model.update(next) }
        .onDisappear { model.stop() }
    }
}

/// The gradient itself. Stops follow the Android TV drawing: clear for the first 42 percent along
/// the diagonal, then 16, 30 and 44 percent of the color. The leftmost 29 percent of the screen is
/// left untouched, where the first column of cards sits.
private struct FocusGradientWash: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: color.opacity(0), location: 0),
                            .init(color: color.opacity(0), location: 0.42),
                            .init(color: color.opacity(0.16), location: 0.66),
                            .init(color: color.opacity(0.30), location: 0.84),
                            .init(color: color.opacity(0.44), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0.12, y: 0),
                        endPoint: UnitPoint(x: 1, y: 0.82)
                    )
                )
                .mask(alignment: .trailing) {
                    Rectangle().frame(width: proxy.size.width * 0.71)
                }
        }
    }
}
