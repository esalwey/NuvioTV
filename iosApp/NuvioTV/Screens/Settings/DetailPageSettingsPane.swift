import SwiftUI
import SharedCore

/// "Detail Page" category content: how a title's page is laid out. Everything here is the shared
/// `MetaScreenSettingsRepository` (synced per profile, so a change on the phone shows up here and
/// the other way round) except the season selector, which is this Apple TV's own choice.
///
/// Rows are the kit's stock ones (`SettingsToggleRow`, `SettingsPickerRow`, `SettingsActionRow`),
/// so the pane looks and focuses like its neighbours. There is no drag on tvOS: a section is moved
/// the way Home Rows are, from the long-press menu of its row.
struct DetailPageSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        let mode = DetailBackgroundMode(kotlinName: model.detailBackgroundModeName)
        let cardStyle = DetailEpisodeCardStyle(kotlinName: model.detailEpisodeCardStyleName)

        SettingsSection(String(localized: "Appearance")) {
            SettingsPickerRow(
                title: String(localized: "Background"),
                subtitle: mode.summary,
                selection: Binding(
                    get: { mode },
                    set: { model.setDetailBackgroundMode($0.key) }
                ),
                options: DetailBackgroundMode.allCases,
                label: { $0.title }
            )
        }

        SettingsSection(String(localized: "Episodes")) {
            SettingsPickerRow(
                title: String(localized: "Episode Cards"),
                subtitle: cardStyle == .list
                    ? String(localized: "One row per episode, with its synopsis")
                    : String(localized: "A shelf of episode stills"),
                selection: Binding(
                    get: { cardStyle },
                    set: { model.setDetailEpisodeCardStyle($0.key) }
                ),
                options: DetailEpisodeCardStyle.allCases,
                label: { $0.title }
            )

            SettingsToggleRow(
                title: String(localized: "Blur Unwatched Episodes"),
                subtitle: model.detailBlurUnwatchedEpisodes
                    ? String(localized: "Stills of episodes you have not watched are blurred, so browsing a season spoils nothing")
                    : String(localized: "Episode stills are shown as they are"),
                isOn: Binding(
                    get: { model.detailBlurUnwatchedEpisodes },
                    set: { model.setDetailBlurUnwatchedEpisodes($0) }
                )
            )

            SettingsPickerRow(
                title: String(localized: "Season Selector"),
                subtitle: model.seasonViewMode == "text"
                    ? String(localized: "Seasons are listed by name")
                    : String(localized: "Seasons show their poster when they have one"),
                selection: Binding(
                    get: { model.seasonViewMode },
                    set: { model.setSeasonViewMode($0) }
                ),
                options: ["posters", "text"],
                label: { $0 == "text" ? String(localized: "Text") : String(localized: "Posters") }
            )
        }

        SettingsSection(
            String(localized: "Sections"),
            footer: String(localized: "Press and hold a section to move it up or down. Actions and Overview stay at the top of the page.")
        ) {
            let movable = model.detailSections.filter { !Self.isHeaderSection($0) }
            ForEach(model.detailSections, id: \.key.name) { item in
                SettingsToggleRow(
                    title: item.title,
                    subtitle: item.description_,
                    isOn: Binding(
                        get: { item.enabled },
                        set: { model.setDetailSectionEnabled(item, $0) }
                    )
                )
                .modifier(SectionMoveMenu(
                    canMoveUp: Self.index(of: item, in: movable).map { $0 > 0 } ?? false,
                    canMoveDown: Self.index(of: item, in: movable).map { $0 < movable.count - 1 } ?? false,
                    moveUp: { model.moveDetailSection(item, up: true) },
                    moveDown: { model.moveDetailSection(item, up: false) }
                ))
            }

            SettingsActionRow(
                title: String(localized: "Reset Detail Page"),
                subtitle: String(localized: "Sections, background and episode options go back to their defaults."),
                systemImage: "arrow.counterclockwise"
            ) {
                model.resetDetailLayout()
            }
        }
    }

    /// Actions and Overview are the page's header: they switch on and off but do not move.
    private static func isHeaderSection(_ item: MetaScreenSectionItem) -> Bool {
        item.key.name == "ACTIONS" || item.key.name == "OVERVIEW"
    }

    private static func index(of item: MetaScreenSectionItem, in movable: [MetaScreenSectionItem]) -> Int? {
        movable.firstIndex { $0.key.name == item.key.name }
    }
}

/// The long-press menu of a section row: Move Up / Move Down, only the directions that exist. A
/// header section (Actions, Overview) gets no menu at all — an empty one would swallow the press.
private struct SectionMoveMenu: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    func body(content: Content) -> some View {
        if canMoveUp || canMoveDown {
            content.contextMenu {
                if canMoveUp {
                    Button(action: moveUp) {
                        Label("Move Up", systemImage: "chevron.up")
                    }
                }
                if canMoveDown {
                    Button(action: moveDown) {
                        Label("Move Down", systemImage: "chevron.down")
                    }
                }
            }
        } else {
            content
        }
    }
}
