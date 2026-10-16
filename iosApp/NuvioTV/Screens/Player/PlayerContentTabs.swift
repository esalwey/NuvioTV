import SharedCore
import SwiftUI

// The content tabs of the tab view (swipe down), shared by both engines. The native screen hosts the
// Episodes and Stream Info tabs in `AVPlayerViewController.customInfoViewControllers` (the system
// draws Info and Chapters itself); the mpv chrome (`MPVTransportFocusView`) shows the same Episodes
// and Stream Info views, plus `PlayerInfoSummaryTab` and `PlayerChaptersTab`, which reproduce the
// system's Info and Chapters tabs from the same data the native screen hands AVKit (the item's
// `externalMetadata` and `navigationMarkerGroups`) and the look measured on the owner's recording
// of the system player (docs/player-spec.md, section 9).

/// Episodes content tab (series): the current season as a shelf of 16:9 stills, the playing one
/// marked and focused first. Selecting another episode plays it — in place when the presenter can
/// swap contexts, else through its stream list.
struct PlayerEpisodesTab: View {
    @ObservedObject var engine: NextEpisodeEngine
    let season: Int?
    let episode: Int?
    let onSelect: (MetaVideo) -> Void

    @State private var picked: String?
    @FocusState private var focused: String?

    init(engine: NextEpisodeEngine, season: Int?, episode: Int?, onSelect: @escaping (MetaVideo) -> Void) {
        _engine = ObservedObject(wrappedValue: engine)
        self.season = season
        self.episode = episode
        self.onSelect = onSelect
    }

    static let tabHeight: CGFloat = 400
    private static let stillSize = CGSize(width: 410, height: 231)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.xl) {
                    ForEach(seasonEpisodes, id: \.key) { entry in
                        card(entry.video, key: entry.key, number: entry.number)
                            .id(entry.key)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollClipDisabled()
            .defaultFocus($focused, currentKey)
            .onAppear {
                if let currentKey { proxy.scrollTo(currentKey, anchor: .leading) }
            }
        }
    }

    private struct Entry {
        let key: String
        let number: Int
        let video: MetaVideo
    }

    private var currentKey: String? {
        guard let season, let episode else { return nil }
        return "\(season)x\(episode)"
    }

    private var seasonEpisodes: [Entry] {
        engine.episodes
            .compactMap { video -> Entry? in
                guard let s = video.season?.value, let e = video.episode?.value else { return nil }
                guard season == nil || s == season else { return nil }
                return Entry(key: "\(s)x\(e)", number: Int(e), video: video)
            }
            .sorted { $0.number < $1.number }
    }

    private func card(_ video: MetaVideo, key: String, number: Int) -> some View {
        let isCurrent = key == currentKey
        let still: String? = video.thumbnail
        return Button {
            guard !isCurrent else { return }
            picked = key
            onSelect(video)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                CachedAsyncImage(string: CachedTitleArt.nonEmpty(still))
                    .frame(width: Self.stillSize.width, height: Self.stillSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay {
                        if picked == key, engine.isSearching {
                            ProgressView()
                        }
                    }
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .hoverEffect(.highlight)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(verbatim: eyebrow(number: number, isCurrent: isCurrent))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(verbatim: video.title)
                        .font(Theme.Font.meta)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                .frame(width: Self.stillSize.width, alignment: .leading)
            }
        }
        .buttonStyle(.borderless)
        .focused($focused, equals: key)
        .accessibilityLabel(Text(verbatim: "\(eyebrow(number: number, isCurrent: isCurrent)), \(video.title)"))
    }

    /// "Episode 5" — "Now Playing · Episode 5" on the current one.
    private func eyebrow(number: Int, isCurrent: Bool) -> String {
        let label = String(localized: "player.episodes.number", defaultValue: "Episode \(number)",
                           comment: "Native player Episodes tab: the episode number above its title.")
        guard isCurrent else { return label }
        let playing = String(localized: "player.episodes.nowPlaying", defaultValue: "Now Playing",
                             comment: "Native player Episodes tab: marks the episode that is playing.")
        return "\(playing) \u{00B7} \(label)"
    }
}

/// Stream Info content tab: the live technical rows (engine, video, audio, subtitles…) plus, on the
/// native engine, the audio format that actually reaches the TV (PLY-A14). Read-only, three columns.
struct PlayerStreamInfoTab: View {
    @ObservedObject var model: PlayerTopPanelModel
    /// The delivered audio format, read live (native remux); nil when the engine has none to add.
    let deliveredAudio: () -> String?

    static let tabHeight: CGFloat = 340

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.xl, alignment: .topLeading),
                                 count: 3),
                  alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(verbatim: row.label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: row.value)
                        .font(Theme.Font.meta)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rows: [NativeInfoRow] {
        var rows = model.info.rows
        if let delivered = deliveredAudio() {
            let label = String(localized: "player.info.audioFormat", defaultValue: "Audio format",
                               comment: "Native player Stream Info tab: the audio format sent to the TV or receiver.")
            let row = NativeInfoRow(label: label, value: delivered)
            if let audioIndex = rows.firstIndex(where: { $0.label == String(localized: "Audio") }) {
                rows.insert(row, at: audioIndex + 1)
            } else {
                rows.append(row)
            }
        }
        return rows
    }
}

/// What the system Info tab shows on the native engine, from the same data the coordinator puts in
/// the item's `externalMetadata`: artwork, title, the episode line (series only), the content rating
/// and genres, and the synopsis. Read-only.
struct PlayerInfoSummary: Equatable {
    let header: NativeInfoHeader
    /// "S1 · E4 · Name" — series only, like `iTunesMetadataTrackSubTitle` on the native item.
    let episodeLine: String?
    let ageRating: String?
    let genres: String?

    init(context: PlaybackContext) {
        header = NativeInfoHeader(context: context)
        episodeLine = context.season != nil ? CachedTitleArt.nonEmpty(header.subtitle) : nil
        ageRating = CachedTitleArt.nonEmpty(context.meta?.ageRating)
        let genres = context.meta?.genres ?? []
        self.genres = genres.isEmpty ? nil : genres.prefix(3).joined(separator: ", ")
    }
}

/// The system Info tab, reproduced (35 s of the owner's recording, 30.45 s settled): one Liquid Glass
/// card spanning the width, the artwork on its leading side, the episode line over the synopsis and the
/// runtime with its resolution badge, and a glass capsule "From the Beginning" on its trailing side.
/// Sizes are `PlayerSpec.Layout`'s.
struct PlayerInfoSummaryTab: View {
    let summary: PlayerInfoSummary
    /// The file's length in seconds, for the runtime ("22 min"); 0 = unknown.
    var runtimeSec: Double = 0
    /// "HD" or "4K" beside the runtime; nil = none.
    var resolutionBadge: String? = nil
    let onStartOver: () -> Void

    private static let artHeight: CGFloat = 211
    private static let cardHeight: CGFloat = 252

    var body: some View {
        HStack(alignment: .center, spacing: 41) {
            if let art = summary.header.poster {
                CachedAsyncImage(string: art, contentMode: .fill)
                    .frame(width: summary.header.landscapeArtwork ? Self.artHeight * 16 / 9 : Self.artHeight * 2 / 3,
                           height: Self.artHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(verbatim: summary.episodeLine ?? summary.header.title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let synopsis = summary.header.synopsis {
                    Text(verbatim: synopsis)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color(red: 0.80, green: 0.85, blue: 1.0))
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                metaRow
            }
            .padding(.vertical, Theme.Spacing.xs)
            Spacer(minLength: 0)
            Button(action: onStartOver) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "play.fill")
                    Text(verbatim: String(localized: "From the Beginning"))
                }
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .frame(height: 68)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PlayerSpec.Layout.tabCardRadius, style: .continuous))
    }

    /// "22 min" and the badge, then the content rating and the genres the catalog knows.
    private var metaRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let runtime = runtimeText {
                Text(verbatim: runtime)
            }
            if let badge = resolutionBadge {
                Text(verbatim: badge)
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
            }
            if let rating = summary.ageRating {
                Text(verbatim: rating)
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
            }
            if let genres = summary.genres {
                Text(verbatim: genres)
            }
        }
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
    }

    private var runtimeText: String? {
        guard runtimeSec.isFinite, runtimeSec >= 30 else { return nil }
        let minutes = Int((runtimeSec / 60).rounded())
        if minutes >= 60 {
            return String(localized: "\(minutes / 60) h \(minutes % 60) min")
        }
        return String(localized: "\(max(minutes, 1)) min")
    }
}

/// The system Chapters tab, reproduced (31.5 s of the owner's recording): one shelf of equal cards on a
/// deep violet glass, each with a film-strip glyph in the middle and the chapter's name at its bottom
/// leading corner — no picture, no time; the chapter that holds the playhead says "Current" (the
/// system's "EN COURS") over its name and is focused first. Select plays from that chapter. Cards focus
/// like the Episodes tab's (lift and highlight).
struct PlayerChaptersTab: View {
    let chapters: [PlayerChapter]
    let positionSec: Double
    let onSelect: (PlayerChapter) -> Void

    @FocusState private var focused: Double?

    private static let cardSize = CGSize(width: 328, height: 232)
    private static let cardFill = Color(red: 0.24, green: 0.23, blue: 0.36).opacity(0.82)
    private static let glyph = Color(red: 0.55, green: 0.52, blue: 0.86)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 43) {
                    ForEach(chapters) { chapter in
                        card(chapter).id(chapter.id)
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollClipDisabled()
            .defaultFocus($focused, currentChapter?.id)
            .onAppear {
                if let current = currentChapter { proxy.scrollTo(current.id, anchor: .leading) }
            }
        }
    }

    private var currentChapter: PlayerChapter? {
        chapters.last { $0.start <= positionSec + 0.5 } ?? chapters.first
    }

    private func card(_ chapter: PlayerChapter) -> some View {
        let isCurrent = chapter.id == currentChapter?.id
        let time = PlayerChromeFormat.time(chapter.start)
        let currentTitle = String(localized: "Current")
        return Button { onSelect(chapter) } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Self.cardFill)
                Image(systemName: "film")
                    .font(.system(size: 62, weight: .light))
                    .foregroundStyle(Self.glyph)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 36)
                VStack(alignment: .leading, spacing: 2) {
                    if isCurrent {
                        Text(verbatim: currentTitle.uppercased())
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(red: 0.62, green: 0.70, blue: 1.0))
                    }
                    Text(verbatim: chapter.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(Theme.Spacing.md)
            }
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 28, style: .continuous))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.borderless)
        .focused($focused, equals: chapter.id)
        .accessibilityLabel(Text(verbatim: isCurrent
                                 ? "\(chapter.title), \(time), \(currentTitle)"
                                 : "\(chapter.title), \(time)"))
    }
}
