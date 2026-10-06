import SwiftUI
import SharedCore
import ImageIO

/// 10-ft renditions of the shared `StreamBadge` model, mirroring mobile's `StreamBadgeChip.kt`:
///
/// - Badges carrying an `imageURL` (the community "badge pack" visuals for quality / HDR /
///   audio channels etc.) render as image chips. `tagStyle == "filled"` paints `tagColor`
///   behind the image; a non-empty `borderColor` draws a thin outline. Mobile's 20pt chip is
///   scaled ~2x for the living-room viewing distance.
/// - Badges without an image fall back to a text chip in the badge's own colors (today's
///   behavior, kept so text-only packs still render).
/// - `StreamFileSizeChip` is the "2.3 GB" companion chip (mobile `StreamFileSizeBadge`).
enum StreamBadgeMetrics {
    /// Text chips (`StreamFileSizeChip`, `BadgeOverflowChip`) use it as a MINIMUM (gap 7, tvOS 27
    /// Larger Text): at default sizes every chip is exactly this tall, and at accessibility sizes a
    /// text chip grows with its Caption text instead of clipping it. Image chips keep it fixed.
    static let containerHeight: CGFloat = 40
    static let imageHeight: CGFloat = 30
    static let minImageWidth: CGFloat = 60
    static let maxImageWidth: CGFloat = 180
    static let cornerRadius: CGFloat = 8
}

struct StreamBadgeChipView: View {
    let badge: StreamBadge

    // BUG-28: `.settingsRow`-styled rows force `.environment(\.colorScheme, .light)` while
    // focused (see FlatControlStyles.swift), which flips SEMANTIC colors (`Theme.Palette
    // .textPrimary`/`.textSecondary`) but leaves FIXED pack-supplied hex colors untouched —
    // producing white-on-white when a pack's `textColor`/`tagColor` happen to both be light.
    // This environment value propagates into button labels (proven by `RowAccentTint` in
    // FlatControlStyles.swift), so reading it here lets the chip pick focus-safe fixed colors
    // instead of trusting the pack.
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        if badge.imageURL.isEmpty {
            textChip
        } else {
            imageChip
        }
    }

    private var imageChip: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius)
        let filled = badge.tagStyle.caseInsensitiveCompare("filled") == .orderedSame
        // Non-filled badge images are authored to sit on a dark surface (transparent PNGs).
        // On the white focus platter they vanish, so recreate that dark context while focused.
        let background: Color? = filled
            ? Color(hexString: badge.tagColor)
            : (isFocused ? Theme.Palette.surfaceElevated : nil)
        let border = Color(hexString: badge.borderColor)
        // BUG-43 (beta.12): the fallback text sits on the background THIS chip actually draws —
        // the pack fill only when `filled`; otherwise the clear/dark row (empty hex routes the
        // decision through its dark semantic default). Computing against `tagColor` regardless
        // gave a non-filled badge with a light `tagColor` near-black fallback text on a dark
        // row — invisible in the opposite direction from the reported defect.
        let effectiveBgHex = filled ? badge.tagColor : ""
        let fallbackDecision = Self.effectiveTextChipColors(
            textColorHex: badge.textColor,
            tagColorHex: effectiveBgHex,
            isFocused: isFocused
        )
        let fallbackForeground = Self.resolvedForeground(
            fallbackDecision,
            textColorHex: badge.textColor,
            tagColorHex: effectiveBgHex
        )

        return BadgeImageView(url: badge.imageURL) {
            // Broken/unreachable image → readable text stand-in.
            Text(badge.name)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(fallbackForeground)
                .lineLimit(1)
        }
        .frame(height: StreamBadgeMetrics.imageHeight)
        .frame(minWidth: StreamBadgeMetrics.minImageWidth, maxWidth: StreamBadgeMetrics.maxImageWidth)
        .padding(.horizontal, 6)
        .frame(height: StreamBadgeMetrics.containerHeight)
        .background(background ?? .clear, in: shape)
        .overlay(shape.stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1))
        .clipShape(shape)
    }

    private var textChip: some View {
        let decision = Self.effectiveTextChipColors(
            textColorHex: badge.textColor,
            tagColorHex: badge.tagColor,
            isFocused: isFocused
        )
        let foreground = Self.resolvedForeground(decision, textColorHex: badge.textColor, tagColorHex: badge.tagColor)
        let background = Self.resolvedBackground(decision, tagColorHex: badge.tagColor)
        let border = decision.showBorder ? Color(hexString: badge.borderColor) : nil

        return Text(badge.name)
            .font(Theme.Font.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(background, in: Capsule())
            .overlay(
                Capsule().stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
            )
    }

    // MARK: - BUG-28 pure color decision logic

    /// Where a text chip's foreground should come from. Kept as a plain enum (no `Color`) so the
    /// decision is testable with simple `==` — see `StreamBadgeColorTests`.
    enum ChipFgSource: Equatable {
        /// `Theme.Palette.textPrimary` — semantic, tracks the row's colorScheme flip.
        case semantic
        /// The pack's own `textColor` hex.
        case pack
        /// Dark/light pick computed against the effective background (pack guard triggered).
        case computedOnBg
        /// Fixed light color used while the row's focus platter is showing.
        case focusedFixed
    }

    /// Where a text chip's background should come from.
    enum ChipBgSource: Equatable {
        /// `Theme.Palette.surfaceElevated` — the existing fixed-dark default.
        case semantic
        /// The pack's own `tagColor` hex.
        case pack
        /// Fixed translucent fill used while the row's focus platter is showing.
        case focusedFixed
    }

    struct ChipColorDecision: Equatable {
        var fg: ChipFgSource
        var bg: ChipBgSource
        /// Whether the pack's `borderColor` should still be drawn.
        var showBorder: Bool
    }

    /// Default effective background hex used for the fg/bg contrast guard when the pack supplies
    /// no (or an unparseable) `tagColor` — mirrors `Theme.Palette.surfaceElevated` (0x242424).
    private static let defaultBgHex = "242424"

    /// Approximate luminance of `Theme.Palette.textPrimary` (`Color.primary`) as it actually
    /// renders in this app: near-white, since the app pins a dark color scheme (see that
    /// property's doc comment). `Color.primary` has no hex to measure outside a live SwiftUI
    /// environment, so this mirrors the literal value `textPrimary` was hard-coded to before it
    /// became semantic (`0xF5F7F8`) — close enough for the contrast guard below, which only
    /// needs to know "this resolves light."
    private static let semanticFgApproxHex = "F5F7F8"

    /// Pure decision function for a text chip's colors — see BUG-28 and BUG-43.
    ///
    /// FOCUSED: ignore the pack entirely. The row's focus platter is near-white, so pack hexes
    /// (authored against the app's normal dark surfaces) are never trustworthy here — use fixed
    /// colors instead, with no pack border.
    ///
    /// UNFOCUSED, `textColor` present: keep the pack's colors. But if the pack's `textColor` and
    /// effective `tagColor` (or the semantic default when `tagColor` is missing) are both light or
    /// both dark — luminance difference under 0.3 — the pair is illegible (BUG-28's reported
    /// white-on-white case), so replace the foreground with a computed dark/light pick against
    /// that background.
    ///
    /// UNFOCUSED, `textColor` missing/unparseable (BUG-43): mobile never renders a text chip at
    /// all (`StreamBadgeChip.kt` only draws `imageURL`), so plenty of imported packs set `tagColor`
    /// alone and leave `textColor` blank — nothing on mobile ever needed it. Naively defaulting to
    /// the semantic foreground here ignores what it will actually sit on: `Theme.Palette
    /// .textPrimary` (`Color.primary`) resolves near-white in this app's pinned dark scheme, and
    /// pairing that with a LIGHT pack `tagColor` (a language badge's flag-style fill, say)
    /// produces a near-invisible near-white-on-light chip — the reported "badge appears in the
    /// light theme" while sibling badges (which supply both colors and go through the guard above)
    /// render dark correctly. So this path runs the identical luminance guard, using
    /// `semanticFgApproxHex` to stand in for the un-measurable `Color.primary`: a light effective
    /// background swaps in the same `.computedOnBg` dark-text pick the explicit-`textColor` path
    /// already uses; a dark/default background keeps today's `.semantic` behavior unchanged.
    static func effectiveTextChipColors(
        textColorHex: String,
        tagColorHex: String,
        isFocused: Bool
    ) -> ChipColorDecision {
        if isFocused {
            return ChipColorDecision(fg: .focusedFixed, bg: .focusedFixed, showBorder: false)
        }

        let packBgLum = Theme.Palette.luminance(fromHexString: tagColorHex)
        let bgSource: ChipBgSource = packBgLum != nil ? .pack : .semantic
        let effectiveBgLum = packBgLum ?? Theme.Palette.luminance(fromHexString: defaultBgHex)!

        guard let fgLum = Theme.Palette.luminance(fromHexString: textColorHex) else {
            let assumedSemanticFgLum = Theme.Palette.luminance(fromHexString: semanticFgApproxHex)!
            if abs(assumedSemanticFgLum - effectiveBgLum) < 0.3 {
                return ChipColorDecision(fg: .computedOnBg, bg: bgSource, showBorder: true)
            }
            return ChipColorDecision(fg: .semantic, bg: bgSource, showBorder: true)
        }

        if abs(fgLum - effectiveBgLum) < 0.3 {
            return ChipColorDecision(fg: .computedOnBg, bg: bgSource, showBorder: true)
        }
        return ChipColorDecision(fg: .pack, bg: bgSource, showBorder: true)
    }

    /// Maps a `ChipColorDecision.fg` to an actual `Color`. Split from `effectiveTextChipColors`
    /// so the pure decision stays `Color`-free while callers (text chip, image-chip fallback
    /// text) share this mapping.
    static func resolvedForeground(
        _ decision: ChipColorDecision,
        textColorHex: String,
        tagColorHex: String
    ) -> Color {
        switch decision.fg {
        case .semantic:
            return Theme.Palette.textPrimary
        case .pack:
            return Color(hexString: textColorHex) ?? Theme.Palette.textPrimary
        case .focusedFixed:
            return Theme.Palette.onFocusPlatter
        case .computedOnBg:
            let bgLum = Theme.Palette.luminance(fromHexString: tagColorHex)
                ?? Theme.Palette.luminance(fromHexString: defaultBgHex)!
            return bgLum > 0.5 ? Color(hex: 0x0D0D0D) : Theme.Palette.textPrimary
        }
    }

    /// Maps a `ChipColorDecision.bg` to an actual `Color`.
    static func resolvedBackground(_ decision: ChipColorDecision, tagColorHex: String) -> Color {
        switch decision.bg {
        case .pack:
            return Color(hexString: tagColorHex) ?? Theme.Palette.surfaceElevated
        case .semantic:
            return Theme.Palette.surfaceElevated
        case .focusedFixed:
            return Color.black.opacity(0.08)
        }
    }
}

/// Downsampled-at-decode badge artwork, replacing AsyncImage. AsyncImage decodes every chip's image
/// at FULL native resolution and each chip holds its own copy — community badge packs ship large
/// PNGs, and a picker with dozens of rows × 8 chips held hundreds of full-size bitmaps: the process
/// blew through the ~2 GB per-process jetsam limit on device (two JetsamEvent kills, 2026-07-16).
/// Badge packs reuse a small set of images across every row, so decode-once + downsample-to-chip-size
/// + cache collapses that to a few dozen thumbnails.
private struct BadgeImageView<Fallback: View>: View {
    let url: String
    @ViewBuilder let fallback: Fallback
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                fallback
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let loaded = await BadgeImageCache.shared.image(for: url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// Process-wide badge-art cache: one fetch + one downsampled decode per unique URL, concurrent
/// requests for the same URL coalesced onto one task. NSCache so the (already small) decoded
/// thumbnails still evict under memory pressure.
private actor BadgeImageCache {
    static let shared = BadgeImageCache()

    /// Longest decoded side in pixels: chip max width (180 pt) at the 4K UI scale (2x), rounded up.
    /// Keeps every thumbnail ≤ ~0.6 MB regardless of the source PNG's size.
    private static let maxPixelSize: CGFloat = 400

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func image(for url: String) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSString) { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let parsed = URL(string: url),
                  let (data, response) = try? await URLSession.shared.data(from: parsed),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return Self.downsample(data: data, maxPixel: Self.maxPixelSize)
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { cache.setObject(result, forKey: url as NSString) }
        return result
    }

    /// CGImageSource thumbnail decode: never materializes the full-resolution bitmap.
    private static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// "2.3 GB" / "740 MB" chip from `behaviorHints.videoSize` (mobile `StreamFileSizeBadge`).
struct StreamFileSizeChip: View {
    let bytes: Int64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius)
        Text(Self.label(for: bytes))
            .font(Theme.Font.caption.weight(.bold))
            // BUG-28: fixed (not semantic) foreground — this chip's background is a fixed dark
            // fill that does NOT flip with the row's focus colorScheme, so a semantic foreground
            // (which does flip) could end up dark-on-dark once focused. Fixed/fixed keeps the
            // pair legible in both states; the resulting light-on-dark chip reads fine sitting on
            // the white focus platter too.
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: StreamBadgeMetrics.containerHeight)
            .background(Theme.Palette.surfaceElevated, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    static func label(for bytes: Int64) -> String {
        let gib = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gib >= 1.0 {
            // Localized format so locales can rename units (French: "Go"/"Mo").
            return String(format: String(localized: "%.1f GB"), (gib * 10.0).rounded() / 10.0)
        }
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return String(format: String(localized: "%d MB"), Int(mib.rounded()))
    }
}

/// BUG-16: "+N" overflow indicator shown by `StreamPickerView.badgeRow`'s `ViewThatFits` ladder
/// when the row doesn't have room for every badge. Deliberately plain text in a muted capsule
/// (not a button) — it's a static count, not a focusable element — and shares
/// `StreamBadgeMetrics.containerHeight` with the other chips so swapping candidates in/out never
/// changes the badge row's height.
struct BadgeOverflowChip: View {
    let count: Int

    var body: some View {
        let shape = Capsule()
        Text("+\(count)")
            .font(Theme.Font.caption.weight(.semibold))
            // BUG-28: fixed (not semantic) foreground for the same reason as StreamFileSizeChip
            // above — this chip's background is fixed-dark and doesn't flip with focus.
            .foregroundStyle(Color.white.opacity(0.7))
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: StreamBadgeMetrics.containerHeight)
            .background(Theme.Palette.surfaceElevated.opacity(0.6), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
