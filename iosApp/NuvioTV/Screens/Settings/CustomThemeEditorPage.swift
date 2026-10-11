import SwiftUI

/// Custom accent editor, pushed from Appearance > Theme > Custom Color.
///
/// Apple TV has no colour well and typing is costly, so the page offers three ways in, all on the
/// remote: a row of preset swatches, hue / saturation / brightness menus, and a hex field for an
/// exact value. Nothing is applied while the user explores - "Use This Color" commits - because
/// applying re-identifies the whole app root (see `AppThemeModel`) and would pop this page under
/// them mid-edit. After committing, the rebuilt Appearance pane hands focus back to the Custom swatch.
struct CustomThemeEditorPage: View {
    /// Called with `#RRGGBB` when the user commits.
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rgb: UInt32
    @State private var hexText: String
    @State private var hexInvalid = false

    init(initialHex: String, onApply: @escaping (String) -> Void) {
        let start = CustomAccentColor.parse(hex: initialHex) ?? 0xEC70A9
        self.onApply = onApply
        _rgb = State(initialValue: start)
        _hexText = State(initialValue: CustomAccentColor.hexString(start))
    }

    private var snapped: CustomAccentColor.HSB { CustomAccentColor.snappedHSB(fromRGB: rgb) }

    var body: some View {
        List {
            SettingsSection(String(localized: "Preview")) {
                LabeledContent {
                    Circle()
                        .fill(Color(hex: rgb))
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                } label: {
                    SettingsRowLabel(
                        title: String(localized: "Accent Color"),
                        subtitle: CustomAccentColor.hexString(rgb)
                    )
                }
                .accessibilityElement(children: .combine)
            }

            SettingsSection(
                String(localized: "Presets"),
                footer: String(localized: "Pick a starting point, then fine-tune it below.")
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(CustomAccentColor.presets, id: \.self) { preset in
                            Button {
                                rgb = preset
                            } label: {
                                PresetSwatch(rgb: preset, isSelected: preset == rgb)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(CustomAccentColor.hexString(preset)))
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }

            SettingsSection(String(localized: "Adjust")) {
                SettingsPickerRow(
                    title: String(localized: "Hue"),
                    selection: Binding(
                        get: { snapped.hue },
                        set: { update(hue: $0) }
                    ),
                    options: CustomAccentColor.hueSteps,
                    label: { "\($0)\u{00B0}" }
                )
                SettingsPickerRow(
                    title: String(localized: "Saturation"),
                    selection: Binding(
                        get: { snapped.saturation },
                        set: { update(saturation: $0) }
                    ),
                    options: CustomAccentColor.saturationSteps,
                    label: { "\($0)%" }
                )
                SettingsPickerRow(
                    title: String(localized: "Brightness"),
                    selection: Binding(
                        get: { snapped.brightness },
                        set: { update(brightness: $0) }
                    ),
                    options: CustomAccentColor.brightnessSteps,
                    label: { "\($0)%" }
                )
            }

            SettingsSection(
                String(localized: "Hex Color"),
                footer: hexInvalid ? String(localized: "Enter six hex digits, like #1E88E5.") : nil
            ) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "number")
                        .font(SettingsRowFont.title)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(String(localized: "Hex color, like #1E88E5"), text: $hexText)
                        .textFieldStyle(.plain)
                        .font(SettingsRowFont.title)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .onSubmit { commitHexText() }
                }
            }

            SettingsSection(nil) {
                SettingsActionRow(
                    title: String(localized: "Use This Color"),
                    subtitle: String(localized: "Applies the color across the app and syncs it with your profile."),
                    systemImage: "checkmark"
                ) {
                    commitHexText()
                    guard !hexInvalid else { return }
                    onApply(CustomAccentColor.hexString(rgb))
                    // A changed colour rebuilds the app root and this page with it; when nothing
                    // changed, Back-equivalent so the press visibly does something.
                    dismiss()
                }
            }
        }
        .navigationTitle(String(localized: "Custom Color"))
        .onChange(of: rgb) { _, newValue in
            hexText = CustomAccentColor.hexString(newValue)
            hexInvalid = false
        }
    }

    private func update(hue: Int? = nil, saturation: Int? = nil, brightness: Int? = nil) {
        var next = snapped
        if let hue { next.hue = hue }
        if let saturation { next.saturation = saturation }
        if let brightness { next.brightness = brightness }
        rgb = CustomAccentColor.rgb(from: next)
    }

    /// Reads the hex field into `rgb`, or flags it. A field that already matches `rgb` (the
    /// common case: the user only used the menus) is left alone.
    private func commitHexText() {
        if let parsed = CustomAccentColor.parse(hex: hexText) {
            hexInvalid = false
            if parsed != rgb { rgb = parsed }
            hexText = CustomAccentColor.hexString(parsed)
        } else {
            hexInvalid = true
        }
    }
}

/// One preset colour. `.borderless` supplies the system focus lift; the swatch adds only the
/// selection / focus ring in a shade that contrasts the fill (the same recipe as the theme
/// swatches in `AppearanceSettingsPane`).
private struct PresetSwatch: View {
    let rgb: UInt32
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Circle()
            .fill(Color(hex: rgb))
            .frame(width: 56, height: 56)
            .overlay(
                Circle().strokeBorder(
                    isSelected
                        ? Theme.Palette.onColor(forFillHex: rgb)
                        : (isFocused ? Theme.Palette.onColor(forFillHex: rgb).opacity(0.8) : .clear),
                    lineWidth: isSelected ? 4 : 3
                )
            )
            .padding(Theme.Spacing.sm)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
