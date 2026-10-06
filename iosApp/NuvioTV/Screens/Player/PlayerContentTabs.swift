import SharedCore
import SwiftUI

// The content tabs under the scrubber, shared by both engines. The native screen hosts the
// Episodes and Stream Info tabs in `AVPlayerViewController.customInfoViewControllers` (the system
// draws Info and Chapters itself); the mpv chrome (`MPVTransportFocusView`) shows the same Episodes
// and Stream Info views, plus `PlayerInfoSummaryTab` and `PlayerChaptersTab`, which reproduce the
// system's Info and Chapters tabs from the same data the native screen hands AVKit (the item's
// `externalMetadata` and `navigationMarkerGroups`).

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

struct PlayerInfoSummaryTab: View {
    let summary: PlayerInfoSummary

    static let tabHeight: CGFloat = 340
    private static let artHeight: CGFloat = 280

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            if let art = summary.header.poster {
                CachedAsyncImage(string: art, contentMode: .fill)
                    .frame(width: summary.header.landscapeArtwork ? Self.artHeight * 16 / 9 : Self.artHeight * 2 / 3,
                           height: Self.artHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let line = summary.episodeLine {
                    Text(verbatim: line)
                        .font(Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: summary.header.title)
                    .font(Font.title3)
                    .fontWeight(.bold)
                    .lineLimit(2)
                if summary.ageRating != nil || summary.genres != nil {
                    HStack(spacing: Theme.Spacing.sm) {
                        if let rating = summary.ageRating {
                            Text(verbatim: rating)
                                .font(Font.caption.weight(.semibold))
                                .padding(.horizontal, Theme.Spacing.xs)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1.5))
                        }
                        if let genres = summary.genres {
                            Text(verbatim: genres)
                                .font(Font.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                if let synopsis = summary.header.synopsis {
                    Text(verbatim: synopsis)
                        .font(Font.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The system Chapters tab, reproduced: a shelf of chapter cards (title and start time); selecting
/// one plays from there. The chapter that holds the playhead is focused first.
struct PlayerChaptersTab: View {
    let chapters: [PlayerChapter]
    let positionSec: Double
    let onSelect: (PlayerChapter) -> Void

    @FocusState private var focused: Double?

    static let tabHeight: CGFloat = 260
    private static let cardSize = CGSize(width: 360, height: 150)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.xl) {
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
        return Button { onSelect(chapter) } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(verbatim: chapter.title)
                    .font(Font.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: Theme.Spacing.xs) {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: PlayerChromeFormat.time(chapter.start))
                        .monospacedDigit()
                }
                .font(Font.caption)
                .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
            .background(Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.borderless)
        .focused($focused, equals: chapter.id)
        .accessibilityLabel(Text(verbatim: "\(chapter.title), \(PlayerChromeFormat.time(chapter.start))"))
    }
}
