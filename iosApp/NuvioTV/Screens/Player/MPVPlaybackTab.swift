import SharedCore
import SwiftUI

/// The mpv player's fourth panel tab ("Playback"): what its old swipe-up settings menu carried
/// beyond tracks — playback speed, the diagnostics overlay toggle, an
/// episode jump list and alternate sources — laid out as three columns inside the top panel.
/// Same rules as the other tabs: default tvOS button focus, Theme tokens, no accent.
struct MPVPlaybackTab: View {
    @ObservedObject var state: MPVPlaybackState
    @ObservedObject var engine: NextEpisodeEngine
    /// True when the presenter can swap playback contexts (episode jump / source switching).
    let canSwitchStreams: Bool
    /// Closes the panel after an action that replaces playback (episode jump, source switch).
    let onClose: () -> Void

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            settingsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            if canSwitchStreams, !sortedEpisodes.isEmpty {
                episodesColumn
                    .frame(width: 440)
                    .focusSection()
            }
            if canSwitchStreams {
                sourcesColumn
                    .frame(width: 560)
                    .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
    }

    // MARK: - Speed · diagnostics

    private var settingsColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                PlayerPanelSectionCaption(text: String(localized: "Playback Speed"))
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Button { state.setSpeed?(speed) } label: {
                            HStack(spacing: Theme.Spacing.xxs) {
                                if state.playbackSpeed == speed { Image(systemName: "checkmark") }
                                Text(String(format: "%g\u{00D7}", speed))
                            }
                            .font(Theme.Font.meta)
                        }
                        .accessibilityIdentifier("player.panel.speed.\(speed)")
                    }
                }

                // Both delays live next to their tracks now: subtitle delay in the Subtitles tab's
                // Timing column (beta.15 §B1), audio delay in the Audio tab's right column (LANG-13,
                // fed through `PlayerTopPanelModel.audioDelayMs` by `MPVPlayerPanelAdapter`).

                PlayerPanelSectionCaption(text: String(localized: "Diagnostics")).padding(.top, Theme.Spacing.sm)
                Button { state.showStreamInfo.toggle() } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: state.showStreamInfo ? "checkmark.circle.fill" : "info.circle")
                        Text(state.showStreamInfo ? String(localized: "Hide Stream Info") : String(localized: "Show Stream Info"))
                    }
                    .font(Theme.Font.body)
                }
                .accessibilityIdentifier("player.panel.diagnostics")
            }
        }
    }

    // MARK: - Episodes (jump to any aired episode)

    private var episodesColumn: some View {
        let watched = watchedEpisodeKeys
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            PlayerPanelSectionCaption(text: String(localized: "Episodes"))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(Array(sortedEpisodes.enumerated()), id: \.offset) { _, episode in
                        let isCurrent = isCurrentEpisode(episode)
                        Button {
                            guard !isCurrent else { return }
                            engine.jumpToEpisode(episode)
                            onClose()
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: isCurrent ? "play.fill" : "checkmark")
                                    .font(Theme.Font.caption.weight(.semibold))
                                    .opacity(isCurrent || watched.contains(episodeKey(episode)) ? 1 : 0)
                                    .frame(width: 28)
                                Text(episodeChipLabel(episode)).font(Theme.Font.meta).frame(width: 90, alignment: .leading)
                                Text(episode.title).font(Theme.Font.body).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            Text("Jumping finds a stream automatically and switches playback.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var sortedEpisodes: [MetaVideo] {
        engine.episodes
            .compactMap { video -> (MetaVideo, Int, Int)? in
                guard let s = video.season?.value, let e = video.episode?.value else { return nil }
                return (video, s, e)
            }
            .sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }
            .map { $0.0 }
    }

    /// "season:episode" keys for episodes to mark watched — explicit Watched marks OR
    /// effectively-completed progress (same rule as the Detail screen's badges).
    private var watchedEpisodeKeys: Set<String> {
        WatchedRepository.shared.ensureLoaded()
        WatchProgressRepository.shared.ensureLoaded()
        var keys: Set<String> = []
        for episode in sortedEpisodes {
            guard let s = episode.season?.value, let e = episode.episode?.value else { continue }
            let season = KotlinInt(int: Int32(s)), number = KotlinInt(int: Int32(e))
            let marked = WatchedRepository.shared.isWatched(
                id: engine.parentMetaId, type: engine.contentType, season: season, episode: number)
            let completed = WatchProgressRepository.shared.progressForVideo(
                videoId: "\(engine.parentMetaId):\(s):\(e)", parentMetaId: engine.parentMetaId,
                seasonNumber: season, episodeNumber: number)?.isEffectivelyCompleted == true
            if marked || completed { keys.insert("\(s):\(e)") }
        }
        return keys
    }

    private func episodeKey(_ episode: MetaVideo) -> String {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return episode.id }
        return "\(s):\(e)"
    }

    private func isCurrentEpisode(_ episode: MetaVideo) -> Bool {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return false }
        return s == engine.currentSeason && e == engine.currentEpisode
    }

    private func episodeChipLabel(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value { return "S\(s)E\(e)" }
        return episode.title
    }

    // MARK: - Sources (switch the current video's stream)

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                PlayerPanelSectionCaption(text: String(localized: "Sources"))
                if engine.sourcesLoading { ProgressView().scaleEffect(0.6) }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if engine.sources.isEmpty && !engine.sourcesLoading {
                        Text("No alternate sources found yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    ForEach(Array(engine.sources.prefix(12).enumerated()), id: \.offset) { _, stream in
                        sourceRow(stream)
                    }
                }
            }
            Text("Switching resumes from your last saved position.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .onAppear { engine.loadSources() }
    }

    private func sourceRow(_ stream: StreamItem) -> some View {
        let urlString: String? = stream.playableDirectUrl
        let isCurrent = urlString == engine.currentUrlString
        return Button {
            guard !isCurrent else { return }
            if engine.playSource(stream) { onClose() }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isCurrent ? "play.fill" : "arrow.triangle.2.circlepath")
                    .font(Theme.Font.caption.weight(.semibold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.streamLabel).font(Theme.Font.body).lineLimit(1)
                    Text(stream.addonName).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("Playing").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
    }
}
