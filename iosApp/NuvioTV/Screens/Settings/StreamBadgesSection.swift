import SwiftUI
import SharedCore

/// The Stream Badges section body (Appearance category): toggles + placement + imported
/// badge-pack management, all backed by the shared `StreamBadgeSettingsRepository` (syncs across
/// devices). Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and wiring
/// preserved verbatim.
///
/// beta.15 §C (C3a): the three toggles bind straight to the view-model instead of the legacy
/// value+action shim. Wave 2 (VIS-03): each pack is one `Menu` row (Set Active / Remove) and the
/// importer is two plain rows, so every list row holds exactly one focus target.
struct StreamBadgesSection: View {
    @ObservedObject var badges: BadgeSettingsViewModel

    var body: some View {
        Text("Badge packs add quality / HDR / audio-channel chips to stream results. Import a pack by its JSON URL \u{2014} packs imported on the Nuvio mobile app sync here automatically. Tip: Remote Setup (Advanced) lets you paste the URL from a phone browser.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: String(localized: "File Size Badges"),
            subtitle: String(localized: "Show the video size (GB/MB) as a chip on stream results."),
            isOn: Binding(get: { badges.showFileSizeBadges }, set: { badges.setShowFileSizeBadges($0) })
        )
        SettingsToggleRow(
            title: String(localized: "Show Add-on Logo"),
            subtitle: String(localized: "Show each result's add-on logo and name on the right of the row."),
            isOn: Binding(get: { badges.showAddonLogo }, set: { badges.setShowAddonLogo($0) })
        )
        SettingsToggleRow(
            title: String(localized: "Badges Above Title"),
            subtitle: badges.badgesOnTop
                ? String(localized: "Badge chips render above the stream name.")
                : String(localized: "Badge chips render below the stream description."),
            isOn: Binding(get: { badges.badgesOnTop }, set: { badges.setBadgesOnTop($0) })
        )

        if badges.imports.isEmpty {
            Text("No badge packs imported yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            // VIS-03: one list row per pack. The two chip buttons that used to share a row (a
            // custom container with two focus targets, the BUG-65 class) became a pull-down
            // menu on the row itself, the native pattern for secondary actions in a tvOS list.
            ForEach(badges.imports, id: \.sourceUrl) { pack in
                Menu {
                    if !pack.isActive {
                        Button {
                            badges.setActive(pack.sourceUrl)
                        } label: {
                            Label("Set Active", systemImage: "checkmark.circle")
                        }
                    }
                    Button(role: .destructive) {
                        badges.deletePack(pack.sourceUrl)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        SettingsRowLabel(
                            title: BadgeSettingsViewModel.packLabel(pack.sourceUrl),
                            subtitle: pack.enabledFilterCount == 1
                                ? String(localized: "1 filter \u{00B7} \(pack.sourceUrl)")
                                : String(localized: "\(pack.enabledFilterCount) filters \u{00B7} \(pack.sourceUrl)")
                        )
                        .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.md)
                        if pack.isActive {
                            // Selected state = a glyph plus a word, never colour alone. The glyph
                            // is the one accent the spec allows on a settings row.
                            Label("Active", systemImage: "checkmark")
                                .font(Theme.Font.meta)
                                .labelStyle(.titleAndIcon)
                                .settingsSelectionAccentTint()
                        }
                    }
                }
            }
        }

        BadgeUrlEntryRow(isImporting: badges.isImporting) { badges.importPack(url: $0) }

        if let status = badges.statusMessage {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(status.hasPrefix("Imported") ? Theme.Palette.textSecondary : .red)
        }
    }
}

/// URL entry + import button for a stream badge pack (mirrors `PluginRepoEntryRow`).
///
/// VIS-03 / gap 14: two separate list rows (a `Group` flattens into its parent `Section`) instead
/// of one container holding two focus targets, and the stock text field instead of a hand-made
/// glass field: Liquid Glass belongs to floating chrome, never to a settings row. Import is a
/// regular list row button, so it follows the system row focus and needs no tint.
private struct BadgeUrlEntryRow: View {
    let isImporting: Bool
    let onImport: (String) -> Void
    @State private var url = ""

    var body: some View {
        Group {
            TextField("Badge pack JSON URL", text: $url)
                .font(Theme.Font.body)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(submit)

            Button(action: submit) {
                HStack(spacing: Theme.Spacing.md) {
                    SettingsRowLabel(title: String(localized: "Import Badge Pack"), systemImage: "plus")
                    Spacer(minLength: Theme.Spacing.md)
                    if isImporting {
                        ProgressView()
                    }
                }
            }
            .disabled(isImporting || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isImporting else { return }
        onImport(trimmed)
        url = ""
    }
}
