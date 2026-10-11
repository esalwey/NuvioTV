import SwiftUI
import SharedCore

/// Season selector + horizontal episode thumbnail shelf for series titles. Mirrors the shared
/// `SeriesSeasonSupport` rules: specials (season 0 / missing) normalize to 0 and sort last;
/// episodes order by number, then release, then title. Tapping an episode opens the stream picker
/// with that episode's playback videoId. A fixed-height panel under the shelf shows the focused
/// episode's synopsis, so browsing left/right never reflows the sections below.
struct EpisodesSection: View {
    let meta: MetaDetails
    /// IMDb ratings keyed "season:episode" (from `DetailViewModel.episodeRatings`); empty = no badges.
    var episodeRatings: [String: Double] = [:]
    /// Episodes to badge as watched, keyed "season:episode" (from `DetailViewModel.watchedEpisodeKeys`).
    var watchedEpisodeKeys: Set<String> = []
    /// EP-2/AES-4: in-progress fraction (0…1) per episode, keyed "season:episode"
    /// (`DetailViewModel.episodeProgress`); drawn as a bar along the bottom of the still.
    var episodeProgress: [String: Double] = [:]
    /// EP-1: the season and episode of the series' Resume / Up Next action — the shelf opens on
    /// that season, scrolled to that episode, and follows it until the viewer reaches the shelf.
    var preferredSeason: Int? = nil
    var preferredEpisode: Int? = nil
    /// SET-2: `EpisodeRatingsVisibility.name` — "HIDE_EPISODES" drops every rating badge,
    /// "HIDE_UNWATCHED_EPISODES" keeps them only on watched episodes (no spoilers).
    var episodeRatingsVisibility: String = "SHOW_ALL"
    /// SET-2: Settings → Appearance → Ratings → Overall Ratings (the player's Info-tab rating chip).
    var showOverallRatings: Bool = true
    /// Settings → Detail Page → Episode Cards: a shelf of stills, or one row per episode.
    var cardStyle: DetailEpisodeCardStyle = .horizontal
    /// Settings → Detail Page → Blur Unwatched Episodes: stills of episodes not watched yet are
    /// blurred, so browsing a season spoils nothing.
    var blurUnwatchedEpisodes: Bool = false
    /// EP-2: mark / unmark one episode (long press → context menu). nil = no menu.
    var onToggleWatched: ((MetaVideo) -> Void)? = nil
    /// Episode options beyond the single mark (Android TV / mobile episode menu): what the long-press
    /// menu offers for an episode, and the season / previous-episodes marks. nil = the single mark only.
    var episodeOptions: ((MetaVideo) -> DetailViewModel.EpisodeOptions?)? = nil
    var onToggleSeasonWatched: ((MetaVideo) -> Void)? = nil
    var onMarkPreviousWatched: ((MetaVideo) -> Void)? = nil
    /// Opens the episode's Trakt comments (the menu's "Episode Comments"). nil = Trakt comments are
    /// switched off, no menu item.
    var onOpenComments: ((MetaVideo) -> Void)? = nil

    @State private var selectedSeason: Int?
    /// Settings → Detail Page → Season Selector (`SeasonViewModeStorage`, this Apple TV): text
    /// chips even when the seasons have posters. Read when the section is created; the setting
    /// lives in Settings, which cannot be open under a detail page.
    @State private var seasonsAsText = SeasonViewModeStorage.shared.load() == SeasonViewMode.text
    /// EP-1: an episode card has had focus. Until then the shelf follows the Resume / Up Next action
    /// as it resolves (local progress first, a Trakt hydration seconds later); from then on the
    /// season on screen is pinned into `selectedSeason` and the shelf never scrolls by itself, so an
    /// action that moves on — an episode marked watched, a season finale, a sync landing — never
    /// swaps the season or the scroll position under the viewer.
    @State private var shelfEngaged = false
    @State private var episodeForStreams: EpisodeRoute?
    @FocusState private var focusedEpisodeId: String?
    /// Gap 21 (spec §6.3): the focused season tab. Selection follows focus after a short dwell,
    /// like a tvOS segmented control ("segments become selected when focus moves to them").
    @FocusState private var focusedSeason: Int?
    /// The pending dwell for `focusedSeason`; replaced on every focus move so a quick swipe across
    /// several seasons only selects the one the viewer stops on.
    @State private var seasonDwellTask: Task<Void, Never>?
    /// Dwell before a focused season tab becomes the selected one (spec §6.3).
    private static let seasonSelectionDwell: Duration = .milliseconds(300)

    var body: some View {
        let grouped = Self.groupedEpisodes(meta.videos)
        let seasons = grouped.keys.sorted { Self.seasonSortKey($0) < Self.seasonSortKey($1) }
        // EP-1: the viewer's pick, else the Resume / Up Next episode's season, else the first.
        let preferred = Self.preferredSeasonKey(preferredSeason, in: grouped)
        let current = selectedSeason ?? preferred ?? seasons.first
        let episodes = current.flatMap { grouped[$0] } ?? []
        let restingEpisodeId = Self.shelfRestingEpisodeId(
            episodes: episodes,
            isPreferredSeason: preferred != nil && current == preferred,
            preferredEpisode: preferredEpisode
        )

        return VStack(alignment: .leading, spacing: 20) {
            if seasons.count > 1 {
                // FEAT-24 (u/mrStevenx3, p4afwfo): season POSTERS instead of "Season 1 / Season 2"
                // text, "comme le fait l'application mobile Nuvio". The data was already here —
                // `MetaVideo.seasonPoster` is filled by the TMDB season fetch (`useSeasonPosters`,
                // default ON) — tvOS just never drew it. Mobile's rule (DetailSeriesContent.kt):
                // posters when any season has one, text chips otherwise; the poster's fallback is
                // the show poster. Mobile's Posters/Text toggle is Settings → Detail Page →
                // Season Selector (`seasonsAsText`).
                let posterBySeason = Self.seasonPosters(grouped, meta: meta)
                if !seasonsAsText, posterBySeason.values.contains(where: { $0 != nil }) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                            ForEach(seasons, id: \.self) { season in
                                Button {
                                    selectedSeason = season
                                } label: {
                                    SeasonPosterCard(
                                        label: Self.seasonLabel(season),
                                        imageURL: posterBySeason[season] ?? nil ?? meta.poster ?? meta.background,
                                        isSelected: season == current
                                    )
                                }
                                // BUG-93: SeasonPosterCard has no manual treatment - keep the native lift in ring mode.
                                .cardFocusButtonStyle(lift: .plain)
                                // BUG-32: follow the user's Corners setting (system radius
                                // otherwise overrides it — the BUG-25 class).
                                .posterButtonShape()
                                .focused($focusedSeason, equals: season)
                                .accessibilityIdentifier("season_poster_\(season)")
                                .accessibilityAddTraits(season == current ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, Theme.Spacing.md)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                    // Spec §6.3: Up from any episode lands on the SELECTED season, not the nearest.
                    .defaultFocus($focusedSeason, current, priority: .userInitiated)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(seasons, id: \.self) { season in
                                Button {
                                    selectedSeason = season
                                } label: {
                                    Text(Self.seasonLabel(season))
                                        .padding(.horizontal, 20).padding(.vertical, 8)
                                }
                                .buttonStyle(.chip(selected: season == current))
                                .focused($focusedSeason, equals: season)
                                .accessibilityAddTraits(season == current ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusSection()
                    .defaultFocus($focusedSeason, current, priority: .userInitiated)
                }
            }

            // UX-15 (u/mrStevenx3, beta.13 review): with multiple seasons the heading used to sit
            // ABOVE the season selector, reading "Episodes → seasons → episodes" — inverted
            // hierarchy. It now labels the shelf it belongs to, directly under the selector. Was
            // also a raw `Text("Episodes")` — the one unlocalized string on this screen (his
            // French locale showed "Episodes", not "Épisodes").
            Text(String(localized: "Episodes")).font(Theme.Font.screenTitle)

            if cardStyle == .list {
                episodeList(episodes: episodes, restingEpisodeId: restingEpisodeId)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                            ForEach(episodes, id: \.id) { episode in
                                Button {
                                    episodeForStreams = EpisodeRoute(meta: meta, episode: episode)
                                } label: {
                                    EpisodeThumbCard(
                                        episode: episode,
                                        fallbackImage: meta.background ?? meta.poster,
                                        rating: rating(for: episode),
                                        isWatched: isWatched(episode),
                                        progress: progress(for: episode),
                                        blursStill: blursStill(of: episode)
                                    )
                                }
                                // BUG-93: EpisodeThumbCard uses tileFocusLift, not CardFocusTreatment - keep the native lift in ring mode.
                                .cardFocusButtonStyle(lift: .plain)
                                .posterButtonShape() // BUG-32: honor the Corners setting
                                .focused($focusedEpisodeId, equals: episode.id)
                                .modifier(EpisodeOptionsMenu(
                                    isWatched: isWatched(episode),
                                    onToggle: toggleWatchedAction(for: episode),
                                    options: { episodeOptions?(episode) },
                                    onStartOver: { episodeForStreams = EpisodeRoute(meta: meta, episode: episode, startOver: true) },
                                    onToggleSeason: onToggleSeasonWatched.map { handler in { handler(episode) } },
                                    onMarkPrevious: onMarkPreviousWatched.map { handler in { handler(episode) } },
                                    onOpenComments: onOpenComments.map { handler in { handler(episode) } }
                                ))
                                .id(episode.id)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.md)
                    }
                    .scrollClipDisabled()
                    .onAppear {
                        // EP-1: open on the Resume / Up Next episode (the layout pass has to land first).
                        // Not on a return to this page once the viewer has been through the shelf.
                        guard !shelfEngaged, let restingEpisodeId, restingEpisodeId != episodes.first?.id else { return }
                        DispatchQueue.main.async {
                            var tx = Transaction()
                            tx.disablesAnimations = true
                            withTransaction(tx) { proxy.scrollTo(restingEpisodeId, anchor: .leading) }
                        }
                    }
                    .onChange(of: current) { _, _ in
                        // A new season can be shorter than the old scroll offset; snap to its first
                        // episode — or, EP-1, to the Resume / Up Next episode — without animating
                        // through the intermediate layout.
                        guard let restingEpisodeId else { return }
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { proxy.scrollTo(restingEpisodeId, anchor: .leading) }
                    }
                    .onChange(of: restingEpisodeId) { _, target in
                        // EP-1: the action resolved late within the season on screen (a Trakt
                        // hydration) — follow it, but only until the viewer has reached the shelf.
                        guard let target, !shelfEngaged, focusedEpisodeId == nil else { return }
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { proxy.scrollTo(target, anchor: .leading) }
                    }
                }
                .focusSection()
                .onChange(of: focusedEpisodeId) { _, focused in
                    // EP-1: the viewer reached the shelf — pin the season on screen (see `shelfEngaged`).
                    guard focused != nil, !shelfEngaged else { return }
                    shelfEngaged = true
                    if selectedSeason == nil { selectedSeason = current }
                }

                focusedOverviewPanel(episodes: episodes, restingEpisodeId: restingEpisodeId)
            }
        }
        // Gap 21: selection follows focus after `seasonSelectionDwell`. Select still selects at
        // once (the buttons' own action), and leaving the row cancels a pending dwell.
        .onChange(of: focusedSeason) { _, season in
            seasonDwellTask?.cancel()
            guard let season, season != selectedSeason else {
                seasonDwellTask = nil
                return
            }
            seasonDwellTask = Task { @MainActor in
                try? await Task.sleep(for: Self.seasonSelectionDwell)
                guard !Task.isCancelled, focusedSeason == season else { return }
                selectedSeason = season
            }
        }
        .onDisappear {
            seasonDwellTask?.cancel()
            seasonDwellTask = nil
        }
        .fullScreenCover(item: $episodeForStreams) { route in
            EpisodeStreamPickerCover(route: route, playbackMeta: playbackMeta(for: route.meta))
        }
    }

    /// SET-2: with Overall Ratings off the player's Info tab shows no rating chip either.
    private func playbackMeta(for details: MetaDetails) -> PlaybackMeta {
        var meta = PlaybackMeta(details: details)
        if !showOverallRatings { meta.imdbRating = nil }
        return meta
    }

    /// Settings → Detail Page → Episode Cards → List: one row per episode, in the system `.card`
    /// style (spec 5.3). Each row carries its own synopsis, so there is no overview panel. Focus
    /// moving down from the season selector lands on the Resume / Up Next episode (spec 6.3).
    @ViewBuilder
    private func episodeList(episodes: [MetaVideo], restingEpisodeId: String?) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(episodes, id: \.id) { episode in
                Button {
                    episodeForStreams = EpisodeRoute(meta: meta, episode: episode)
                } label: {
                    EpisodeListRow(
                        episode: episode,
                        fallbackImage: meta.background ?? meta.poster,
                        rating: rating(for: episode),
                        isWatched: isWatched(episode),
                        progress: progress(for: episode),
                        blursStill: blursStill(of: episode)
                    )
                }
                .buttonStyle(.card)
                .focused($focusedEpisodeId, equals: episode.id)
                .modifier(EpisodeOptionsMenu(
                    isWatched: isWatched(episode),
                    onToggle: toggleWatchedAction(for: episode),
                    options: { episodeOptions?(episode) },
                    onStartOver: { episodeForStreams = EpisodeRoute(meta: meta, episode: episode, startOver: true) },
                    onToggleSeason: onToggleSeasonWatched.map { handler in { handler(episode) } },
                    onMarkPrevious: onMarkPreviousWatched.map { handler in { handler(episode) } },
                    onOpenComments: onOpenComments.map { handler in { handler(episode) } }
                ))
                .id(episode.id)
            }
        }
        .focusSection()
        .defaultFocus($focusedEpisodeId, restingEpisodeId, priority: .userInitiated)
        .onChange(of: focusedEpisodeId) { _, focused in
            // EP-1: the viewer reached the list — pin the season on screen (see `shelfEngaged`).
            guard focused != nil, !shelfEngaged else { return }
            shelfEngaged = true
            if selectedSeason == nil { selectedSeason = currentSeasonForPinning }
        }
    }

    /// The season on screen, for pinning it once the viewer reaches the list.
    private var currentSeasonForPinning: Int? {
        let grouped = Self.groupedEpisodes(meta.videos)
        let seasons = grouped.keys.sorted { Self.seasonSortKey($0) < Self.seasonSortKey($1) }
        let preferred = Self.preferredSeasonKey(preferredSeason, in: grouped)
        return selectedSeason ?? preferred ?? seasons.first
    }

    /// Blur Unwatched Episodes: the episode's own still (a fallback backdrop gives nothing away) of
    /// an episode that is not watched yet.
    private func blursStill(of episode: MetaVideo) -> Bool {
        guard blurUnwatchedEpisodes, !isWatched(episode) else { return false }
        let thumb: String? = episode.thumbnail
        return !(thumb ?? "").isEmpty
    }

    /// Fixed-height synopsis for the focused episode (falls back to the episode the shelf rests on
    /// — EP-1's Resume / Up Next one, else the season's first — so the panel is never blank). Fixed
    /// frame keeps the cast row below from reflowing as focus moves along the shelf.
    @ViewBuilder
    private func focusedOverviewPanel(episodes: [MetaVideo], restingEpisodeId: String?) -> some View {
        let episode = episodes.first(where: { $0.id == focusedEpisodeId })
            ?? episodes.first(where: { $0.id == restingEpisodeId })
            ?? episodes.first
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let episode {
                if let caption = Self.episodeCaption(episode) {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                let overview: String? = episode.overview
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: 1100, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.15), value: focusedEpisodeId)
    }

    /// "S1E4 · Apr 12, 2024 · 52 min"-style caption line; nil when nothing is known.
    private static func episodeCaption(_ episode: MetaVideo) -> String? {
        var parts: [String] = []
        if let s = episode.season?.value, let e = episode.episode?.value {
            parts.append("S\(s)E\(e)")
        }
        let released: String? = episode.released
        if let released, released.count >= 10 {
            parts.append(String(released.prefix(10)))
        }
        if let runtime = episode.runtime?.value, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Grouping / sorting (mirrors shared SeriesSeasonSupport.kt)

    /// True if this title should show an episode list at all.
    static func isSeriesLike(_ meta: MetaDetails) -> Bool {
        meta.type == "series" || meta.videos.contains { $0.season != nil || $0.episode != nil }
    }

    nonisolated static func normalizeSeasonNumber(_ season: KotlinInt?) -> Int {
        guard let s = season?.value, s > 0 else { return 0 }
        return s
    }

    nonisolated static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    nonisolated private static func groupedEpisodes(_ videos: [MetaVideo]) -> [Int: [MetaVideo]] {
        let withNumbers = videos.filter { $0.season != nil || $0.episode != nil }
        var groups: [Int: [MetaVideo]] = [:]
        for video in withNumbers {
            groups[normalizeSeasonNumber(video.season), default: []].append(video)
        }
        for (key, value) in groups {
            groups[key] = value.sorted(by: episodeOrder)
        }
        return groups
    }

    nonisolated private static func episodeOrder(_ a: MetaVideo, _ b: MetaVideo) -> Bool {
        let ea = a.episode?.value ?? Int.max
        let eb = b.episode?.value ?? Int.max
        if ea != eb { return ea < eb }
        let ra: String = a.released ?? ""
        let rb: String = b.released ?? ""
        if ra != rb { return ra < rb }
        return a.title < b.title
    }

    private static func seasonLabel(_ season: Int) -> String {
        season <= 0 ? String(localized: "Specials") : String(localized: "Season \(season)")
    }

    /// FEAT-24: first non-blank `seasonPoster` among each season's episodes (mobile's rule), then —
    /// upstream 22096a1e parity — the addon's own `app_extras.seasonPosters` art for that season
    /// number. Same precedence as mobile's `resolveSeasonPoster`: per-episode (TMDB enrichment or a
    /// per-video addon field) first, addon season map second, and the caller's show poster/backdrop
    /// last. The map is keyed by season NUMBER with specials at 0, matching `groupedEpisodes` keys.
    nonisolated private static func seasonPosters(_ grouped: [Int: [MetaVideo]], meta: MetaDetails) -> [Int: String?] {
        var result: [Int: String?] = [:]
        for (season, episodes) in grouped {
            let poster = episodes.lazy
                .compactMap { $0.seasonPoster?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            // `Map<Int, String>` crosses the SharedCore boundary as `[KotlinInt: String]`.
            let trimmedAddon: String? = meta.seasonPosters[KotlinInt(int: Int32(season))]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let addonPoster: String? = (trimmedAddon?.isEmpty == false) ? trimmedAddon : nil
            // Explicit `String?` so `??` doesn't infer against the dictionary's `String??` value type.
            let resolved: String? = poster ?? addonPoster
            result[season] = resolved
        }
        return result
    }

    static func episodeTitle(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return String(localized: "S\(s)E\(e) \u{00B7} \(episode.title)")
        }
        return episode.title
    }

    private func rating(for episode: MetaVideo) -> Double? {
        switch episodeRatingsVisibility {
        case "HIDE_EPISODES": return nil
        case "HIDE_UNWATCHED_EPISODES": if !isWatched(episode) { return nil }
        default: break
        }
        guard let s = episode.season?.value, let e = episode.episode?.value else { return episode.rating?.doubleValue }
        return episodeRatings["\(s):\(e)"] ?? episode.rating?.doubleValue
    }

    private func isWatched(_ episode: MetaVideo) -> Bool {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return false }
        return watchedEpisodeKeys.contains("\(s):\(e)")
    }

    /// EP-2/AES-4: the episode's partial progress; nil once it is watched (the check shows instead).
    private func progress(for episode: MetaVideo) -> Double? {
        guard let s = episode.season?.value, let e = episode.episode?.value,
              !watchedEpisodeKeys.contains("\(s):\(e)") else { return nil }
        return episodeProgress["\(s):\(e)"]
    }

    private func toggleWatchedAction(for episode: MetaVideo) -> (() -> Void)? {
        guard let onToggleWatched else { return nil }
        return { onToggleWatched(episode) }
    }

    /// EP-1: the Resume / Up Next season when it exists in the shelf (specials normalize to 0).
    nonisolated private static func preferredSeasonKey(_ season: Int?, in grouped: [Int: [MetaVideo]]) -> Int? {
        guard let season else { return nil }
        let key = max(season, 0)
        return grouped[key] == nil ? nil : key
    }

    /// EP-1: the episode the shelf rests on — the Resume / Up Next episode when its season is on
    /// screen, else the season's first episode.
    nonisolated private static func shelfRestingEpisodeId(episodes: [MetaVideo], isPreferredSeason: Bool,
                                                          preferredEpisode: Int?) -> String? {
        if isPreferredSeason, let preferredEpisode,
           let match = episodes.first(where: { $0.episode?.value == preferredEpisode }) {
            return match.id
        }
        return episodes.first?.id
    }
}

/// Long press → the episode options (mobile / Android TV episode menu): start over, mark this
/// episode, its season, or everything before it. A conditional modifier, like `ExternalPlayMenu`,
/// so a shelf without a handler adds nothing — an empty context menu would still swallow the long
/// press. Play is the card's own Select, so it is not repeated here; the stream picker is already
/// the manual choice.
private struct EpisodeOptionsMenu: ViewModifier {
    let isWatched: Bool
    let onToggle: (() -> Void)?
    let options: () -> DetailViewModel.EpisodeOptions?
    let onStartOver: () -> Void
    let onToggleSeason: (() -> Void)?
    let onMarkPrevious: (() -> Void)?
    let onOpenComments: (() -> Void)?

    func body(content: Content) -> some View {
        if let onToggle {
            content.contextMenu {
                let available = options()
                if available?.hasProgress == true {
                    Button {
                        onStartOver()
                    } label: {
                        Label("Start from Beginning", systemImage: "backward.end")
                    }
                }
                Button {
                    onToggle()
                } label: {
                    if isWatched {
                        Label("Mark Unwatched", systemImage: "eye.slash")
                    } else {
                        Label("Mark Watched", systemImage: "checkmark.circle")
                    }
                }
                if let onToggleSeason, let available, !available.seasonEpisodes.isEmpty {
                    Button {
                        onToggleSeason()
                    } label: {
                        if available.isSeasonWatched {
                            Label("Mark Season Unwatched", systemImage: "eye.slash")
                        } else {
                            Label("Mark Season Watched", systemImage: "checklist")
                        }
                    }
                }
                if let onMarkPrevious, let available, !available.unwatchedPreviousEpisodes.isEmpty {
                    Button {
                        onMarkPrevious()
                    } label: {
                        Label("Mark Previous Episodes Watched", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                if let onOpenComments {
                    Button {
                        onOpenComments()
                    } label: {
                        Label("Episode Comments", systemImage: "text.bubble")
                    }
                }
            }
        } else {
            content
        }
    }
}

/// `KotlinInt` is an `NSNumber` subclass, whose `.intValue` Swift accessor is `Int32`. This converts
/// to a plain Swift `Int` to avoid Int/Int32 mismatches throughout.
extension KotlinInt {
    nonisolated var value: Int { Int(truncating: self) }
}

/// Identifiable wrapper so an episode can drive `.fullScreenCover(item:)`.
struct EpisodeRoute: Identifiable {
    let meta: MetaDetails
    let episode: MetaVideo
    /// Opened by "Start from Beginning": the episode plays from 0:00 instead of its saved position.
    var startOver = false
    var id: String { startOver ? "\(episode.id)|startOver" : episode.id }

    /// Episode still for the player's Info header — blank addon values count as missing.
    var episodeStill: String? {
        let t: String? = episode.thumbnail
        return (t ?? "").isEmpty ? nil : t
    }
    /// Episode overview, else the series synopsis (never an empty header for a blank overview).
    var synopsis: String? {
        let o: String? = episode.overview
        if let o, !o.isEmpty { return o }
        let d: String? = meta.description_
        return d
    }
}

/// The stream picker for one episode of a series: the episode shelf's Select, its "Start from
/// Beginning" menu item, and Detail's Shuffle all open it, so the ids sent to the addons and the
/// progress record stay identical whichever way in.
struct EpisodeStreamPickerCover: View {
    let route: EpisodeRoute
    let playbackMeta: PlaybackMeta

    var body: some View {
        StreamPickerView(
            type: route.meta.type,
            // STAB-02: progress is keyed `parent:season:episode`; the addons are asked with the
            // episode's own id (kitsu and other anime catalogs don't follow that shape).
            videoId: NextEpisodeEngine.episodeVideoId(metaId: route.meta.id, episode: route.episode),
            streamVideoId: NextEpisodeEngine.streamQueryVideoId(metaId: route.meta.id, episode: route.episode),
            title: EpisodesSection.episodeTitle(route.episode),
            parentMetaId: route.meta.id,
            season: route.episode.season?.value,
            episode: route.episode.episode?.value,
            episodes: route.meta.videos,
            poster: route.meta.poster,
            episodeStill: route.episodeStill,
            synopsis: route.synopsis,
            meta: playbackMeta,
            // CW-1: progress is filed under the series, with the episode's own name beside it.
            seriesTitle: route.meta.name,
            episodeTitle: route.episode.title,
            background: route.meta.background,
            logo: route.meta.logo,
            startFromBeginning: route.startOver
        )
    }
}

/// One 16:9 episode thumbnail in the horizontal shelf: still + watched/rating badges over a bottom
/// scrim, title below. Platter-free — used inside a `.poster` Button, so it carries the same focus
/// ring/scale/shadow language as `LandscapeCard`.
private struct EpisodeThumbCard: View {
    let episode: MetaVideo
    let fallbackImage: String?
    /// IMDb rating for this episode (badge hidden when nil).
    var rating: Double? = nil
    /// Shows the green watched checkmark on the thumbnail (mirrors mobile's watched badge).
    var isWatched: Bool = false
    /// AES-4/EP-2: 0…1 partial progress, drawn along the bottom of the still; nil hides the bar.
    var progress: Double? = nil
    /// Blur Unwatched Episodes: the still of an episode not watched yet is blurred.
    var blursStill: Bool = false

    @Environment(\.isFocused) private var isFocused
    // BUG-32: shared corner token, not the hardcoded Theme.Radius.card.
    @Environment(\.posterStyle) private var posterStyle
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: thumbnailURL)
                    .blur(radius: blursStill ? EpisodeStillBlur.radius : 0, opaque: true)
                    .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight)
                    // BUG-31: episode stills are not all 16:9 (and the poster fallback never is), so
                    // the `.fill` image overflows this fixed frame and the hover lift copies the
                    // overflow as a ghost-doubled subject. Clip inside the frame first.
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius))
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: posterStyle.cornerRadius), surface: .episodeCards)

                // Soft scrim so the rating badge reads over bright stills.
                if rating != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius))
                    .allowsHitTesting(false)
                }

                if let progress {
                    // AES-4/EP-2: the Continue Watching cards' bar (`LandscapeCard`), clipped to
                    // this card's corners and lifted with the still by `tileFocusLift` below.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle()
                                .fill(Theme.Palette.progress)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 6)
                    .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isWatched { WatchedCheckBadge().padding(10) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let rating { ratingBadge(rating).padding(10) }
            }
            .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight)
            // Whole-card system lift — see PosterCard: still, scrim, and badges move as one.
            // BUG-31/BUG-25: highlight geometry pinned to the card's own corner radius; goes
            // still under "No Zoom on Focus" (which this tile used to ignore).
            .tileFocusLift(cornerRadius: posterStyle.cornerRadius)

            Text(heading)
                .font(Theme.Font.cardTitle)
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Theme.Spacing.xs)
                .frame(width: Theme.Size.episodeWidth, alignment: .leading)
                // UX-15 class: keep the artwork↔title gap constant under the system lift.
                .modifier(CardCaptionFocusDrop(
                    mode: noZoomOnFocus ? .still(ringed: false) : .systemLift,
                    isFocused: isFocused,
                    artworkHeight: Theme.Size.episodeHeight
                ))
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    /// Heatmap-colored IMDb rating chip (green ≥ 8.5, lime ≥ 7, orange ≥ 5.5, red below).
    private func ratingBadge(_ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
            Text(String(format: "%.1f", value))
        }
        .font(Theme.Font.meta)
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ratingColor(value), in: Capsule())
    }

    private func ratingColor(_ value: Double) -> Color {
        switch value {
        case 8.5...: return Color(red: 0.22, green: 0.78, blue: 0.36)
        case 7.0..<8.5: return Color(red: 0.68, green: 0.85, blue: 0.25)
        case 5.5..<7.0: return .orange
        default: return Color(red: 0.9, green: 0.3, blue: 0.25)
        }
    }

    private var thumbnailURL: String {
        let thumb: String? = episode.thumbnail
        if let thumb, !thumb.isEmpty { return thumb }
        return fallbackImage ?? ""
    }

    private var heading: String {
        if let e = episode.episode?.value {
            return String(localized: "E\(e) \u{00B7} \(episode.title)")
        }
        return episode.title
    }
}

/// Green circular checkmark marking a watched episode (tvOS take on mobile's watched badge).
struct WatchedCheckBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(Theme.Font.meta)
            .foregroundStyle(.white)
            .padding(7)
            .background(Color(red: 0.22, green: 0.78, blue: 0.36).opacity(0.95), in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// FEAT-24: one season in the poster selector — 2:3 artwork with the season label under it, the
/// selected season outlined in the accent (the same "selected vs focused" split the text chips
/// draw with colour). Same idioms as `TrailerThumbCard`: `.borderless` button, `tileFocusLift`
/// (goes still under No Zoom on Focus), `Theme.Font.cardTitle` caption.
private struct SeasonPosterCard: View {
    let label: String
    let imageURL: String?
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused
    // BUG-32: read the shared corner token instead of hardcoding Theme.Radius.card, so the
    // Poster Style → Corners setting reaches this card (both states, focused and not).
    @Environment(\.posterStyle) private var posterStyle
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    // FEAT-26: 180×270 — the same miniPoster size as More Like This, so the season row no longer
    // reads as the smallest tile on the detail screen (it shipped at 120×180).
    private static let width: CGFloat = Theme.Size.miniPosterWidth
    private static let height: CGFloat = Theme.Size.miniPosterHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack {
                if let imageURL, !imageURL.isEmpty {
                    CachedAsyncImage(string: imageURL)
                } else {
                    Theme.Palette.surface
                    // FEAT-26: at 180×270 the caption2 label got lost in the empty surface — meta
                    // (caption semibold) with md padding gives the placeholder some presence.
                    Text(label)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(Theme.Spacing.md)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius))
            // FEAT-26: these cards were the only detail tiles without the card-depth treatment —
            // same surface as the poster rows, attached to the artwork like EpisodeThumbCard.
            .nuvioCardDepth(RoundedRectangle(cornerRadius: posterStyle.cornerRadius), surface: .posters)
            .overlay {
                RoundedRectangle(cornerRadius: posterStyle.cornerRadius)
                    .strokeBorder(isSelected ? Theme.Palette.accent : Color.white.opacity(0.10), lineWidth: isSelected ? 4 : 1)
            }
            .tileFocusLift(cornerRadius: posterStyle.cornerRadius)

            Text(label)
                .font(Theme.Font.cardTitle)
                .foregroundStyle(isFocused || isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(width: Self.width, alignment: .leading)
                // UX-15 (beta.13 review, frame-verified at t=77.5): the system lift grows the
                // artwork's bottom edge over this caption. Same fix as PosterCard's BUG-54
                // treatment — the focused caption drops by the lift's bottom expansion.
                .modifier(CardCaptionFocusDrop(
                    mode: noZoomOnFocus ? .still(ringed: false) : .systemLift,
                    isFocused: isFocused,
                    artworkHeight: Self.height
                ))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The blur Blur Unwatched Episodes puts over a still (mobile blurs by 18 dp; this is the same
/// softness at television scale: the picture stays recognisably a scene, the detail is gone).
enum EpisodeStillBlur {
    static let radius: CGFloat = 22
}

/// One episode as a row of the list layout (Settings → Detail Page → Episode Cards → List): the
/// 16:9 still with its watched / rating / progress marks beside the title, the air date line and
/// the synopsis. Text uses semantic colours so the `.card` button style owns every focus state.
/// At accessibility text sizes the still moves above the text and takes the full width.
private struct EpisodeListRow: View {
    let episode: MetaVideo
    let fallbackImage: String?
    var rating: Double? = nil
    var isWatched: Bool = false
    var progress: Double? = nil
    var blursStill: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.posterStyle) private var posterStyle

    private static let stillWidth: CGFloat = 360
    private static let stillHeight: CGFloat = 203   // 16:9

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.lg))
        layout {
            still
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(heading)
                    .font(Theme.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let caption {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                let overview: String? = episode.overview
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var still: some View {
        let radius = posterStyle.cornerRadius
        return ZStack(alignment: .bottom) {
            CachedAsyncImage(string: thumbnailURL)
                .blur(radius: blursStill ? EpisodeStillBlur.radius : 0, opaque: true)
                .frame(width: Self.stillWidth, height: Self.stillHeight)
                .clipped()
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle()
                            .fill(Theme.Palette.progress)
                            .frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 6)
                .allowsHitTesting(false)
            }
        }
        .frame(width: Self.stillWidth, height: Self.stillHeight)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isWatched { WatchedCheckBadge().padding(10) }
        }
        .overlay(alignment: .bottomTrailing) {
            if let rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .accessibilityHidden(true)
                    Text(String(format: "%.1f", rating))
                }
                .font(Theme.Font.meta)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(10)
            }
        }
        .accessibilityHidden(true)
    }

    private var thumbnailURL: String {
        let thumb: String? = episode.thumbnail
        if let thumb, !thumb.isEmpty { return thumb }
        return fallbackImage ?? ""
    }

    private var heading: String {
        if let e = episode.episode?.value {
            return String(localized: "\(e). \(episode.title)")
        }
        return episode.title
    }

    /// "S1E4 \u{00B7} 2024-04-12 \u{00B7} 52 min"; nil when nothing is known.
    private var caption: String? {
        var parts: [String] = []
        if let s = episode.season?.value, let e = episode.episode?.value {
            parts.append("S\(s)E\(e)")
        }
        let released: String? = episode.released
        if let released, released.count >= 10 {
            parts.append(String(released.prefix(10)))
        }
        if let runtime = episode.runtime?.value, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
