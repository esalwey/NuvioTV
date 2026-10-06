import SwiftUI
import UIKit

/// Central design tokens for the tvOS app.
///
/// Mirrors the mobile app's default **Crimson** dark palette (see composeApp `ThemeColors.kt` +
/// `Theme.kt`) so the two clients read as one product. Use these everywhere instead of hardcoding
/// fonts, colors, paddings, and sizes per-screen.
enum Theme {

    // MARK: - Color

    enum Palette {
        /// App background (deepest layer).
        static let background = Color(hex: 0x0D0D0D)
        /// Elevated surface (cards, sheets, shimmer base).
        static let surface = Color(hex: 0x1A1A1A)
        /// Higher-elevation surface (chips, controls).
        static let surfaceElevated = Color(hex: 0x242424)
        /// Brand accent — mutable so the user's theme choice applies (see `applyTheme`). Reads are
        /// re-evaluated when ContentView re-identifies the tree on a theme change, so plain static
        /// access everywhere keeps working. `nonisolated(unsafe)`: only mutated on the main actor.
        nonisolated(unsafe) static var accent = Color(hex: 0xE53935)
        /// Focus ring / highlight (brighter accent). Mutable — follows the theme with `accent`.
        nonisolated(unsafe) static var accentFocus = Color(hex: 0xFF5252)
        /// Text/icon color for content drawn ON an `accent`/`accentFocus` fill (selected chips,
        /// filled badges, etc). Mutable — recomputed by `applyTheme` from the accent's luminance so
        /// the near-white White theme gets dark text/icons while every other (darker/saturated)
        /// theme keeps the existing light `textPrimary`. Only use this where text sits on a solid
        /// accent fill — accent borders/rings don't need it.
        nonisolated(unsafe) static var accentText = Color(hex: 0x0D0D0D)
        /// Raw hex backing `accentFocus`, set alongside it in `applyTheme`. FEAT-14 needs the
        /// hex (not just the `Color`) to run it through `focusRingHex(accentFocusHex:)` for the
        /// opt-in accent focus ring on artwork cards. Defaults to CRIMSON's focus hex, matching
        /// `accentFocus`'s own default above.
        nonisolated(unsafe) static var accentFocusHex = "FF5252"

        /// Retints the palette for a shared `AppTheme` (by enum name). Accents mirror mobile's
        /// `ThemeColors.kt` (`AppTheme.nativeAccentHex`), with a brighter focus variant per theme.
        static func applyTheme(named name: String) {
            let accentHex: UInt32
            let focusHex: UInt32
            switch name {
            case "OCEAN":   accentHex = 0x1E88E5; focusHex = 0x42A5F5
            case "VIOLET":  accentHex = 0x8E24AA; focusHex = 0xAB47BC
            case "EMERALD": accentHex = 0x43A047; focusHex = 0x66BB6A
            case "AMBER":   accentHex = 0xFB8C00; focusHex = 0xFFA726
            case "ROSE":    accentHex = 0xD81B60; focusHex = 0xEC407A
            case "WHITE":   accentHex = 0xF5F5F5; focusHex = 0xFFFFFF
            default:        accentHex = 0xE53935; focusHex = 0xFF5252 // CRIMSON
            }
            accent = Color(hex: accentHex)
            accentFocus = Color(hex: focusHex)
            accentFocusHex = String(format: "%06X", focusHex)
            accentText = onColor(forFillHex: accentHex)
        }

        /// Picks a legible text/icon color for a solid fill, by simple relative-luminance
        /// threshold: dark text for light fills (e.g. the White theme's near-white accent), the
        /// app's light `textPrimary` otherwise. Not full WCAG contrast math — just enough to keep
        /// text readable against any of the app's accent colors. Threshold sits well above the
        /// brightest saturated accent (Amber, ~0.6) so every existing theme keeps its current
        /// light text; only near-white fills (the White theme, ~0.96) cross it.
        static func onColor(forFillHex hex: UInt32) -> Color {
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance > 0.75 ? Color(hex: 0x0D0D0D) : textPrimary
        }

        /// Relative luminance (0–1, Rec. 709 weights) of a `#RGB`/`#RRGGBB`/`#RRGGBBAA` hex
        /// string, using the same parsing rules as `Color(hexString:)`. Returns nil for
        /// empty/malformed input so callers can fall back. Deliberately String-in/Double-out (no
        /// `Color` involved) so pure color-decision logic elsewhere (e.g.
        /// `StreamBadgeChipView.effectiveTextChipColors`, BUG-28) stays unit-testable without
        /// relying on `Color` equality.
        static func luminance(fromHexString hexString: String) -> Double? {
            var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 3 || s.count == 6 || s.count == 8,
                  let value = UInt64(s, radix: 16) else { return nil }

            let r, g, b: Double
            switch s.count {
            case 3:
                r = Double((value >> 8) & 0xF) / 15.0
                g = Double((value >> 4) & 0xF) / 15.0
                b = Double(value & 0xF) / 15.0
            case 6:
                r = Double((value >> 16) & 0xFF) / 255.0
                g = Double((value >> 8) & 0xFF) / 255.0
                b = Double(value & 0xFF) / 255.0
            default: // 8: AARRGGBB — Android/Compose convention, matching `Color(hexString:)`.
                // BUG-43: reading these bytes as RRGGBBAA fed the contrast guards a luminance
                // computed from the WRONG channels (alpha in, blue out) for every 8-digit pack
                // color — see the parity note in `Color(hexString:)`.
                r = Double((value >> 16) & 0xFF) / 255.0
                g = Double((value >> 8) & 0xFF) / 255.0
                b = Double(value & 0xFF) / 255.0
            }
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        /// FEAT-14: decides the accent focus ring's actual draw color, given the current theme's
        /// `accentFocus` hex. Originally mirrored BUG-28's `onColor(forFillHex:)` — a luminance
        /// threshold routed near-white hexes to a fixed dark fallback ("1A1A1A") so they wouldn't
        /// vanish against the system focus platter/lift brightness. BUG-40 (beta feedback): that
        /// reasoning doesn't hold for the ring, this function's only caller (`focusRingColor` in
        /// `PosterCard.swift`). Ring mode never puts artwork under the system platter — it swaps
        /// out `.hoverEffect(.highlight)` for a manual `.scaleEffect` (`CardFocusTreatment`, also
        /// in `PosterCard.swift`) specifically so the ring is the only focus indicator drawn, and
        /// it carries its own stroke over the artwork rather than a fill needing on-light-fill
        /// text contrast. So a user who picks the White theme and turns the ring on should see a
        /// white ring, not a grey one. No dark fallback: the ring always draws in the theme's own
        /// focus color.
        static func focusRingHex(accentFocusHex: String) -> String {
            accentFocusHex
        }

        /// Primary text — semantic, resolves against the pinned dark scheme (near-white) and
        /// tracks Increase Contrast automatically. (Was hard-coded 0xF5F7F8.)
        static let textPrimary = Color.primary
        /// Secondary / muted text — semantic. (Was hard-coded 0x969CA3.)
        static let textSecondary = Color.secondary
        /// Hairline / outline color.
        static let outline = Color(hex: 0x252A2A)
        /// Rating star.
        static let star = Color(hex: 0xFFC857)
        /// Advisory warnings (the stream picker's debrid-session banner, AES-11) — the star's amber,
        /// so the app keeps a single warm signal colour instead of a raw `.yellow`.
        static let warning = Color(hex: 0xFFC857)
        /// Resting fill of a focusable row drawn over artwork or a panel material (the stream
        /// picker's rows, AES-3): the chips' translucent white, a step quieter, so a list reads as
        /// separate cards without competing with the white focus platter.
        static let restingRowFill = Color.white.opacity(0.07)
        /// Progress bar fill (continue watching). AES-5: derived from `accentFocus`, never a fixed
        /// hex — it was pinned to CRIMSON's `FF5252` when theme switching was added, so Ocean,
        /// Emerald, Violet… still drew red bars. Computed, so it follows `applyTheme` through the same
        /// ContentView `.id` remount every accent read relies on; CRIMSON renders exactly as before.
        static var progress: Color { accentFocus }
        /// Label color on the system focus platter (near-white). Public mirror of
        /// `FlatControlStyles.FocusLook.onPlatter` — that type stays private to
        /// FlatControlStyles.swift, so call sites elsewhere (e.g. `StreamBadges.swift`, BUG-28)
        /// that need the same "on the white platter" color use this instead of duplicating it.
        static let onFocusPlatter = Color.black.opacity(0.85)
    }

    // MARK: - Surfaces (materials / Liquid Glass)

    /// System materials for floating chrome. Prefer these over the opaque `Palette.surface*`
    /// hexes for anything that OVERLAYS content (modals, pickers, pause cards, chrome over
    /// artwork) — HIG: glass/materials belong to the floating layer, opaque surfaces to the
    /// content layer. `Palette.surface*` remains correct for in-content fills (card shimmer
    /// bases, list row fills) where translucency would just add noise.
    enum Surface {
        /// Large panels presented over content (stream picker, track picker, profile sheets).
        static let panel: Material = .thick
        /// Standard floating overlays (pause info card, confirmation panels).
        static let overlay: Material = .regular
        /// Light-touch chrome riding on media (badges over artwork, transport bar).
        static let chrome: Material = .thin
        /// Opaque stand-in for any custom Liquid Glass surface when Reduce Transparency is on
        /// (design spec §10). System controls swap their own glass; only app-drawn glass needs it.
        static let opaqueFallback = Color(white: 0.12)
    }

    // MARK: - Grid (HIG Layout › tvOS)

    /// The tvOS grid from the HIG: a 1760pt readable width (1920 minus the 80pt side safe areas),
    /// 40pt between columns, and at least 100pt between rows. `itemWidth(columns:)` reproduces the
    /// HIG's unfocused widths: 7 → 217, 5 → 320, 4 → 410, 3 → 560.
    enum Grid {
        static let readableWidth: CGFloat = 1760
        /// Horizontal gap between items in a shelf or grid.
        static let spacing: CGFloat = 40
        /// Vertical gap between grid rows. With the caption slot (~44pt) below each poster this
        /// keeps the artwork-to-artwork distance above the HIG's 100pt minimum.
        static let rowSpacing: CGFloat = 60
        /// Portrait poster columns: 7 by default, 5 at accessibility text sizes (spec §3.1).
        static let posterColumns = 7
        static let posterColumnsAccessibility = 5
        /// 16:9 card columns: 4 by default, 3 at accessibility text sizes.
        static let landscapeColumns = 4
        static let landscapeColumnsAccessibility = 3

        /// Unfocused item width for `columns` items across the readable width.
        static func itemWidth(columns: Int) -> CGFloat {
            guard columns > 0 else { return readableWidth }
            return ((readableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)).rounded(.down)
        }
    }

    // MARK: - Typography (semantic tvOS text styles)
    //
    // Every token maps to a `Font.TextStyle` rather than a fixed point size, so text scales with
    // the user's Larger Text / Bold Text accessibility settings for free (HIG ACCESS-07). The
    // tvOS defaults already sit on the 10-foot size table (body 29, title3 48, title2 57…), so
    // each mapping below is the closest style to the old fixed size — call sites are unchanged.

    /// User-selectable UI font family (FEAT-31), driven by the device-local `ui_font` UserDefaults
    /// key — `"system"` (default) or `"openSans"`. The Settings row that writes this key is a
    /// separate wave's work; this type plus `Theme.Font` below is the machinery it drives.
    enum AppFontFamily: String, CaseIterable, Equatable {
        case system = "system"
        case openSans = "openSans"

        static let defaultsKey = "ui_font"

        /// Label for the (future) Settings row. "System" is a real word and gets localized; "Open
        /// Sans" is a proper name, which HIG/translators leave as-is, so it stays a plain literal.
        var displayName: String {
            switch self {
            case .system: return String(localized: "System")
            case .openSans: return "Open Sans"
            }
        }

        /// Reads the persisted choice. Missing key, or any value that isn't a known case (a future
        /// downgrade, a corrupted default), resolves to `.system` — never a crash or an unknown state.
        static func fromDefaults(_ defaults: UserDefaults = .standard) -> AppFontFamily {
            guard let raw = defaults.string(forKey: defaultsKey) else { return .system }
            return AppFontFamily(rawValue: raw) ?? .system
        }
    }

    enum Font {
        /// Selected UI font family. Mutable so a user's choice applies without relaunching —
        /// mutated only on the main actor (`NuvioTVApp.init()` at launch, or a future Settings
        /// toggle via `apply(_:)`), and reads are re-evaluated by the `.id` remount in ContentView
        /// the same way `Palette.accent` is. `nonisolated(unsafe)` for the same reason as that
        /// property. Default `.system` — with the defaults key absent, every token below must
        /// resolve byte-identically to its pre-FEAT-31 value.
        nonisolated(unsafe) static var family: AppFontFamily = .system

        /// Resolved-font cache for the CURRENT `family`, rebuilt only by `apply(_:)`. Tokens are
        /// read in hot row bodies (every card title, every row header), so a hit here must be a
        /// dictionary lookup, never a fresh descriptor/metrics computation.
        /// `nonisolated(unsafe)`: mutated only on the main actor, inside `apply(_:)`.
        nonisolated(unsafe) private static var cache: [Token: SwiftUI.Font] = buildCache(for: .system)

        /// Hero display text (was fixed 52pt bold → title2, 57pt): clearer step above screenTitle.
        static var hero: SwiftUI.Font { resolved(.hero) }
        /// Screen titles (was fixed 48pt bold → title3, 48pt — exact match).
        static var screenTitle: SwiftUI.Font { resolved(.screenTitle) }
        /// Section/row headers (was fixed 30pt semibold → callout, 31pt).
        static var sectionTitle: SwiftUI.Font { resolved(.sectionTitle) }
        /// Card titles under posters (was fixed 24pt → caption2, 23pt).
        static var cardTitle: SwiftUI.Font { resolved(.cardTitle) }
        /// Body copy (was fixed 28pt → body, 29pt — the HIG minimum for body text).
        static var body: SwiftUI.Font { resolved(.body) }
        /// Metadata lines — year/runtime/rating (was fixed 26pt semibold → caption, 25pt).
        static var meta: SwiftUI.Font { resolved(.meta) }
        /// Fine print (was fixed 22pt → caption2, 23pt).
        static var caption: SwiftUI.Font { resolved(.caption) }

        // HIG tvOS text styles not covered by the tokens above (spec §3.3). The full scale is
        // Title 1 76 · Title 2 57 · Title 3 48 · Headline 38 · Subtitle 1 38 · Callout 31 ·
        // Body 29 · Caption 1 25 · Caption 2 23 — `hero`, `screenTitle`, `sectionTitle`, `body`,
        // `meta` and `caption` already sit on Title 2, Title 3, Callout, Body, Caption 1 and
        // Caption 2. All of them scale with Larger Text and follow the selected font family.

        /// Title 1 (76pt). Full-screen messages only (error and end screens); too large for content.
        static var display: SwiftUI.Font { resolved(.display) }
        /// Headline (38pt). Shelf headers and the player title per the spec; also the size for a
        /// large standalone glyph such as the See All tile's chevron.
        static var headline: SwiftUI.Font { resolved(.headline) }
        /// Subtitle 1 (38pt, regular). Taglines under a title.
        static var subtitle: SwiftUI.Font { resolved(.subtitle) }

        private static func resolved(_ token: Token) -> SwiftUI.Font {
            cache[token] ?? build(token, family: family)
        }

        /// Applies a font family choice: a no-op if unchanged, otherwise swaps `family` and rebuilds
        /// the cache. Main-actor only (same contract as the mutable `Palette` accent setters).
        static func apply(_ newFamily: AppFontFamily) {
            guard newFamily != family else { return }
            family = newFamily
            cache = buildCache(for: newFamily)
            bodyLineHeight = measuredBodyLineHeight(for: newFamily)
            sectionTitleLineHeight = measuredSectionTitleLineHeight(for: newFamily)
        }

        /// The rendered line height of `Theme.Font.body`, from `UIFont` metrics of the SAME face
        /// and size the SwiftUI token resolves to — never a constant. Home's hero derives its
        /// synopsis line limit from this (BUG "1–2 lines", 2026-09-10): the old
        /// `heroSynopsisSlotHeightPinned / 2` (36) assumption undercounted Open Sans (≈39.5 pt per
        /// line → a 108 pt slot draws 2 lines while the code counted 3) and overcounted nothing;
        /// with the rc10 Large reach the No-Zoom panel slot is 107.67, which 36 rounds down to 2
        /// while the real ≈35 pt system line fits 3. Refreshed with the font cache on `apply(_:)`.
        static private(set) var bodyLineHeight: CGFloat = measuredBodyLineHeight(for: family)

        private static func measuredBodyLineHeight(for family: AppFontFamily) -> CGFloat {
            switch family {
            case .system:
                return UIFont.preferredFont(forTextStyle: .body).lineHeight
            case .openSans:
                let size = baseSize(for: .body)
                return UIFont(name: "OpenSans-Regular", size: size)?.lineHeight
                    ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            }
        }

        /// The rendered line height of `Theme.Font.sectionTitle` — the token every pinned ROW TITLE
        /// is drawn in — measured from `UIFont` metrics of the same text style the token resolves to,
        /// never a constant. Same contract and same refresh point as `bodyLineHeight`.
        ///
        /// `PinnedRowGeometry.topReachFloor(lift:titleHeight:)` defaults to it, and that is why it
        /// exists (BUG-87/89, rc10 Codex P2): the reach floor has to reserve the band the title
        /// ACTUALLY occupies, and it was reserving a hard-coded 38 — the system font's own number.
        /// Open Sans at the same text style measures ≈42.2 (its bundled faces carry 1.3618 em of
        /// vertical metrics against SF's ≈1.21), and the row title's clearance is computed from the
        /// title's live MEASURED height, so the 4pt gap came straight out of
        /// `PinnedRowTitle.Clearances.focusedRaw`: with zoom on it went NEGATIVE, which is the
        /// corrector's `LIFT-DEFICIT` stand-down — permanently, for the session, on a shipping font.
        ///
        /// Known limit, stated rather than implied: like `bodyLineHeight` this is refreshed only by
        /// `apply(_:)`, so a Larger Text change mid-session is not picked up until the next font
        /// apply or relaunch, and the Open Sans branch measures the DEFAULT content size category
        /// (`baseSize(for:)`) while the rendered title scales with `relativeTo:`. Both err the same
        /// way — the metric can read SHORT of what is drawn — and the consequence is bounded and
        /// already handled: the floor may then leave less than `fadeIntrusionArm`, and at an
        /// accessibility size it can leave a genuine deficit, which is the documented handoff to the
        /// visibility belt (see `topReachFloor`).
        ///
        /// `nonisolated(unsafe)` — the one difference from `bodyLineHeight`, and it is load-bearing:
        /// `PinnedRowGeometry.topReachFloor(lift:titleHeight:)` and `plan(…)` read this as a DEFAULT
        /// ARGUMENT, and both are `nonisolated`. A nonisolated function's default value expression
        /// may not touch main-actor state (SE-0411 — a warning in this target's Swift 5 mode, an
        /// error in Swift 6). Same contract as `family` directly above: written only on the main
        /// actor, inside `apply(_:)`; read from anywhere.
        nonisolated(unsafe) static private(set) var sectionTitleLineHeight: CGFloat =
            measuredSectionTitleLineHeight(for: family)

        /// Measured against `Token.sectionTitle`'s OWN text style rather than a pasted `.callout`, so
        /// a change to that mapping moves this with it. The Open Sans branch uses the SemiBold face
        /// because that is the weight the token carries; all three bundled Open Sans faces share
        /// their vertical metrics, so the Regular fallback measures the same line height rather than
        /// a different one. The system branch takes no weight for the same reason (SF's semibold has
        /// the regular's metrics), which is also why the historical 38pt reference still describes
        /// the system font.
        ///
        /// `nonisolated` because it initializes the `nonisolated(unsafe)` property above. Nothing it
        /// touches is main-actor state: `UIFont`, `UIFontDescriptor` and `UITraitCollection` are not
        /// actor-isolated in the tvOS SDK, and `Token`/`family` are both declared nonisolated too.
        nonisolated private static func measuredSectionTitleLineHeight(for family: AppFontFamily) -> CGFloat {
            let style = Token.sectionTitle.uiTextStyle
            switch family {
            case .system:
                return UIFont.preferredFont(forTextStyle: style).lineHeight
            case .openSans:
                let size = baseSize(for: style)
                return UIFont(name: "OpenSans-SemiBold", size: size)?.lineHeight
                    ?? UIFont(name: "OpenSans-Regular", size: size)?.lineHeight
                    ?? UIFont.preferredFont(forTextStyle: style).lineHeight
            }
        }

        private static func buildCache(for family: AppFontFamily) -> [Token: SwiftUI.Font] {
            var result: [Token: SwiftUI.Font] = [:]
            for token in Token.allCases {
                result[token] = build(token, family: family)
            }
            return result
        }

        /// Builds one token's font for one family. System mode reproduces the exact pre-FEAT-31
        /// expression (`.system(textStyle)` + `.weight` only when the token has one, which is
        /// Equatable-identical to the old `SwiftUI.Font.title2.weight(.bold)`-style literals) so
        /// the default behavior stays byte-for-byte unchanged. Open Sans mode swaps the family for
        /// a `.custom` font anchored to the same text style via `relativeTo:`, so Larger Text still
        /// scales it.
        private static func build(_ token: Token, family: AppFontFamily) -> SwiftUI.Font {
            switch family {
            case .system:
                let base = SwiftUI.Font.system(token.textStyle)
                guard let weight = token.weight else { return base }
                return base.weight(weight)
            case .openSans:
                let size = baseSize(for: token.uiTextStyle)
                let base = SwiftUI.Font.custom("Open Sans", size: size, relativeTo: token.textStyle)
                guard let weight = token.weight else { return base }
                return base.weight(weight)
            }
        }

        /// The platform's own default-category point size for a text style — the base fed to
        /// `.custom(_:size:relativeTo:)`. Derived, never a hard-coded number (the HIG contract bans
        /// fixed point sizes at call sites): `.large` is the system's default content size
        /// category, so this is exactly the un-scaled size `SwiftUI.Font.system(textStyle)` starts
        /// from, and `relativeTo:`/`UIFontMetrics` above still let Larger Text scale it further.
        ///
        /// `nonisolated`: `measuredSectionTitleLineHeight` initializes a `nonisolated(unsafe)` metric
        /// and so has to reach this from outside the main actor. Nothing here is main-actor state —
        /// `UIFontDescriptor` and `UITraitCollection` are not actor-isolated in the tvOS SDK — and the
        /// MainActor callers (`build`, `uiFont`) are unaffected by the widening.
        nonisolated static func baseSize(for textStyle: UIFont.TextStyle) -> CGFloat {
            UIFontDescriptor.preferredFontDescriptor(
                withTextStyle: textStyle,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            ).pointSize
        }

        /// A `UIFont` for the given text style — the system preferred font in system mode, or an
        /// Open Sans face scaled through `UIFontMetrics` (so Larger Text still applies) in Open
        /// Sans mode, falling back to the system font if the face isn't registered. The one UIKit
        /// font-measurement call site in the app (`CollectionsUI.swift`) calls this instead of
        /// `UIFont.preferredFont(forTextStyle:)` directly, so it follows the same family choice.
        static func uiFont(for textStyle: UIFont.TextStyle) -> UIFont {
            guard family == .openSans,
                  let custom = UIFont(name: "OpenSans-Regular", size: baseSize(for: textStyle)) else {
                return UIFont.preferredFont(forTextStyle: textStyle)
            }
            return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: custom)
        }

        /// Whether the Open Sans face is actually registered — used by diagnostics/tests rather
        /// than call sites (which always go through `build`/`uiFont`'s own fallback). Checks Bold
        /// specifically since it's the heaviest weight the tokens above depend on.
        static var isCustomFaceAvailable: Bool {
            UIFont(name: "OpenSans-Bold", size: 20) != nil
        }

        /// Per-token text-style/weight mapping, exactly mirroring the values the 7 tokens above
        /// hard-coded before FEAT-31 — see this section's header comment for the size rationale.
        // `nonisolated`: used as a dictionary key from the `nonisolated(unsafe)` cache above; under
        // the target's MainActor default isolation the Hashable conformance would otherwise be
        // actor-isolated (a warning today, an error in Swift 6 mode).
        nonisolated private enum Token: CaseIterable, Hashable {
            case hero, screenTitle, sectionTitle, cardTitle, body, meta, caption
            case display, headline, subtitle

            var textStyle: SwiftUI.Font.TextStyle {
                switch self {
                case .display: return .title
                case .headline: return .headline
                case .subtitle: return .subheadline
                case .hero: return .title2
                case .screenTitle: return .title3
                case .sectionTitle: return .callout
                case .cardTitle: return .caption2
                case .body: return .body
                case .meta: return .caption
                case .caption: return .caption2
                }
            }

            var uiTextStyle: UIFont.TextStyle {
                // NOTE: UIFont.TextStyle names these differently from SwiftUI.Font.TextStyle —
                // `.caption1` here, not `.caption` (SwiftUI has no `.title1`/`.caption1`, UIKit has
                // no bare `.title`/`.caption`). Mixing them up is a compile error, not a bug — kept
                // as its own switch (rather than deriving from `textStyle`) so that stays true.
                switch self {
                case .display: return .title1
                case .headline: return .headline
                case .subtitle: return .subheadline
                case .hero: return .title2
                case .screenTitle: return .title3
                case .sectionTitle: return .callout
                case .cardTitle: return .caption2
                case .body: return .body
                case .meta: return .caption1
                case .caption: return .caption2
                }
            }

            var weight: SwiftUI.Font.Weight? {
                switch self {
                case .display, .headline, .subtitle: return nil
                case .hero: return .bold
                case .screenTitle: return .bold
                case .sectionTitle: return .semibold
                case .cardTitle: return nil
                case .body: return nil
                case .meta: return .semibold
                case .caption: return nil
                }
            }
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 40
        /// Overscan-safe screen edge padding.
        static let screen: CGFloat = 60
        /// Vertical gap between stacked sections/rows.
        static let sectionGap: CGFloat = 48
        /// Horizontal gap between cards in a row.
        static let rowGap: CGFloat = 28
        /// BUG-106 (u/mrStevenx3, rc8 video 2026-09-10): gap for rows of 16:9 cards that wear the
        /// ring-mode manual lift (`CardArtworkFocusLift.manualScale` — today the Saga row). That
        /// lift is a uniform scale of `1 + 2 × heroPinnedRowFocusLiftAllowance / height`, so a
        /// 16:9 card grows `2 × 20 × 16 / 9 ≈ 71 pt` in width WHATEVER its size — ≈35.5 pt per
        /// side. Under `lg` (24) the raised card landed ≈11.5 pt onto each neighbour; 40 leaves
        /// ≈4.5 pt clear in ring mode and ≈15 pt under the default system lift (≈1.1×, ≈25 pt per
        /// side at 500 wide). Portrait cards grow only ≈13 pt per side, so `rowGap` stays.
        static let landscapeLiftRowGap: CGFloat = 40
    }

    // MARK: - Corner radii

    enum Radius {
        static let chip: CGFloat = 6
        static let card: CGFloat = 12
        static let hero: CGFloat = 16
        /// Floating panels over media and artwork — the player's transport bar, its pause / Up Next /
        /// stream-info cards, the swipe-down panel, the stream picker's list (AES-7). Artwork inside
        /// them keeps `card`.
        static let panel: CGFloat = 24
    }

    // MARK: - Standard element sizes

    enum Size {
        static let posterWidth: CGFloat = 220
        static let posterHeight: CGFloat = 330      // 2:3
        static let landscapeWidth: CGFloat = 360
        static let landscapeHeight: CGFloat = 203   // 16:9
        /// FEAT-34 (2026-09-09, tester ask via u/mrStevenx3 on rc7): the description page's saga
        /// row read as the same size as the trailer cards; official Nuvio's saga cards read
        /// noticeably larger. `SagaCard`-only size, distinct from `landscapeWidth`/`landscapeHeight`.
        ///
        /// rc9 (2026-09-10): 440×248 was still "too small" on rc8 (u/mrStevenx3). Measured from the
        /// reference photo (`docs/research/steven-beta18-photos/2026-09-08-official-nuvio-saga-row-
        /// landscape.jpg`, outer repo): the visible screen spans ~1010 px for 1920 pt, the two
        /// UNFOCUSED cards span ~271 / ~261 px (≈515 / ≈496 pt, the spread is camera perspective)
        /// at a 16:9 ratio, and the three cards plus gaps cover ~84% of the screen width — the
        /// earlier "two thirds" note in `SagaCard.swift` under-read the photo. 500×281 reproduces
        /// that: 3 × 500 + 2 × `Spacing.lg` + `Spacing.screen` = 1608 pt of 1920 (84%).
        static let sagaCardWidth: CGFloat = 500
        static let sagaCardHeight: CGFloat = 281    // 16:9 (500 × 9 / 16 = 281.25)
        /// Episode thumbnail cards in the Detail episodes row (16:9, larger than landscape cards
        /// so the still + badges stay readable at 10 feet).
        static let episodeWidth: CGFloat = 420
        static let episodeHeight: CGFloat = 236
        static let miniPosterWidth: CGFloat = 180
        static let miniPosterHeight: CGFloat = 270
        static let castAvatar: CGFloat = 140
        static let heroHeight: CGFloat = 480
        /// Height of the full-bleed Home hero backdrop (image + scrim) behind the scrolling rows.
        static let heroBackdropHeight: CGFloat = 820
        /// Top padding that pushes the hero's logo/synopsis overlay down onto the lower third of
        /// the backdrop (mirrors Detail's layout).
        static let heroForegroundTopPad: CGFloat = 340
        /// Fixed height of the hero carousel viewport. Every page reserves identical slot heights
        /// (logo + meta + synopsis + CTA button), so advancing the hero can never reflow the rows
        /// below it — that reflow was the visible "glitch" on every 8s auto-advance. Sized to the
        /// tallest layout's summed slots + paddings (Nuvio-style: 150+32+108+56 + 3×16 + 2×24)
        /// with a little headroom.
        static let heroCarouselHeight: CGFloat = 452
        /// Fixed slot for the hero's "Go to Movie"/"Go to Show" CTA button (the hero's only
        /// focusable element — the info block above it is static content).
        static let heroButtonSlotHeight: CGFloat = 56
        /// Fixed logo/title slot inside a hero page (bottom-aligned; image fits within it).
        static let heroLogoSlotHeight: CGFloat = 150
        static let heroLogoMaxWidth: CGFloat = 520
        /// Fixed single-line metadata slot inside a hero page.
        static let heroMetaSlotHeight: CGFloat = 32
        /// Fixed two-line synopsis slot inside a hero page.
        static let heroSynopsisSlotHeight: CGFloat = 72
        // UX-2 hero redesign, v2: "Nuvio-style" — info panel top-LEFT, artwork reading on the
        // right behind a leading scrim. Same fixed-slot rule as the classic layout: every
        // dimension constant so pages stay layout-identical and the carousel never reflows
        // the rows below. Panel sum stays inside `heroCarouselHeight`
        // (150 + 32 + 108 + spacings ≈ 320 < 344).
        /// Fixed three-line synopsis slot for the fixed-width Nuvio-style panel.
        static let heroSynopsisSlotHeightNuvio: CGFloat = 108
        /// Fixed width of the leading hero info panel (text column) in the Nuvio-style layout.
        static let heroInfoPanelWidth: CGFloat = 680
        /// Nuvio-style raises the info panel toward the top of the backdrop (classic uses
        /// `heroForegroundTopPad`'s lower-third placement). Currently unreferenced: the
        /// Nuvio-style hero is pinned above the rows now and uses the compacted
        /// `heroPinnedTopPad` instead. Kept as the in-scroll Nuvio value in case that layout
        /// comes back.
        static let heroForegroundTopPadNuvio: CGFloat = 120
        /// Width of the right-anchored artwork panel in the Nuvio-style hero (tvOS layout is
        /// a fixed 1920pt canvas). Its left ~30% fades out via a gradient mask, so the flat
        /// background region behind the 680pt info panel meets the art in a smooth blend.
        static let heroNuvioArtworkWidth: CGFloat = 1250
        // Pinned Nuvio hero (UX-7 extension): when the Nuvio-style hero is pinned above the rows
        // (a VStack split — hero fixed on top, rows ScrollView takes the remainder) the two share
        // ONE 1080pt screen instead of the hero scrolling away, so the hero region has to be
        // compacted. Height budget, measured in the sim:
        //   ~76 tab-bar safe area + 8 top pad + ~490 carousel (452 + page dots) + 0 gap ≈ 574,
        // leaving ~506pt for the rows viewport. A default poster row's FOCUS FRAME is
        //   72 top reach + 330 poster + 16 gap + ~28 caption + 48 bottom reach ≈ 494 ≤ 506 —
        // both reaches must fit INSIDE the viewport or the focus engine can't reveal the whole
        // frame and rest positions degrade. Oversized user Poster Style settings can exceed the
        // budget; that degrades to partially-revealed frames (art-edge cuts), same as before the
        // reaches existed. Shrink these only against that budget. Classic is untouched: it
        // keeps `heroForegroundTopPad`, and `heroCarouselHeight` is shared by both layouts.
        /// Compact pinned-hero slots (device round 6): the full 452pt carousel left the rows
        /// viewport at ~506pt, and a reach-extended row focus frame (~490) PLUS the focus
        /// engine's own reveal margin (~60, device-measured) did not fit — unsatisfiable
        /// reveals produced stuck rests, cut captions, and trapped focus. The pinned hero
        /// renders a COMPACT foreground instead (smaller logo slot, 2-line synopsis, tighter
        /// vertical padding): content = 16 + (110 logo + 16 + 32 meta + 16 + 72 synopsis) +
        /// 16 + 56 CTA + 16 ≈ 350 → frame 352, freeing ~100pt (rows viewport ≈ 606).
        /// Classic keeps the full-size slots everywhere.
        static let heroCarouselHeightPinned: CGFloat = 352
        static let heroLogoSlotHeightPinned: CGFloat = 110
        /// 2-line synopsis in the compact pinned hero (3 lines in full Nuvio).
        static let heroSynopsisSlotHeightPinned: CGFloat = 72
        /// Top padding above the PINNED hero header (pinned Nuvio mode only — the classic
        /// in-scroll layout keeps `heroForegroundTopPad`).
        static let heroPinnedTopPad: CGFloat = 8
        /// Gap between the pinned hero header and the top of the rows ScrollView below it.
        /// 0: the page-dots row inside the carousel already carries its own whitespace.
        static let heroPinnedRowsGap: CGFloat = 10
        /// Top content inset INSIDE the pinned rows ScrollView. Small: the real protection
        /// against device rest-position error lives per-row in `heroPinnedRowTopPad` (below) —
        /// this only sets where row 1 rests at true top (8 + 88; with the original 72 reach,
        /// 8 + 72 ≈ the 80 the round-2 fix used).
        static let heroPinnedRowsHeadroom: CGFloat = 8
        /// Per-row top band in the PINNED rows list (replaces the LazyVStack's sectionGap in
        /// pinned mode, which drops to 0), AND the `rowCardTopReach` each row card extends its
        /// focusable frame upward by in pinned mode (see BrowseComponents). Device rounds 1–4
        /// of the pinned-hero pass (2026-08-03): hardware rests the focus engine's
        /// scroll-to-reveal systematically high (BUG-30 residual class; every tvOS scroll is
        /// reveal-driven — swipes drive focus, there is no free momentum scrolling), and the
        /// pinned clip edge turned that into cropped poster tops / bisected titles. Padding
        /// OUTSIDE the card frame can never fix that (the reveal target excludes it — rounds
        /// 2–3 proved it on device); the card frames themselves reach up through this band, so
        /// the reveal always includes the section title. Also the row-to-row visual gap in
        /// pinned mode (88 vs classic's 48 sectionGap — slightly airier by design).
        ///
        /// BUG-53 (2026-08-11 device pass): 72 → 88. On the beta.12 build rests are
        /// deterministic — every settled rest parks the slid title bottom EXACTLY at the
        /// artwork top, zero slack — so the system `hoverEffect(.highlight)` lift (~10–16pt)
        /// on a row's leftmost cards clipped the title. Widening the band (and with it the
        /// reach — deliberately coupled: a reach larger than the band would overlap the
        /// previous row's focus frames) to 88 gives the parked title a 16pt cushion above
        /// the art. Reach is the most regression-prone dial (the sim bisected reach 100 =
        /// focus resolution dies outright; 72 was the long-proven value): any focus
        /// hesitation or missed navigation on device means reverting to 72.
        static let heroPinnedRowTopPad: CGFloat = 88
        /// Downward card reach in pinned mode (device round 5): scrolling DOWN, the reveal
        /// rests short in the mirror direction, leaving the focused card's caption — and up to
        /// ~40pt of art — below the fold. Extending the focus frame down by this much makes the
        /// reveal pull the row fully above the fold even with that shortfall. Smaller than the
        /// top reach because there is no title band to cover below, only the rest error.
        static let heroPinnedRowBottomReach: CGFloat = 44
        /// Top inset of the section title OVERLAID inside a pinned row's reach band (the title
        /// floats over the transparent region the cards' focus frames cover, so the engine's
        /// reveal always shows it). Band above the art = shelf padding (24) + top reach (88)
        /// = 112; the title (~40) sits at this inset with a ~24pt static gap to the art
        /// (~12pt back when the reach was 72/band 96) so that the distance from the button
        /// frame's top to the title's top exceeds the device's measured reveal residual — a
        /// full-residual rest still shows the whole title. Reach history: 72 was the
        /// long-proven value (the sim freeze bisected to reach 100, where focus resolution
        /// dies); raised to 88 for BUG-53 — see `heroPinnedRowTopPad`.
        ///
        /// BUG-37 CORRECTION (2026-08-05): that "~48pt" was the inset read against the wrong
        /// anchor. The overlay is attached to the SHELF (the horizontal ScrollView), whose top is
        /// where this inset is measured from, while the card's focusable frame — the thing the
        /// engine's scroll-to-reveal actually aligns — starts `Spacing.lg` (24) further down,
        /// inside the shelf's own vertical padding. The real button-top→title-top margin is
        /// 48 − 24 = **24pt**, roughly half the device's 40–67pt rest envelope, which is exactly
        /// why titles still vanish on hardware while the sim looks correct. The inset itself is
        /// left alone (it is the resting look device round 8 signed off); the shortfall is
        /// absorbed by the slide below.
        static let heroPinnedRowTitleInset: CGFloat = 48
        /// BUG-37 (2026-08-05): how far the overlaid title may ride DOWN to stay inside the rows
        /// viewport when the device rests short of the reveal target.
        ///
        /// No static inset can cover the envelope. The whole band above the art is
        /// shelf padding (24) + reach (88) = 112pt and the title is ~40pt tall, so the largest
        /// static button-top→title-top margin the band can offer is 112 − 40 − 24 = 48pt —
        /// at the time of measurement (reach 72, band 96, margin 32pt) under the 40–67pt error
        /// either way, whether the title hangs off the shelf (today) or off the card frame.
        /// Widening the band further means a reach approaching 100, the sim-bisected value
        /// where focus resolution dies outright, so that door is shut too. (The 40–67pt
        /// envelope itself no longer reproduces on beta.12 — rests are deterministic — but
        /// the slide stays: it is what parks the title at the clip edge at every rest.)
        /// Hence a render-time slide (`pinnedRowTitleTracking`, BrowseComponents) with this
        /// clamp: 72 covers the full 0–67pt envelope on top of the 24pt static margin, and bounds
        /// how far a deeply-clipped row's title may ride over its own artwork (worst case ~62pt
        /// of a 330pt poster, at rests where the clip edge is cutting that art anyway).
        static let heroPinnedRowTitleMaxSlide: CGFloat = 72
        /// Wave 4 item 6 (tester report, `docs/steven-batch-plan-2026-08-29.md`): how much of a
        /// row's ARTWORK a slid title may cover, as a fraction of that artwork's height.
        ///
        /// `heroPinnedRowTitleMaxSlide` bounds the SLIDE; what the viewer actually judges is the
        /// INTRUSION — how far the title's bottom edge ends up PAST the artwork's top edge. At a
        /// settled rest the title's bottom sits `(Spacing.lg + heroPinnedRowTopPad) −
        /// (heroPinnedRowTitleInset + titleHeight)` = (24 + 88) − (48 + ~38) ≈ **26pt** above the
        /// art, so a full 72pt slide intrudes ≈ **46pt**. That 46 is a FIXED number measured
        /// against a SCALED card:
        ///
        ///     Poster Size       artwork height              46pt intrusion
        ///     Small  (105 dp)   275pt (183 × 1.5)           16.7%
        ///     Medium (126 dp)   330pt                       13.9%
        ///     Medium+ 351: takes the Large dial (FEAT-39)
        ///     Large  (154 dp)   403pt                       11.4%
        ///     Landscape rows    203pt                       22.7%
        ///     Folder tile,      183pt (square/16:9 folder   25.1%  ← the tester's
        ///       Small             tiles take their height           "Streaming Services" row
        ///                         from `style.width`)
        ///
        /// A poster's top sixth is usually empty margin, so the fixed cap reads as harmless there;
        /// a folder tile's is not — square/landscape folder covers are CENTRED WORDMARKS on a short
        /// tile, so the same 46pt lands on the only thing the tile exists to show.
        ///
        /// 9% is the budget: under the ~10% top band that stays visually empty on virtually all
        /// poster art, and never tighter than the ~26pt of static clearance a deterministic beta.12
        /// rest needs — the resolved cap is `clearance + budget` (see `PinnedRowTitle.maxSlide`),
        /// so a settled rest, which parks the title's bottom exactly at the artwork's top edge, is
        /// unchanged at every Poster Size. Only deeply-clipped rows (mid-scroll, or a row well
        /// above the focused one) give up slide, and those are rows whose art the clip edge is
        /// cutting anyway.
        static let heroPinnedRowTitleArtIntrusionFraction: CGFloat = 0.09
        /// Allowance for the SYSTEM focus lift, in points — how far a focused card's artwork rises
        /// above its resting top under `CardFocusMode.systemLift`, and therefore how much deeper a
        /// slid title cuts into the art the viewer is actually looking at.
        ///
        /// Pixel-measured on the FA87 sim fixture (2026-08-30) and — the part that matters —
        /// measured as the SAME ~20pt at Medium AND at Large. The SYSTEM hover effect's rise does
        /// not grow with the card, which is precisely why the rc1 report ("titles continue to
        /// overlap the posters … only at Large") is not a lift problem.
        ///
        /// As of BUG-93 (beta.18) this is the ONE rise for both zoom-on modes, and the single
        /// source of truth for all three consumers. `PosterCard.cardFocusLiftRise` is defined as
        /// this constant and derives ring mode's per-card scale from it
        /// (`cardLiftScale(artworkHeight:)`), so the ring no longer charges a size-dependent
        /// 16/20/27pt against a budget that reserved 20. `PinnedRowTitle.focusLiftAllowance`
        /// (BrowseComponents) returns this in both zoom modes and 0 under "No Zoom on Focus"
        /// (Wave 7 made that genuinely zero-lift). Nothing lays out against it — it feeds the
        /// settle re-reveal's correction band, the visibility belt's threshold, and the
        /// `intrLifted=` probe field. rc12: also the floor `PinnedRowGeometry.plan`'s `floorLift`
        /// borrows in No Zoom when the reach-hold A/B is on, reserving the same band width even
        /// though nothing actually scales in that mode.
        static let heroPinnedRowFocusLiftAllowance: CGFloat = 20
        /// Hard ceiling on ONE settle re-reveal correction (`PinnedRowSettle`, BrowseComponents).
        ///
        /// The measured Large failure needs ~90pt (sim probe 2026-08-30: `margin=-86..-100`,
        /// `slide=72` saturated, `net` negative). 220 leaves generous room for a taller card or
        /// text configuration while making it impossible for one bad measurement to fling the
        /// page: a correction larger than this is a broken measurement, not a rest worth chasing.
        static let heroPinnedRowSettleMaxNudge: CGFloat = 220

        // MARK: Wave 10 — static hero compression

        /// The pinned rows viewport as it stands with NO compression, in points.
        ///
        /// Device- and sim-verified: `vh=455` in both probes (2026-08-31). It is treated as a
        /// measured platform constant rather than re-derived at layout time on purpose — the
        /// compression it feeds CHANGES this viewport, so measuring the live value and feeding it
        /// back would be a layout feedback loop on the single most regression-prone surface in the
        /// app. `PinnedRowTitle.pinnedHeroCompression` logs loudly if the live `vh` ever disagrees
        /// with `budget + compression`, so the assumption cannot rot silently.
        static let heroPinnedRowsViewportBudget: CGFloat = 455

        // MARK: FEAT-30 — sidebar chrome

        /// Extra TOP safe-area padding applied to the tab shell in SIDEBAR mode only (FEAT-30);
        /// lives here, not with the rest of the sidebar's numbers, because it exists purely to
        /// keep `heroPinnedRowsViewportBudget` above honest.
        ///
        /// Hiding the system tab bar may change the shell's top safe area, and that budget is a
        /// MEASURED platform constant the whole pinned-hero compression chain is derived from — if
        /// the sidebar moves the top inset, every rest position on Home is computed against a
        /// viewport that no longer exists (`PinnedRowTitle.pinnedHeroCompression` would start
        /// logging its BUDGET MISMATCH line). Padding the top back by the delta keeps 455 valid
        /// instead of forking the constant per chrome mode.
        ///
        /// SHIPS AS 0, and 0 means "no modifier applied at all" (`sidebarTopCompensation()` in
        /// SidebarOverlay.swift branches structurally), so an untouched build in either mode is
        /// unaffected. The Phase 0 device spike (`-debug.sidebarSpike YES`) measures the real delta
        /// against 455 and the shipping value replaces the 0 below.
        ///
        /// The knob is what lets a device pass bisect the value without a rebuild — same override
        /// pattern as `debug.pinnedTitleMaxSlide` (`PinnedRowTitle.maxSlideOverride`) and
        /// `debug.heroFolderLogoHeight` above: `UserDefaults.standard` consults the launch-argument
        /// domain first, so
        ///
        ///     xcrun devicectl device process launch --terminate-existing --device <udid> \
        ///         com.nuvio.media.NuvioTV -debug.sidebarTopCompensation 32
        ///
        /// works on physical hardware. Launch-latched: the shell reads it during layout, and a
        /// value that changed mid-session would move the rows viewport under a settled rest.
        static let sidebarTopCompensation: CGFloat = {
            let override = UserDefaults.standard.double(forKey: "debug.sidebarTopCompensation")
            return override > 0 ? CGFloat(override) : 0
        }()
        /// Hard ceiling on the compression: exactly what the pinned hero's internals can actually
        /// yield, and not a point more.
        ///
        /// DERIVED, never a literal (Codex Wave 10 r4). It used to be a hand-picked 110 while the
        /// hero could only give ~70, so a large enough demand shrank the FRAME up to ~40pt further
        /// than the CONTENT shrank and the hero's own slots overflowed into the page dots and the
        /// rows below. Computing it from the same three give values `HomeHeroForeground` spends
        /// means a future slot or floor change moves the cap with it instead of silently
        /// reopening that gap.
        ///
        /// That overflow was reachable in production, not just in theory: `PosterStyle.init(from:)`
        /// takes `widthDp` straight off the synced `PosterCardStyleUiState` and computes
        /// `height = width * 1.5` with no clamp to the three Poster Size presets. A width above
        /// Large — written by another client, or by a future mobile build with a wider range — is
        /// a perfectly ordinary payload here, and it drives `pinnedHeroCompression` toward whatever
        /// ceiling this constant sets.
        ///
        /// Past the cap the geometry is honestly unsatisfiable again: `pinnedHeroCompression` logs
        /// `compression CAPPED want=… — rows still short, belt remains in play`, and the
        /// visibility belt covers the residue exactly as designed (see `PinnedRowSettle`'s handoff
        /// contract). A too-tall poster costs a hidden row title, never a broken hero.
        static let heroPinnedCompressionCap: CGFloat =
            heroLogoSlotPinnedGive + heroSynopsisSlotPinnedGive + heroPinnedFrameSlack
        /// BUG-87 (beta.18): the same ceiling, stated for the hero form that is actually on screen.
        ///
        /// The constant above is the CAROUSEL form's give. FEAT-15's focus panel (`showsCTA ==
        /// false`) renders the same pinned hero with the CTA removed and its slot folded into the
        /// synopsis (`heroSynopsisSlotHeightPinnedPanel`, 144 against 72 — see
        /// `HomeHeroForeground.synopsisSlotHeight`), so the panel can give 108pt of synopsis where
        /// the carousel gives 36 — 142 in total against 70. Sizing the compression against the
        /// carousel number in panel mode is what left Steven's shape (Large + Hide Labels + Show
        /// Hero off) 12pt over its viewport with 72pt of unspent give sitting in the hero.
        ///
        /// Same derivation rule as the constant, for the same reason (Codex Wave 10 r4): it is the
        /// sum of the gives `HomeHeroForeground` actually spends, never a hand-picked number, so a
        /// future slot or floor change moves the ceiling with it. `PinnedRowGeometry.plan` is the
        /// only caller; carousel-only call sites keep reading the constant.
        ///
        /// `nonisolated`: read from `PinnedRowGeometry`'s pure, non-main-actor plan (and its unit
        /// tests). The `static let`s it sums are immutable and Sendable, so they are already
        /// reachable from anywhere; only the function needs saying so.
        nonisolated static func heroPinnedCompressionCap(showsCTA: Bool) -> CGFloat {
            heroLogoSlotPinnedGive
                + (showsCTA ? heroSynopsisSlotPinnedGive : heroSynopsisSlotPanelPinnedGive)
                + heroPinnedFrameSlack
        }
        /// Breathing room below the focused row's artwork at the canonical rest, so the poster's
        /// bottom edge is not flush with the fold. Reuses the rows headroom rather than inventing
        /// a number: it is the same "absorb the rest error" budget, spent at the other end.
        ///
        /// LOAD-BEARING for the "Medium and Small are bit-identical" guarantee. With
        /// `requiredRowExtent = Spacing.lg (24) + heroPinnedRowTopPad (88) + artwork + cushion`:
        ///
        ///     Small      24 + 88 + 275.0 + 8 = 395.0  →  under 455, compression 0
        ///     Medium     24 + 88 + 330.0 + 8 = 450.0  →  under 455, compression 0 (5pt spare)
        ///     Medium+ 351: takes the Large dial (FEAT-39)
        ///     Large      24 + 88 + 403.3 + 8 = 523.3  →  compression 68.3
        ///     Landscape  24 + 88 + 203.0 + 8 = 323.0  →  0 (landscape rows are shorter)
        ///
        /// A larger cushion would push Medium over the line and change a layout nobody complained
        /// about; a smaller one buys Large nothing it needs. 8 is the value that satisfies both.
        static let heroPinnedRowsSettledCushion: CGFloat = heroPinnedRowsHeadroom
        /// BUG-89 (beta.18-rc2, Steven's video): the device-observed extra DEPTH of the focus
        /// engine's own rest compared with the simulator's — measured off that video, where the
        /// LAST row parks roughly 90pt deeper than a middle row does, at Large AND at Medium, with
        /// the previous row's tiles still showing clipped above it. BUG-66 family: the same
        /// hardware-only anchoring spread the Wave G band header records (~55pt there), and nothing
        /// in the simulator reproduces it.
        ///
        /// Used by ONE thing: the floor under `HomeView.pinnedRowsBottomInset`. It only ever ADDS
        /// SCROLL RANGE at the bottom of the rows list — it is a content inset, so it can never
        /// move a row's rest, change a band edge, or alter a correction. What it changes is whether
        /// `PinnedRowSettle.settlePlan` has any range left to spend when the engine parks the last
        /// row deep: without it `scrollRoomUp` is exhausted at that park and the `endOfContent`
        /// branch closes the epoch with `nudge=0`, which is the honest answer to "there is no
        /// scroll left" and the wrong outcome for "the engine parked 90pt deeper than we sized for".
        ///
        /// 96 rather than 90: the measurement is read off a photograph of a TV, so it is rounded up
        /// to the next multiple of the dead zone's own granularity with a little margin. Over-
        /// providing costs nothing (unused range is simply never scrolled into); under-providing
        /// puts the last row straight back into `endOfContent`.
        static let heroPinnedRowsDeviceParkSlack: CGFloat = 96
        /// Floors the compression may drive the pinned hero's two elastic slots down to. Compressing
        /// these — rather than shrinking the hero's frame around fixed content — is what keeps the
        /// hero from hard-clipping: the logo keeps a legible slot and the synopsis drops from two
        /// lines to one. Their combined give is exactly 68pt (110→78 and 72→36), which covers
        /// Large's 68.3pt requirement with the frame's own 2pt of slack (352 frame vs 350 content).
        static let heroLogoSlotHeightPinnedFloor: CGFloat = 78
        static let heroSynopsisSlotHeightPinnedFloor: CGFloat = 36

        /// FEAT-29 (Steven's beta.17 report, re-raised as a regression): a focused collection
        /// folder's hero wordmark used to render inside the shared TITLE-hero pinned logo slot,
        /// which Wave 10's compression drains first (`heroLogoSlotHeightPinned` 110 → 78 at
        /// Large, 110 at Medium — "the Walt Disney logo is tiny, and it's a little bigger at
        /// Medium" is exactly that give). Folder heroes have no meta line or synopsis to protect
        /// (`HomeView.folderHeroPreview` always sends `description: nil, genres: []`), so they now
        /// render through their OWN merged box (`HomeHeroForeground.nuvioLayout`/`.classicLayout`)
        /// sized against the reference footage instead of borrowing the title-hero slot: official
        /// Nuvio's collection wordmark reads roughly 0.2-0.35x the poster height, comfortably wide
        /// enough that a 2:1 wordmark spans 300+pt at Large. 160 is a FIXED point value (not
        /// poster-scaled) so the wordmark reads the same size at every Poster Size rather than
        /// shrinking with the grid — 0.40x Small (275), 0.48x Medium (330), 0.58x Large (403.3)
        /// poster height; a 2:1 wordmark renders 320pt wide. Medium+ 351: takes the Large dial
        /// (FEAT-39). The inside-collection folder page
        /// title (`FolderRoute`) is untouched — this only sizes the HOME hero's wordmark.
        static let heroFolderLogoSlotHeight: CGFloat = 160

        /// Release-inert device-bisect knob for `heroFolderLogoSlotHeight` — the device pass needs
        /// to judge the wordmark size on Christian's TV against Steven's reference frames before
        /// the number ships. Same override pattern as `PinnedRowTitle.maxSlideOverride`
        /// (BrowseComponents.swift): read once at launch, `UserDefaults.standard` consults the
        /// launch-argument domain before every other domain, so a `devicectl device process
        /// launch` invocation can set it on physical hardware with no rebuild:
        ///
        ///     xcrun simctl spawn <udid> defaults write com.nuvio.media.NuvioTV debug.heroFolderLogoHeight -float 200
        ///     xcrun devicectl device process launch --terminate-existing --device <udid> \
        ///         com.nuvio.media.NuvioTV -debug.heroFolderLogoHeight 200
        ///
        /// Unset/0 = the shipped constant.
        static let heroFolderLogoHeightOverride: CGFloat? = {
            let v = UserDefaults.standard.double(forKey: "debug.heroFolderLogoHeight")
            return v > 0 ? CGFloat(v) : nil
        }()

        /// The three components of the pinned hero's SHRINK BUDGET — how much its internals can
        /// actually give up. `HomeHeroForeground` spends the first two in this order, and
        /// `heroPinnedCompressionCap` is their sum, so the budget and the ceiling can never drift
        /// apart: change a slot or a floor and both move together.
        static let heroLogoSlotPinnedGive: CGFloat =
            heroLogoSlotHeightPinned - heroLogoSlotHeightPinnedFloor          // 110 → 78 = 32
        static let heroSynopsisSlotPinnedGive: CGFloat =
            heroSynopsisSlotHeightPinned - heroSynopsisSlotHeightPinnedFloor  // 72 → 36 = 36
        /// The pinned synopsis slot in FEAT-15's CTA-less focus panel: the carousel slot plus the
        /// CTA slot and the `md` gap that preceded it, which the panel folds in so its summed panel
        /// height stays identical to the carousel's (`HomeHeroForeground.synopsisSlotHeight` states
        /// the same arithmetic: 32 + 110 + 16 + 32 + 16 + 144 = 350 = 32 + 110 + 16 + 32 + 16 + 72
        /// + 16 + 56). Named here (BUG-87, beta.18) because the compression ceiling and the slot's
        /// own give both have to be derived from it rather than from the carousel's 72.
        static let heroSynopsisSlotHeightPinnedPanel: CGFloat =
            heroSynopsisSlotHeightPinned + heroButtonSlotHeight + Theme.Spacing.md  // 72 + 56 + 16 = 144
        /// The panel form's synopsis give against the SAME one-line floor the carousel uses:
        /// 144 → 36 = 108.
        static let heroSynopsisSlotPanelPinnedGive: CGFloat =
            heroSynopsisSlotHeightPinnedPanel - heroSynopsisSlotHeightPinnedFloor  // 144 → 36 = 108
        /// The pinned hero's frame is 2pt taller than the content it holds — 352 against
        /// `32 padding + 110 logo + 16 + 32 meta + 16 + 72 synopsis + 16 + 56 CTA = 350` (the
        /// arithmetic `HomeHeroForeground.synopsisSlotHeight` documents). That slack is real give:
        /// the frame can lose it without the content losing anything.
        static let heroPinnedFrameSlack: CGFloat = 2

        // MARK: Wave 10 / Wave G — settled rests

        /// The corrector's tolerance, in points. Comfortably above the probe's own 2pt quantization
        /// and any sub-point layout noise, which is what stops noise alone from re-triggering a
        /// rest that has already landed — see `PinnedRowSettle`'s termination contract.
        ///
        /// Wave G (BUG-87) turned the correction target from a point into a legibility BAND, and
        /// this constant now does two jobs, both of them still GATE-shaped and neither of them a
        /// subtrahend:
        ///
        ///  - **The inset inside the band.** A correction aims one dead zone in from the nearer
        ///    band edge (never past the midpoint), so a landed rest sits strictly inside the band
        ///    rather than on its boundary, where sub-point noise could push it back out. It does
        ///    NOT shorten the correction: deducting it from the magnitude made corrections stop AT
        ///    the boundary, so rests approached from opposite directions settled 4pt either side —
        ///    an 8pt spread between rows that had both "converged".
        ///  - **The idle-drift tolerance.** It is `PinnedRowSettle.pullBackTolerance`: a rest that
        ///    lands within this of the margin a correction was fired FROM counts as the focus
        ///    engine putting the row back, not as a correction that worked. It is also the slack
        ///    the end-of-content branch judges a spent scroll range by.
        ///
        /// Band MEMBERSHIP has its own, tighter ±2 slack (the probe's quantization) so that a rest
        /// reported exactly on an edge reads as inside it.
        static let heroPinnedRowSettleDeadZone: CGFloat = 4
    }
}

/// Liquid Glass for the FUNCTIONAL layer only (design spec §3.4 and gap 14): player chrome, the
/// source picker panel, and other floating controls over content. Never on content itself (posters,
/// badges, settings rows). With Reduce Transparency on it draws `Theme.Surface.opaqueFallback`
/// instead, which is the fallback the accessibility checklist (spec §10) asks every custom glass
/// surface to have.
struct FunctionalGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Theme.Surface.opaqueFallback, in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// See `FunctionalGlass`. Use instead of a bare `.glassEffect` on app-drawn floating chrome.
    func functionalGlass<S: Shape>(in shape: S) -> some View {
        modifier(FunctionalGlass(shape: shape))
    }
}

extension Color {
    /// Create a color from a 0xRRGGBB literal (sRGB), e.g. `Color(hex: 0xE53935)`.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Parse a `#RGB` / `#RRGGBB` / `#RRGGBBAA` (or unprefixed) hex string, e.g. from a shared
    /// `StreamBadge` color field. Returns nil for empty or malformed input so callers can fall back.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15.0
            g = Double((value >> 4) & 0xF) / 15.0
            b = Double(value & 0xF) / 15.0
            a = 1.0
        case 6:
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        default: // 8: AARRGGBB — see the BUG-43 note below.
            // BUG-43 (beta.12): every 8-digit hex this app parses is a CROSS-PLATFORM string
            // (badge packs, synced avatar colors) authored in the Android/Compose convention,
            // which mobile reads as AARRGGBB (`StreamBadgeChip.kt`: `8 -> hex`,
            // `6 -> "FF$hex"`). Reading RRGGBBAA here turned an opaque `#FF1A1A1A` chip
            // (dark on mobile) into a ~10%-alpha light ghost on tvOS — the "language badge
            // renders in the light theme" report — and fed garbage luminance into the BUG-28/43
            // contrast guards, which is why the guard-side fix alone never took.
            a = Double((value >> 24) & 0xFF) / 255.0
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
