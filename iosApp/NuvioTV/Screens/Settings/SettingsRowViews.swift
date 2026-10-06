import SwiftUI
import SharedCore

// MARK: - Settings component kit (beta.15 §C, task C1)
//
// Every primitive below is a STOCK SwiftUI control that a native `List` styles for us — the C0
// spike (`SettingsKitPreview.swift`, commit 8c375436) proved tvOS 26's `List` renders the
// Settings.app look with zero custom chrome. Nothing here declares a `ButtonStyle`, a
// `hoverEffect`, a focus platter, or a focus-derived colour: the system draws the platter and
// flips the label colour scheme itself, which is exactly what the BUG-4/14/22/28/33/45/65
// white-on-white family of bugs came from hand-rolling.
//
// Colour rule: semantic only (`.primary` by inheritance, `.secondary` for subtitles/values).
// Never `Theme.Palette.textPrimary`-on-a-platter, never `onFocusPlatter`.
//
// Type scale (HIG 10-foot table, nothing under 23):
//   row title    → Body 29      (`Theme.Font.body`)
//   row subtitle → Caption1 25  (`Theme.Font.meta`)
//   section head → Caption2 23  (`Theme.Font.caption`)
//
// C4 (cleanup after C1-C3): the seven `*SettingsPane` files are fully converted now, so every
// legacy value+action shim, `SettingsInfoRow`, and `LanguageSelectRow` — all unreferenced once C3
// landed — are deleted from this file. The legacy focus-aware text-colour modifier moved to
// DesignSystem/FlatControlStyles.swift, since five non-Settings screens still draw the legacy
// full-width row button style and need it; those screens are out of this beta's scope.
// `settingsSection` survives here because `TmdbFilterEditorView` (also out of scope) still calls
// it.

/// The three type-scale tokens the kit uses, named by role so a future scale change is one edit.
/// All three resolve to `Theme.Font` semantic tokens — no `Font.system(size:)` anywhere (HIG
/// hybrid contract, Typography row).
enum SettingsRowFont {
    /// Row titles — Body 29.
    static let title = Theme.Font.body
    /// Row subtitles / trailing values — Caption1 25.
    static let subtitle = Theme.Font.meta
    /// Section headers and footers — Caption2 23.
    static let sectionHeader = Theme.Font.caption
}

// MARK: - Accent

/// How a row's leading SF Symbol is coloured.
enum SettingsRowIconTint {
    /// `.secondary` at rest, `.primary` on the platter — the tvOS Settings look. The default:
    /// spec §2.6 / §3.4 keep the brand accent for progress, the unwatched dot and selection marks.
    case neutral
    /// The theme accent while the row is at rest — only for a real selected-state glyph.
    case accent
    /// Inherit whatever the row already paints — used by `SettingsDestructiveRow`, whose system
    /// red must not be overridden by the accent.
    case inherit
}

/// Focus-aware theme accent for the two places the Settings kit is allowed to carry colour: a
/// row's leading glyph and an interactive row's trailing value.
///
/// The colour rule below still holds — this NEVER paints a fixed colour onto the focus platter.
/// At rest the element carries `Theme.Palette.accent`; focused, it hands the colour back to
/// `.primary` so the system's own light/dark label flip on the near-white platter applies. Pinning
/// the accent through focus is the BUG-4/33/45/65 family, and the White theme's near-white accent
/// (0xF5F5F5) would disappear into the platter outright.
///
/// BUG-65 container half: `\.isFocused` alone is not enough for a kit row hosted inside a CUSTOM
/// container (the Home Screen pane's collapsible groups) — that container is a single tvOS list
/// row, so its near-white platter is up whenever ANY of its children has focus, and an at-rest
/// accent then sits on white. `settingsRowPlatterActive` reports that; `settingsRowIsFocused`
/// reports the row's own device-proven `@FocusState`. Both default false, so the sidebar and the
/// six panes that publish neither are unchanged.
///
/// The `colorScheme` write-back is what makes handing the colour to `.primary` safe in those
/// containers: on a native list row the system flips the row's label appearance itself, but a
/// custom container's children never got that flip, so `.primary` resolved to the app's dark-mode
/// white — the failure this modifier is supposed to prevent. Writing the INHERITED value back in
/// the at-rest case (rather than a literal `.dark`) keeps it a true no-op: it can never clobber a
/// flip the system already performed.
struct SettingsAccentTint: ViewModifier {
    /// Wave 2 review: `false` (the default) is the neutral `.secondary` resting colour every
    /// glyph and value now uses; `true` keeps the accent for genuine selection marks only.
    var selectionAccent: Bool = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    @Environment(\.colorScheme) private var inheritedScheme

    private var onPlatter: Bool { isFocused || rowFocused || platterActive }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                onPlatter
                    ? AnyShapeStyle(.primary)
                    : (selectionAccent ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(.secondary))
            )
            .environment(\.colorScheme, onPlatter ? .light : inheritedScheme)
    }
}

extension View {
    /// Internal, not private: `SettingsView`'s sidebar builds its own `Label` rather than going
    /// through `SettingsRowLabel`, and its icon column is the most visible place the theme shows.
    func settingsAccentTint() -> some View { modifier(SettingsAccentTint()) }

    /// The accent variant, for a selected-state glyph (an "Active" checkmark) — never for plain
    /// row icons or values.
    func settingsSelectionAccentTint() -> some View { modifier(SettingsAccentTint(selectionAccent: true)) }
}

// MARK: - Shared row label

/// The title (+ optional subtitle, + optional SF Symbol) block every kit row puts on its leading
/// side. Deliberately sets NO foreground colour on the title: it inherits the list row's label
/// colour, which the system inverts on the focus platter for free. The GLYPH is `.secondary` at
/// rest through `SettingsAccentTint` (wave 2: monochrome like tvOS Settings; `iconTint: .accent`
/// is kept for a real selected-state glyph).
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var iconTint: SettingsRowIconTint = .neutral

    /// BUG-65 container half. In a native list row this stays false and the block below is a
    /// no-op — the system inverts the row's label colour and the kit's colour rule holds as
    /// written. Inside a CUSTOM container (the Home Screen pane's collapsible groups) the
    /// container is one list row whose platter is up whenever any child has focus, and its
    /// children never got that inversion, so `.primary`/`.secondary` resolved white-on-white.
    /// See `settingsRowPlatterActive` / `settingsRowIsFocused` in FlatControlStyles.swift.
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.settingsRowPlatterActive) private var platterActive
    /// Written straight back when the platter is down, so this can never clobber a `colorScheme`
    /// flip the system already applied to a native row — the over-correction the kit's header
    /// comment warns about. Nothing here pins a fixed colour onto the platter either: the label
    /// stays semantic and only the SCHEME it resolves against changes.
    @Environment(\.colorScheme) private var inheritedScheme

    private var onPlatter: Bool { rowFocused || platterActive }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let systemImage {
                switch iconTint {
                case .neutral:
                    Image(systemName: systemImage)
                        .font(SettingsRowFont.title)
                        .settingsAccentTint()
                case .accent:
                    Image(systemName: systemImage)
                        .font(SettingsRowFont.title)
                        .settingsSelectionAccentTint()
                case .inherit:
                    Image(systemName: systemImage)
                        .font(SettingsRowFont.title)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(SettingsRowFont.title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .environment(\.colorScheme, onPlatter ? .light : inheritedScheme)
    }
}

// MARK: - Section

/// One grouped block of rows inside a settings `List` — a stock `Section` with a Caption2 header
/// and an optional Caption2 footer. Use inside a `List` only (that is where `Section` earns its
/// native header/footer treatment).
struct SettingsSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    /// Unlabelled convenience so a call reads `SettingsSection("Playback") { … }`.
    init(_ title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, content: content)
    }

    var body: some View {
        Section {
            content
        } header: {
            if let title, !title.isEmpty {
                Text(title)
                    .font(SettingsRowFont.sectionHeader)
                    // The focused row's platter scales up past the row bounds and was covering the
                    // header at the stock distance (device pass 2026-08-28: "Account" clipped behind
                    // the focused Sign Out row). `sm` of extra bottom padding keeps the header clear
                    // of the platter without visibly loosening the section rhythm.
                    .padding(.bottom, Theme.Spacing.sm)
            }
        } footer: {
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(SettingsRowFont.sectionHeader)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Set on the settings detail `List` (task C2) so the transitional `settingsSection(_:)` helper
/// below knows it is inside a native list and can emit a real `Section`. Default `false` keeps
/// every other caller — notably `TmdbFilterEditorView`, which stacks the same helper inside a
/// plain `ScrollView`/`VStack` and is NOT part of the Settings conversion — on the pre-C1
/// hand-rolled layout, byte-for-byte.
private struct SettingsUsesNativeListKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsUsesNativeList: Bool {
        get { self[SettingsUsesNativeListKey.self] }
        set { self[SettingsUsesNativeListKey.self] = newValue }
    }
}

/// LEGACY SHIM (C3) — the free function every `*SettingsPane` (and `TmdbFilterEditorView`) still
/// calls. Inside the settings detail `List` it becomes a native `SettingsSection`; anywhere else
/// it keeps the old title + `.focusSection()` stack so unconverted screens are untouched.
/// C3 replaces the pane call sites with `SettingsSection`; C4 deletes this once
/// `TmdbFilterEditorView` has its own copy or is converted too.
func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    LegacySettingsSection(title: title, content: content())
}

private struct LegacySettingsSection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.settingsUsesNativeList) private var usesNativeList

    var body: some View {
        if usesNativeList {
            SettingsSection(title: title) { content }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                content
            }
            .focusSection()
        }
    }
}

// MARK: - Toggle

/// A real `Toggle` — system switch, system platter, system label inversion, VoiceOver state for
/// free. Replaces the `checkmark.circle.fill` glyph fake.
struct SettingsToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let isOn: Binding<Bool>

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
    }

    var body: some View {
        Toggle(isOn: isOn) {
            SettingsRowLabel(title: title, subtitle: subtitle)
        }
        // Kept from the pre-C1 row: the UITest harness's state-aware toggle helper reads this
        // exact value (beta.13 wave 2), and it is a friendlier VoiceOver value than "1"/"0".
        .accessibilityValue(isOn.wrappedValue ? Text("On") : Text("Off"))
    }
}

// MARK: - Picker

/// A choice row: `Menu { Picker }` over a `LabeledContent` label — the native grey pill that pops
/// the system radio-checkmark popover (C0-proven). Replaces the horizontal chip rows.
struct SettingsPickerRow<T: Hashable>: View {
    let title: String
    var subtitle: String?
    let selection: Binding<T>
    let options: [T]
    let label: (T) -> String

    init(
        title: String,
        subtitle: String? = nil,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
        } label: {
            LabeledContent {
                Text(label(selection.wrappedValue))
                    .font(SettingsRowFont.title)
                    // The value the user actually picked — `.secondary` at rest (wave 2: no
                    // accent on plain values), platter-flipped when this row has focus.
                    .settingsAccentTint()
            } label: {
                SettingsRowLabel(title: title, subtitle: subtitle)
            }
        }
    }
}

// MARK: - Value

/// A read-only title/value row — stock `LabeledContent`. Not focusable by design (HIG: static
/// content does not take focus); every pane that uses it also carries at least one focusable row,
/// which is the BUG-47 requirement.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var subtitle: String?
    var systemImage: String?

    init(title: String, value: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .font(SettingsRowFont.title)
                .foregroundStyle(.secondary)
        } label: {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
    }
}

// MARK: - Link

/// A pushed sub-page row — stock `NavigationLink` inside the settings `NavigationStack`. Menu on
/// the pushed page pops exactly one level, back to this list.
struct SettingsLinkRow<Destination: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder let destination: () -> Destination

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
    }
}

// MARK: - Action

/// A plain `Button` in default list-row style: no `ButtonStyle`, no chevron glyph (the system
/// draws the row treatment). `systemImage` is optional and only kept because pre-C3 panes pass it.
struct SettingsActionRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    let action: () -> Void

    init(
        title: String,
        subtitle: String = "",
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle.isEmpty ? nil : subtitle
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
    }
}

/// Destructive variant — `Button(role: .destructive)`, so the system paints it red and VoiceOver
/// announces it. Pair with the screen's `.alert` confirmation (SettingsView already owns those).
struct SettingsDestructiveRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    let action: () -> Void

    init(
        title: String,
        subtitle: String = "",
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle.isEmpty ? nil : subtitle
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            // `.inherit`: the destructive red is the row's whole point (HIG), and it stays red
            // under every theme. An accent glyph here would fight it.
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, iconTint: .inherit)
        }
    }
}

// MARK: - Key entry

/// Manual API-key entry row (debrid fallback, MDBList, and similar key-gated services). Shared
/// between the Account & Services pane's per-provider debrid rows and the Content Sources pane's
/// MDBList row. C1: the hand-rolled `glassEffect` capsule around the field is gone — inside a
/// native `List` the row already has the system's own background and focus treatment, and glass
/// belongs to floating chrome (HIG hybrid contract, Overlay surfaces).
struct DebridKeyEntryRow: View {
    let providerName: String
    var placeholder: String?
    /// DEB-2: false when the caller checks the key asynchronously before saving it — the typed key
    /// then stays in the field (a rejected key can be corrected) and the row disappears on its own
    /// once the key is saved.
    var clearsOnSave: Bool = true
    /// DEB-2: the key is being checked with the provider.
    var isValidating: Bool = false
    /// DEB-2: why the last key was not saved.
    var errorMessage: String?
    let onSave: (String) -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "key")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField(placeholder ?? String(localized: "Or paste your \(providerName) API key"), text: $key)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
            }

            Button {
                if !key.isEmpty {
                    onSave(key)
                    if clearsOnSave { key = "" }
                }
            } label: {
                if isValidating {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                        Text("Checking the key\u{2026}")
                            .font(SettingsRowFont.subtitle)
                    }
                } else {
                    Label("Save Key", systemImage: "checkmark")
                        .font(SettingsRowFont.subtitle)
                }
            }
            // Not disabled while checking: disabling the focused row would throw focus elsewhere
            // (see SimklSyncNowRow); the view model ignores a second press instead.
            .disabled(key.isEmpty)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Legacy support (deleted in C4 once nothing references it)
//
// The legacy focus-aware text-colour modifier moved out to DesignSystem/FlatControlStyles.swift
// in C4 — it is still used by five non-Settings screens (`StreamPickerView`, `DetailView`,
// `CloudLibraryUI`, `AddonsView`, `TmdbFilterEditorView`) that draw the legacy full-width row
// button style, so it belongs next to `SettingsRowButtonStyle`/`RowAccentTint` rather than in the
// Settings kit, which no longer uses it anywhere.

/// Language options for the audio/subtitle preference pickers. Special sentinels (`device`,
/// `original`, `none`) match the shared `AudioLanguageOption`/`SubtitleLanguageOption` constants;
/// labels are local since the shared label table lives in the mobile module. Shared between the
/// Playback pane (Audio & Subtitle Language) and the Content Sources pane (TMDB Metadata Language).
enum LanguageOptions {
    static let languages: [(name: String, code: String)] = [
        (String(localized: "English"), "en"), (String(localized: "Spanish"), "es"),
        (String(localized: "French"), "fr"), (String(localized: "German"), "de"),
        (String(localized: "Italian"), "it"), (String(localized: "Portuguese"), "pt"),
        (String(localized: "Japanese"), "ja"), (String(localized: "Korean"), "ko"),
        (String(localized: "Chinese"), "zh"), (String(localized: "Russian"), "ru"),
        (String(localized: "Hindi"), "hi"), (String(localized: "Arabic"), "ar"),
        // FEAT-19 (beta.12): rode along with the Vietnamese UI localization so vi is also
        // selectable for TMDB metadata and audio/subtitle track preference.
        (String(localized: "Vietnamese"), "vi")
    ]
    static var audio: [(name: String, code: String)] {
        [(String(localized: "Device"), "device"), (String(localized: "Original"), "original")] + languages
    }
    static var subtitle: [(name: String, code: String)] {
        [(String(localized: "Off"), "none"), (String(localized: "Device"), "device")] + languages
    }
    /// TMDB metadata language: Device = no stored language (the shared repo derives it from the
    /// Apple TV's language). TMDB accepts the same bare ISO 639-1 codes the track pickers use.
    static var tmdbMetadata: [(name: String, code: String)] {
        [(String(localized: "Device"), "device")] + languages
    }

    /// Label lookup for the `SettingsPickerRow` conversions C3 does — the picker stores the code
    /// and needs the display name back.
    static func name(forCode code: String, in options: [(name: String, code: String)]) -> String {
        options.first { $0.code == code }?.name ?? code
    }

    // MARK: Track languages (LANG-11)

    /// Every language the shared track matcher knows (`AvailableLanguageOptionCodes`, the same list
    /// the phone's pickers offer, kept identical by composeApp's `PlayerLanguageOptionsParityTest`),
    /// as the codes the shared settings store: `PlayerSettingsRepository` saves
    /// `normalizeLanguageCode` output, which is lower-case ("pt-br", "es-419", "zh-tw"). Named in
    /// the app's UI language and sorted by that name, so a pt-BR preference synced from the phone
    /// reads "Portuguese (Brazil)" / "Portugais (Brésil)" instead of the raw "pt-br".
    static let trackLanguages: [(name: String, code: String)] = PlayerLanguageOptionCodesKt.AvailableLanguageOptionCodes
        .map { (name: LanguageOptions.trackLanguageName($0), code: $0.lowercased()) }
        .sorted { $0.name.compare($1.name, locale: LanguageOptions.uiLocale) == .orderedAscending }

    /// Sentinels shared with `AudioLanguageOption` / `SubtitleLanguageOption` (shared Kotlin).
    static let audioDefaultCode = "default"
    static let subtitleForcedCode = "forced"
    /// Picker value for "no secondary language" (the shared setting is `nil`).
    static let noSecondaryCode = ""

    /// Preferred audio: File Default, Device, Original, then every track language.
    static func preferredAudioCodes(including current: String) -> [String] {
        withCurrent([audioDefaultCode, "device", "original"] + trackLanguages.map(\.code), current)
    }

    /// Secondary audio: None, Original, then every track language (the phone's list).
    static func secondaryAudioCodes(including current: String) -> [String] {
        withCurrent([noSecondaryCode, "original"] + trackLanguages.map(\.code), current)
    }

    /// Preferred subtitles: Off, Device, Forced, then every track language.
    static func preferredSubtitleCodes(including current: String) -> [String] {
        withCurrent(["none", "device", subtitleForcedCode] + trackLanguages.map(\.code), current)
    }

    /// Secondary subtitles: None, Forced, then every track language (the phone's list).
    static func secondarySubtitleCodes(including current: String) -> [String] {
        withCurrent([noSecondaryCode, subtitleForcedCode] + trackLanguages.map(\.code), current)
    }

    /// Display name for any value the four track-language pickers can hold.
    static func trackLabel(_ code: String) -> String {
        switch code {
        case noSecondaryCode: return String(localized: "None")
        case audioDefaultCode:
            return String(localized: "settings.language.fileDefault", defaultValue: "File Default", comment: "Preferred audio option: keep the track the video file marks as default")
        case "device": return String(localized: "Device")
        case "original": return String(localized: "Original")
        case "none": return String(localized: "Off")
        case subtitleForcedCode:
            return String(localized: "settings.language.forced", defaultValue: "Forced Subtitles", comment: "Subtitle language option: only the forced track (signs and foreign dialogue)")
        default:
            return trackLanguages.first { $0.code == code.lowercased() }?.name ?? trackLanguageName(code)
        }
    }

    /// The UI language the app is actually running in (not the device region), so language names
    /// match the surrounding strings.
    private static var uiLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// "pt-br" → "Portuguese (Brazil)", "es-419" → "Spanish (Latin America)". Falls back to the
    /// code itself when the system has no name for it.
    private static func trackLanguageName(_ code: String) -> String {
        let tag = canonicalTag(code)
        let locale = uiLocale
        guard let name = locale.localizedString(forIdentifier: tag), !name.isEmpty else { return code }
        // Several languages (French among them) write language names in lower case; a picker row
        // starts with a capital everywhere else in Settings.
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// BCP 47 casing for a stored lower-case code: "pt-br" → "pt-BR", "zh-tw" → "zh-TW".
    private static func canonicalTag(_ code: String) -> String {
        let parts = code.split(separator: "-").map(String.init)
        guard let primary = parts.first else { return code }
        let rest = parts.dropFirst().map { $0.count == 2 ? $0.uppercased() : $0 }
        return ([primary.lowercased()] + rest).joined(separator: "-")
    }

    /// A picker needs its selection among its options: a value synced from another device that is
    /// not in the list (an older build's code, say) is appended so it still shows and stays put.
    private static func withCurrent(_ options: [String], _ current: String) -> [String] {
        options.contains(current) ? options : options + [current]
    }
}
