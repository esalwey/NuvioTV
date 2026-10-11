import SwiftUI
import SharedCore

// Pushed sub-pages of Settings → Content Sources. Each is a native `List` of stock kit rows, the way
// Settings.app drills into a group of switches; Menu pops back to the pane that pushed it.

/// "Enrichment Groups": one switch per part of a title TMDB may fill in or replace. Reached from the
/// Metadata (TMDB) section once enrichment is on, so there is always a focusable row here (BUG-47).
struct TmdbEnrichmentGroupsPage: View {
    @StateObject private var vm = TmdbModulesViewModel()

    var body: some View {
        List {
            SettingsSection(
                String(localized: "Enrichment Groups"),
                footer: String(localized: "Choose which parts of a title TMDB fills in. Titles you open after changing a switch use the new setting.")
            ) {
                ForEach(TmdbModule.allCases, id: \.self) { module in
                    SettingsToggleRow(
                        title: module.title,
                        subtitle: module.subtitle,
                        isOn: Binding(
                            get: { vm.flags.isOn(module) },
                            set: { vm.set(module, $0) }
                        )
                    )
                }
            }
        }
        .navigationTitle(String(localized: "Enrichment Groups"))
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

/// "Ratings Providers": which MDBList providers appear on a title's Details, and in what order.
/// Reached from the Ratings (MDBList) section once ratings are on.
struct MdbListRatingsPage: View {
    @StateObject private var vm = MdbListProvidersViewModel()

    var body: some View {
        List {
            SettingsSection(
                String(localized: "Providers"),
                footer: String(localized: "Ratings from switched-off providers are not shown.")
            ) {
                ForEach(MdbListProviders.all, id: \.self) { id in
                    SettingsToggleRow(
                        title: MdbListProviders.name(id),
                        isOn: Binding(
                            get: { vm.enabled.contains(id) },
                            set: { vm.setEnabled(id, $0) }
                        )
                    )
                }
            }

            SettingsSection(
                String(localized: "Order"),
                footer: String(localized: "Ratings appear on a title's Details in this order. Select a provider to move it.")
            ) {
                ForEach(Array(vm.order.enumerated()), id: \.element) { index, id in
                    providerOrderRow(id: id, index: index)
                }
            }
        }
        .navigationTitle(String(localized: "Ratings Providers"))
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    /// A choice row in the same shape as `SettingsPickerRow` (a `Menu` over a `LabeledContent`): the
    /// value is the provider's position, the menu moves it one step.
    private func providerOrderRow(id: String, index: Int) -> some View {
        Menu {
            Button {
                vm.move(id, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(index == 0)

            Button {
                vm.move(id, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(index == vm.order.count - 1)
        } label: {
            LabeledContent {
                Text("\(index + 1)")
                    .font(SettingsRowFont.title)
                    .settingsAccentTint()
            } label: {
                SettingsRowLabel(
                    title: MdbListProviders.name(id),
                    subtitle: vm.enabled.contains(id) ? nil : String(localized: "Hidden")
                )
            }
        }
    }
}
