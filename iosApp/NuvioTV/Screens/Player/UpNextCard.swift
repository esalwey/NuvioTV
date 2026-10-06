import SharedCore
import SwiftUI

/// The Up Next card both engines draw bottom-trailing while `NextEpisodeEngine.phase` is not
/// `.hidden` (AES-1): the next episode's still (series artwork when it has none), "Next Episode",
/// the S·E line and title, and a countdown ring with the seconds left. No key legend (VIS-05): both
/// engines follow the system's Up Next grammar — Select plays now, Back keeps the credits playing.
///
/// Never focusable — the mpv controller owns the remote, and on the native engine the interactive
/// twins are the system contextual actions. Neutral glass (a prompt is an action, not a selection —
/// `PlayerChipStyle`), Theme tokens only. The countdown lives in its own ring, never in a line of
/// text that could truncate it away.
///
/// Layout: still · "Next Episode · S1 · E5" over the episode name and status · ring — the same
/// panel surface and type scale as the pause card and the transport bar (`playerPanelGlass()`,
/// AES-7).
struct UpNextCard: View {
    @ObservedObject var engine: NextEpisodeEngine
    /// Artwork when the next episode has no still of its own (series backdrop, else poster).
    let fallbackArtwork: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The series backdrop (`CachedTitleArt`): a 16:9 stand-in for a next episode without a still,
    /// sharper in this frame than the 2:3 poster the players pass as `fallbackArtwork`. Read at init,
    /// like `PlayerEndScreen`, so the card's first frame already draws it — no poster-to-backdrop
    /// swap while the card fades in.
    private let seriesBackdrop: String?

    init(engine: NextEpisodeEngine, fallbackArtwork: String?) {
        _engine = ObservedObject(wrappedValue: engine)
        self.fallbackArtwork = fallbackArtwork
        seriesBackdrop = CachedTitleArt.peek(type: engine.contentType, id: engine.parentMetaId)?.background
    }

    private static let cardWidth: CGFloat = 920
    private static let artworkSize = CGSize(width: 288, height: 162)
    private static let ringSize: CGFloat = 104
    private static let ringLineWidth: CGFloat = 8

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            artwork
            details
                .frame(maxWidth: .infinity, alignment: .leading)
            ring
        }
        .padding(PlayerChipStyle.panelPadding)
        .frame(width: Self.cardWidth, alignment: .leading)
        .playerPanelGlass()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Artwork

    private var artworkURL: String? {
        let still: String? = engine.nextVideo?.thumbnail
        return CachedTitleArt.nonEmpty(still) ?? seriesBackdrop ?? fallbackArtwork
    }

    private var artwork: some View {
        CachedAsyncImage(string: artworkURL)
            .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: - Text

    /// "Next Episode · S1 · E5" — one eyebrow line instead of two, with the player's localized code.
    private var eyebrow: String {
        let label = String(localized: "Next Episode")
        guard let season = engine.nextVideo?.season?.value, let episode = engine.nextVideo?.episode?.value else {
            return label
        }
        return "\(label) \u{00B7} \(PlaybackTitleParts.episodeCode(season: season, episode: episode))"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(eyebrow)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            Text(CachedTitleArt.nonEmpty(engine.nextVideo?.title) ?? engine.nextEpisodeTitle)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            status
                .padding(.top, Theme.Spacing.xxs)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch engine.phase {
        case .noStream:
            Label("No stream found for the next episode.", systemImage: "exclamationmark.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
        case .stillWatching:
            Label("Still watching?", systemImage: "questionmark.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .upNext where engine.isWaitingForSource:
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().scaleEffect(0.6)
                Text("Finding a source\u{2026}")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
        case .upNext where engine.countdownPaused:
            Label("Paused", systemImage: "pause.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        case .upNext:
            if let source = engine.sourceName, engine.isStreamReady {
                Text(source)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        case .hidden:
            EmptyView()
        }
    }

    // MARK: - Countdown ring

    private var progress: CGFloat {
        guard engine.phase == .upNext, engine.countdownTotal > 0 else { return 0 }
        return CGFloat(engine.countdownRemaining) / CGFloat(engine.countdownTotal)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.textPrimary.opacity(0.2), lineWidth: Self.ringLineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.Palette.textPrimary,
                        style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: engine.countdownRemaining)
            ringCenter
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
    }

    @ViewBuilder
    private var ringCenter: some View {
        switch engine.phase {
        case .upNext where engine.countdownRemaining > 0:
            Text(verbatim: "\(engine.countdownRemaining)")
                .font(Theme.Font.screenTitle.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityLabel(Text("Playing in \(engine.countdownRemaining) s"))
        case .upNext:
            if engine.isStreamReady {
                Image(systemName: PlayerChipStyle.nextSymbol)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            } else {
                ProgressView()
            }
        case .stillWatching:
            Image(systemName: "questionmark")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .noStream:
            Image(systemName: "exclamationmark")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .hidden:
            EmptyView()
        }
    }
}

/// "Loading S1 · E5…" while a jump from the Episodes tab finds the episode's stream (both engines,
/// where the Up Next card sits). The jump used to run silently for seconds once the tab had closed,
/// and read as a selection that did nothing. Never focusable.
struct EpisodeJumpStatus: View {
    let video: MetaVideo

    var body: some View {
        PlayerChipCaption(text: Self.text(for: video), showsProgress: true)
    }

    static func text(for video: MetaVideo) -> String {
        let name: String
        if let season = video.season?.value, let episode = video.episode?.value {
            name = PlaybackTitleParts.episodeCode(season: season, episode: episode)
        } else {
            name = video.title
        }
        return String(localized: "player.jump.loading",
                      defaultValue: "Loading \(name)\u{2026}",
                      comment: "Player: an episode picked in the Episodes tab is finding its stream. The argument is the episode, e.g. \"S1 · E5\".")
    }
}
