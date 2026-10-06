import SwiftUI

/// Focus treatment shared by the custom control styles below (HIG revamp, see
/// docs/design/hig-hybrid-contract.md): these mimic the SYSTEM tvOS focus language — the platter
/// turns near-white and the label flips dark, with a small lift — rather than the old brand
/// accent rings. Custom `ButtonStyle`s are kept only where a system style can't express the
/// shape (capsule chips with a selected fill; full-width transparent rows pending the Settings
/// List conversion). Everything else should use `.borderless` / `.card` / `.glass` /
/// `.bordered` directly.
private enum FocusLook {
    /// System focus platter color (near-white, as `.bordered`/`.card` render it).
    static let platter = Color.white
    /// Label color on the focused platter.
    static let onPlatter = Color.black.opacity(0.85)
    static let liftScale: CGFloat = 1.05
    static let pressScale: CGFloat = 0.97
    static let anim = Animation.easeOut(duration: 0.15)
    static let pressAnim = Animation.easeOut(duration: 0.12)
    /// Soft shadow under a lifted (focused) control — reads as elevation, not glow.
    static func liftShadow(_ isFocused: Bool) -> Color { .black.opacity(isFocused ? 0.45 : 0) }
    /// VIS-03: resting fill of an unselected chip — the translucent platter system `.bordered`
    /// buttons show at rest.
    static let restingFill = Color.white.opacity(0.1)
    /// VIS-03: resting fill of a SELECTED chip. A brighter neutral platter plus a semibold label,
    /// never the brand accent (design spec §2.6 and §3.4: the accent is for progress, the unwatched
    /// dot and selected-state glyphs, not button fills). Selection is carried by two cues, the
    /// platter's brightness and the label's weight, so it is never colour alone.
    static let selectedFill = Color.white.opacity(0.3)
}

/// BUG-65 (beta.13, u/mrStevenx3's review video t=133.5): ON DEVICE, a focused `.settingsRow`
/// button can render its white focus platter while the env-keyed label modifiers
/// (`RowTextColor`/`RowAccentTint`) still paint the at-rest light colors — white-on-white.
/// The tvOS 26.5 SIM does NOT reproduce this (test36 measured the row rendering correctly
/// before and after any fix, byte-identical), so the sim cannot adjudicate which env read dies
/// on the device. Fix strategy is therefore belt-and-braces via a signal that IS device-proven:
/// the row views (`SettingsToggleRow` & co.) hold their own `@FocusState` — the mechanism
/// BUG-45's device-verified sidebar fix already relies on — and publish it through this key;
/// the style body and the label modifiers treat `\.isFocused` OR this key as focus. In the sim
/// both signals agree and rendering is unchanged; on a device where the env read dies, the
/// published FocusState still flips the text dark.
private struct SettingsRowIsFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsRowIsFocused: Bool {
        get { self[SettingsRowIsFocusedKey.self] }
        set { self[SettingsRowIsFocusedKey.self] = newValue }
    }
}

/// BUG-65, container half (u/mrStevenx3's device video 2026-08-29, frames 3:38/3:56 — the Home
/// Screen pane's two collapsible groups). A custom container — a `VStack` of focusable rows —
/// placed in a tvOS `List` is ONE list row, and the system paints that row's near-white focus
/// platter whenever the row CONTAINS focus. So the whole group turns white, and EVERY child sits
/// on the platter, not just the focused one. The video pins exactly which children survive that:
/// content that is a control's LABEL (`SettingsRowLabel` inside a `Toggle`/`Button`) gets the
/// system's label inversion and reads dark-on-white, while content that is merely free-standing
/// inside the cell — the plain `Text`s and the `.chip` glyphs of `CatalogSettingRow` — keeps the
/// app's dark-scheme `.primary`/`.secondary` and vanishes. Only the accent-tinted state circles
/// stayed visible, which is what made the row look "completely blank".
///
/// This is deliberately a SECOND key rather than a wider publication of `settingsRowIsFocused`.
/// That key means "this control has focus", and `SettingsRowButtonStyle`/`ChipButtonStyle` render
/// the full focus treatment from it (white capsule, lift, shadow) — publishing it container-wide
/// would draw every sibling chip as though it were the focused one. `settingsRowPlatterActive`
/// carries strictly less: "the surface under this content is the near-white platter". Consumers
/// use it to pick platter-safe colours, never to fake focus.
///
/// Published by the container that owns the focus state (`HeroSourcesGroup`/`HomeCatalogsGroup`),
/// derived from a `@FocusState` its children bind — the same device-proven mechanism as the key
/// above, because `\.isFocused` is the read that dies on hardware. Defaults false, so every screen
/// that does not publish it renders byte-identically.
private struct SettingsRowPlatterActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsRowPlatterActive: Bool {
        get { self[SettingsRowPlatterActiveKey.self] }
        set { self[SettingsRowPlatterActiveKey.self] = newValue }
    }
}

/// Full-width text row style used by Settings (pending the native List conversion) and a few
/// content rows. Transparent at rest; focused it renders the system look: near-white platter,
/// dark label, slight lift.
struct SettingsRowButtonStyle: ButtonStyle {
    /// Fill behind the label while NOT focused. Clear by default (every existing call site); the
    /// stream picker's rows pass `Theme.Palette.restingRowFill` so unfocused rows read as separate
    /// cards over the artwork (AES-3). Focus always replaces it with the white platter — the
    /// focused look (and its BUG-65 label flip) is unchanged.
    var restingFill: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, restingFill: restingFill)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let restingFill: Color
        @Environment(\.isFocused) private var isFocused
        // BUG-65: rows that carry their own `@FocusState` (SettingsToggleRow & co.) publish it
        // through this key; the style treats either signal as focus — see the key's doc above.
        @Environment(\.settingsRowIsFocused) private var externalFocus

        private var focused: Bool { isFocused || externalFocus }

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? FocusLook.onPlatter : Theme.Palette.textPrimary)
                // The label's own semantic colors (.primary/.secondary — e.g. subtitles, stream
                // metadata) don't inherit the foregroundStyle above; flipping the scheme makes
                // them resolve dark on the white focus platter (device feedback: light-on-white
                // text in the stream picker / settings rows was illegible).
                .environment(\.colorScheme, focused ? .light : .dark)
                // BUG-65: see SettingsRowIsFocusedKey above.
                .environment(\.settingsRowIsFocused, focused)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(focused ? FocusLook.platter : restingFill)
                )
                .shadow(color: FocusLook.liftShadow(focused), radius: 16, y: 8)
                .scaleEffect(focused ? 1.02 : 1)
                .scaleEffect(configuration.isPressed ? FocusLook.pressScale : 1)
                .animation(FocusLook.anim, value: focused)
                .animation(FocusLook.pressAnim, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == SettingsRowButtonStyle {
    /// Platter-free-at-rest style for full-width text rows (system-look focus).
    static var settingsRow: SettingsRowButtonStyle { .init() }
    /// `.settingsRow` with a resting fill (the stream picker's rows) — same focus treatment.
    static func settingsRow(restingFill: Color) -> SettingsRowButtonStyle { .init(restingFill: restingFill) }
}

/// Capsule chip. System focus language: grey platter at rest, near-white platter + dark label
/// while focused, small lift — the same look as a system `.bordered` capsule button.
///
/// VIS-03: kept as a custom style only for its BUG-65 machinery (focus published through
/// `settingsRowIsFocused`, the container-platter case). New code should use `.bordered` with
/// `.buttonBorderShape(.capsule)`. Selection no longer paints the brand accent: a selected chip
/// rests on a brighter neutral platter with a semibold label (see `FocusLook.selectedFill`), and
/// focus overrides it with the white platter, the way native tvOS pickers treat a focused
/// selected item.
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.settingsRowIsFocused) private var externalFocus
        // BUG-65 container half: this chip can be sitting on a near-white platter that a SIBLING's
        // focus put up (see SettingsRowPlatterActiveKey) — the reorder chevrons in the Home Screen
        // pane's catalog group are exactly that case, and on device they disappeared outright.
        @Environment(\.settingsRowPlatterActive) private var platterActive

        private var focused: Bool { isFocused || externalFocus }

        /// Anything drawn against the near-white platter — this chip's own, or the container's.
        private var onPlatter: Bool { focused || platterActive }

        private var fill: Color {
            if focused { return FocusLook.platter }
            if selected { return platterActive ? Color.black.opacity(0.2) : FocusLook.selectedFill }
            // At rest on a container platter the 10%-white pill is invisible against the platter it
            // sits on; the same 10% the other way round reads as a light-grey pill on white, and
            // keeps the focused chip (a FULL-white platter, plus lift and shadow) distinguishable
            // from its unfocused neighbours.
            if platterActive { return Color.black.opacity(0.1) }
            return FocusLook.restingFill
        }

        private var labelColor: Color {
            if focused { return FocusLook.onPlatter }
            return Theme.Palette.textPrimary
        }

        var body: some View {
            configuration.label
                .foregroundStyle(labelColor)
                // VIS-03: the second selection cue (the first is the brighter platter).
                .fontWeight(selected ? .semibold : nil)
                // Same semantic-color flip as SettingsRowButtonStyle — chip labels with their own
                // .secondary text stay legible on the white focus platter. `onPlatter`, not
                // `focused`: an unfocused chip on a container platter forced .dark here, which is
                // what turned `labelColor`'s semantic `textPrimary` into white-on-white (device
                // video 3:38 — the catalog rows' up/down chevrons were simply not there).
                .environment(\.colorScheme, onPlatter ? .light : .dark)
                // BUG-65: same custom-ButtonStyle label env gap as SettingsRowButtonStyle —
                // `chipMetaText` inside chip labels needs the style's known-good focus value.
                .environment(\.settingsRowIsFocused, focused)
                .frame(minWidth: 40, minHeight: 40)
                .background(Capsule().fill(fill))
                .shadow(color: FocusLook.liftShadow(focused), radius: 16, y: 8)
                .scaleEffect(focused ? FocusLook.liftScale : 1)
                .scaleEffect(configuration.isPressed ? FocusLook.pressScale : 1)
                .animation(FocusLook.anim, value: focused)
                .animation(FocusLook.pressAnim, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    /// Capsule chip with no selection state.
    static var chip: ChipButtonStyle { .init() }
    /// Chip that fills with the theme accent when selected (at rest; focus overrides).
    static func chip(selected: Bool) -> ChipButtonStyle { .init(selected: selected) }
}

/// Subtitle/meta text inside a `.chip`-styled button (e.g. a catalog chip's addon-name line,
/// BUG-33 defect 3). A bare `.foregroundStyle(Theme.Palette.textSecondary)` on that text ignores
/// both the chip's fill and its focus state — `Color.secondary` resolves as a flat mid-grey once
/// `ChipButtonStyle` forces the `colorScheme` to `.light` on focus, measured at 1.52:1 against the
/// near-white focused platter (worse than the 2.23:1 it measured unfocused, where it can also sit
/// on a near-white "White"-theme accent fill). Anchor to the SAME tokens `ChipButtonStyle`'s own
/// `labelColor` already resolves correctly (`onPlatter` focused, `accentText` on a selected
/// accent fill, `textPrimary` otherwise) and only dim opacity for hierarchy when unfocused —
/// focused always gets the full-contrast token, undimmed, so the chip reads at 10 feet.
struct ChipMetaText: ViewModifier {
    var selected = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused

    // BUG-65: `\.isFocused` alone can die inside a custom ButtonStyle's label on device —
    // OR in the style-published value (see SettingsRowIsFocusedKey).
    private var effectiveFocus: Bool { isFocused || rowFocused }

    private var color: Color {
        if effectiveFocus { return FocusLook.onPlatter }
        // VIS-03: a selected chip rests on a neutral platter now, not the accent, so its meta
        // line uses the same primary token as an unselected one.
        return Theme.Palette.textPrimary
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(color.opacity(effectiveFocus ? 1 : 0.7))
    }
}

extension View {
    /// Focus- and selection-aware subtitle/meta text inside a `.chip`-styled button. Use instead
    /// of a bare `.foregroundStyle(Theme.Palette.textSecondary)`/`.secondary`, which does not
    /// survive the chip's focus platter or a light accent fill (BUG-33).
    func chipMetaText(selected: Bool = false) -> some View {
        modifier(ChipMetaText(selected: selected))
    }
}

/// Label color for accent-tinted `.borderedProminent` buttons. tvOS swaps the prominent platter to
/// a near-white "lifted" fill on focus regardless of tint, so no fixed label color works: focused
/// needs dark text, unfocused needs the accent's contrast color (`Theme.Palette.accentText`). An
/// explicit `foregroundStyle` would disable the system's automatic label flip — this restores it.
struct ProminentAccentLabel: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.foregroundStyle(isFocused ? Color(hex: 0x0D0D0D) : Theme.Palette.accentText)
    }
}

extension View {
    /// Apply to the label of an accent-tinted `.borderedProminent` button.
    func prominentAccentLabel() -> some View { modifier(ProminentAccentLabel()) }
}

/// legacy — used by non-Settings screens pending their own native-List pass (beta.16 candidate).
///
/// Focus-aware title/subtitle/value text colour for content inside `.settingsRow`-styled buttons
/// (the BUG-4/14/22/28/33 white-on-white class; BUG-65 added the `settingsRowIsFocused` OR-in for
/// devices where `\.isFocused` dies inside the custom style). Moved here from the Settings kit
/// (`SettingsRowViews.swift`) in beta.15 task C4: the Settings screen's own rows are all stock
/// controls now and the system flips their label colour itself, so this survives only for the
/// five screens still on `.settingsRow` buttons — `StreamPickerView`, `DetailView`,
/// `CloudLibraryUI`, `AddonsView`, `TmdbFilterEditorView`. Do not reach for it in new code.
struct RowTextColor: ViewModifier {
    var secondary = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused

    func body(content: Content) -> some View {
        content.foregroundStyle(
            (isFocused || rowFocused)
                ? Theme.Palette.onFocusPlatter.opacity(secondary ? 0.7 : 1)
                : (secondary ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
        )
    }
}

extension View {
    /// legacy — used by non-Settings screens pending their own native-List pass (beta.16
    /// candidate). See `RowTextColor`.
    func rowTextColor(secondary: Bool = false) -> some View {
        modifier(RowTextColor(secondary: secondary))
    }
}

/// Accent tint for icons/labels that sit INSIDE a focusable row or chip (BUG-22). The row
/// styles above flip their platter to near-white on focus and rely on semantic colors flipping
/// with the forced light `colorScheme` — but an explicit `Theme.Palette.accent` bypasses that,
/// and the White theme's accent (~#F5F5F5) disappears on the white platter (state checkmarks,
/// row icons, the sidebar's selected category — the reporter's "white-on-white settings").
/// At rest the accent applies (when active) or [inactiveColor] (when not); on focus the content
/// ALWAYS joins the platter's dark label color, regardless of `active` — BUG-45: the previous
/// version only forced `onPlatter` inside the `active` branch, so a focused-but-inactive row
/// (an unchecked toggle icon, a sidebar row focused a frame before `active` catches up to the
/// focus change) fell through to [inactiveColor], which is not guaranteed safe on the white
/// platter (e.g. the default `textSecondary` resolves as a flat mid-grey under the forced light
/// `colorScheme`). Focus must win outright so every call site is platter-safe unconditionally.
struct RowAccentTint: ViewModifier {
    /// When false and NOT focused, the content shows [inactiveColor] instead of the accent (e.g.
    /// an unchecked state circle) — pass a SEMANTIC color so the row's colorScheme flip keeps it
    /// legible. Ignored while focused: the platter-safe color always wins then.
    var active = true
    var inactiveColor: Color = Theme.Palette.textSecondary
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive

    private var color: Color {
        // BUG-65: OR in the style-published focus value — see SettingsRowIsFocusedKey.
        if isFocused || rowFocused { return FocusLook.onPlatter }
        // BUG-65 container half: unfocused, but on a platter a sibling's focus put up. The accent
        // is the one colour this modifier exists to keep OFF the platter — the White theme's
        // ~#F5F5F5 accent is invisible on it, which is the original BUG-22 report. The state
        // circles in the Home Screen pane's catalog group were the only thing still visible in the
        // device video precisely BECAUSE that theme's accent happened to be blue; on the White
        // theme the row would have had nothing at all. Dark-vs-dimmed keeps the enabled/disabled
        // distinction the accent was carrying, and the glyph shape carries it too.
        if platterActive { return active ? FocusLook.onPlatter : inactiveColor }
        return active ? Theme.Palette.accent : inactiveColor
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }
}

extension View {
    /// Focus-aware accent for content inside `.settingsRow`/`.chip`-styled buttons — see
    /// [RowAccentTint]. Never use a bare `Theme.Palette.accent` inside those rows.
    func rowAccentTint(_ active: Bool = true, inactiveColor: Color = Theme.Palette.textSecondary) -> some View {
        modifier(RowAccentTint(active: active, inactiveColor: inactiveColor))
    }
}
