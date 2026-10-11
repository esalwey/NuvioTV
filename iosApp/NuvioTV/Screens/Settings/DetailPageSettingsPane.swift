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
    /// Which providers are connected decides where More Like This can read from.
    @ObservedObject var trakt: TraktViewModel
    @ObservedObject var simkl: SimklViewModel

    /// Local-only switches the title page reads through the same `@AppStorage` keys (DetailView).
    ///
    /// F2 / decision D5: a trailer never takes the screen over by itself, so the full-screen
    /// auto-play defaults OFF (the muted in-place background trailer stays on). The defaults here
    /// must match DetailView's own declarations, or a fresh install shows a switch off while the
    /// behavior is on.
    @AppStorage("detail_trailer_autoplay") private var detailTrailerAutoplay = false
    @AppStorage("detail_poster_backdrop") private var detailPosterBackdrop = true
    /// UX-4b: the muted background trailer (distinct from the full-screen auto-play above).
    @AppStorage("detail_trailer_background") private var detailTrailerBackground = true
    /// FEAT-8: 0 = play forever.
    @AppStorage("detail_trailer_duration") private var detailTrailerDuration = 0
    @AppStorage("detail_action_icons_only") private var detailActionIconsOnly = false
    @AppStorage("detail_trailer_button_enabled") private var detailTrailerButton = true
    @AppStorage("detail_show_full_release_date") private var detailFullReleaseDate = false

    private static let trailerDurationOptions: [(value: Int, label: String)] = [
        (30, String(localized: "30s")),
        (60, String(localized: "1 min")),
        (90, String(localized: "90s")),
        (0, String(localized: "Always")),
    ]

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
            SettingsToggleRow(
                title: String(localized: "Poster in Detail Background"),
                subtitle: String(localized: "Show the title's poster on the right side of detail pages"),
                isOn: $detailPosterBackdrop
            )
            // FEAT-9
            SettingsToggleRow(
                title: String(localized: "Icon-Only Detail Buttons"),
                subtitle: String(localized: "Buttons show icons only"),
                isOn: $detailActionIconsOnly
            )
            SettingsToggleRow(
                title: String(localized: "Full Release Date"),
                subtitle: String(localized: "A movie's detail page shows its release date instead of the year"),
                isOn: $detailFullReleaseDate
            )
        }

        SettingsSection(String(localized: "Trailers")) {
            SettingsToggleRow(
                title: String(localized: "Auto-Play Trailer on Detail"),
                subtitle: String(localized: "Play the trailer full screen shortly after opening a title"),
                isOn: $detailTrailerAutoplay
            )
            // UX-4b (tester ask): the auto-play toggle above never controlled the muted
            // trailer looping BEHIND the detail description — that had no switch at all.
            SettingsToggleRow(
                title: String(localized: "Background Trailer on Detail"),
                subtitle: String(localized: "A muted trailer plays behind the description on detail pages"),
                isOn: $detailTrailerBackground
            )
            // FEAT-8: only meaningful while the background trailer itself is on.
            if detailTrailerBackground {
                SettingsPickerRow(
                    title: String(localized: "Trailer Duration"),
                    selection: $detailTrailerDuration,
                    options: Self.trailerDurationOptions.map(\.value),
                    label: { value in Self.trailerDurationOptions.first { $0.value == value }?.label ?? "\(value)" }
                )
            }
            // Independent of the two switches above: this one only removes the action-row button.
            SettingsToggleRow(
                title: String(localized: "Trailer Button on Detail"),
                subtitle: String(localized: "Show the Trailer button beside Play"),
                isOn: $detailTrailerButton
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

        // The source row appears once Trakt or Simkl is connected (before that TMDB is the only
        // choice); a stored choice whose provider is not connected reads as TMDB, which is what the
        // shared repository falls back to as well.
        if trakt.isConnected || simkl.isConnected {
            SettingsSection(String(localized: "More Like This")) {
                SettingsPickerRow(
                    title: String(localized: "More Like This Source"),
                    subtitle: String(localized: "Where recommendations on a title's page come from."),
                    selection: Binding(
                        get: { effectiveMoreLikeThisSource },
                        set: { model.setMoreLikeThisSource($0) }
                    ),
                    options: moreLikeThisOptions,
                    label: Self.moreLikeThisLabel
                )
            }
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

    private var moreLikeThisOptions: [String] {
        ["tmdb"] + (trakt.isConnected ? ["trakt"] : []) + (simkl.isConnected ? ["simkl"] : [])
    }

    private var effectiveMoreLikeThisSource: String {
        let stored = model.moreLikeThisSource
        return moreLikeThisOptions.contains(stored) ? stored : "tmdb"
    }

    private static func moreLikeThisLabel(_ key: String) -> String {
        switch key {
        case "trakt": return String(localized: "Trakt")
        case "simkl": return String(localized: "Simkl")
        default: return String(localized: "TMDB")
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
