import SwiftUI
import SharedCore

/// Settings > Home Screen > Ambient Mode: whether the idle slideshow runs, how long Nuvio waits for
/// it, and which catalogs it takes artwork from. Pushed by a `SettingsLinkRow`, so Back pops to the
/// Home Screen list.
struct AmbientModeSettingsPage: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var ambient = AmbientModeSettingsModel.shared

    var body: some View {
        List {
            SettingsSection(
                title: nil,
                footer: String(localized: "Starts after the Siri Remote has been idle for the time you choose. Pick a time shorter than your Apple TV screen saver delay, or the screen saver starts first. Any button returns to where you were.")
            ) {
                SettingsToggleRow(
                    title: String(localized: "Ambient Mode"),
                    subtitle: ambient.settings.enabled
                        ? String(localized: "Fills the screen with artwork from your catalogs while nothing is happening")
                        : String(localized: "Nuvio stays on Home when idle"),
                    isOn: Binding(
                        get: { ambient.settings.enabled },
                        set: { ambient.setEnabled($0) }
                    )
                )

                if ambient.settings.enabled {
                    SettingsPickerRow(
                        title: String(localized: "Start After"),
                        selection: Binding(
                            get: { ambient.settings.timeoutMinutes },
                            set: { ambient.setTimeoutMinutes($0) }
                        ),
                        options: Self.timeoutOptions(including: ambient.settings.timeoutMinutes),
                        label: { AmbientModeSettings.timeoutLabel(minutes: $0) }
                    )

                    if model.catalogs.contains(where: { !$0.isCollection }) {
                        SettingsLinkRow(
                            title: String(localized: "Artwork From"),
                            subtitle: Self.catalogSummary(selected: selectedCatalogs.count)
                        ) {
                            AmbientCatalogsPage(model: model)
                        }
                    } else {
                        SettingsValueRow(
                            title: String(localized: "Artwork From"),
                            value: Self.catalogSummary(selected: 0)
                        )
                    }
                }
            }
        }
        .navigationTitle(Text("Ambient Mode"))
    }

    /// The delay choices, plus the saved delay when it is not one of them, so the row never shows a blank.
    private static func timeoutOptions(including current: Int) -> [Int] {
        let options = AmbientModeSettings.timeoutOptionsMinutes
        return options.contains(current) ? options : (options + [current]).sorted()
    }

    private var selectedCatalogs: [HomeCatalogSettingsItem] {
        let keys = ambient.settings.catalogKeys
        return model.catalogs.filter { !$0.isCollection && keys.contains($0.key) }
    }

    static func catalogSummary(selected: Int) -> String {
        selected == 0
            ? String(localized: "Same as the Home hero")
            : String(localized: "\(selected) of \(AmbientModeSettings.maxCatalogs) selected")
    }
}

/// The catalog choice for Ambient Mode: up to three, each a toggle. At the limit an unselected row
/// keeps focus and says why it can not be turned on, instead of dropping out of the focus order.
struct AmbientCatalogsPage: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var ambient = AmbientModeSettingsModel.shared

    private var catalogs: [HomeCatalogSettingsItem] {
        model.catalogs.filter { !$0.isCollection }
    }

    var body: some View {
        List {
            SettingsSection(
                title: nil,
                footer: String(localized: "Choose up to \(AmbientModeSettings.maxCatalogs) catalogs. With none chosen, Ambient Mode uses the titles of your Home hero.")
            ) {
                if catalogs.isEmpty {
                    Text("Install add-ons to choose catalogs.")
                        .font(SettingsRowFont.title)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(catalogs, id: \.key) { item in
                        let selected = ambient.settings.catalogKeys.contains(item.key)
                        let atLimit = !selected && ambient.settings.catalogKeys.count >= AmbientModeSettings.maxCatalogs
                        SettingsToggleRow(
                            title: item.displayTitle,
                            subtitle: atLimit
                                ? String(localized: "Limit reached \u{2014} turn another catalog off first")
                                : item.addonName,
                            isOn: Binding(
                                get: { selected },
                                set: { ambient.setCatalog(item.key, selected: $0) }
                            )
                        )
                    }
                }
            }
        }
        .navigationTitle(Text("Artwork From"))
    }
}
