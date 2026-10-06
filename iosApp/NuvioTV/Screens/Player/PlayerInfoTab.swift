import SharedCore
import SwiftUI

/// One label/value row of the Info tab's stream section.
struct NativeInfoRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Static what's-playing header for the Info tab, captured once from the PlaybackContext.
struct NativeInfoHeader: Equatable {
    let title: String
    /// "S1 · E4 · Episode name" for series (falls back to the stream label when the episode list
    /// doesn't carry a name), else the stream's own label (release name / addon line).
    let subtitle: String?
    let synopsis: String?
    let poster: String?
    /// True when `poster` is an episode still (16:9) rather than a 2:3 poster.
    let landscapeArtwork: Bool
    /// Release name / addon line — shown as a secondary line under the synopsis when it isn't
    /// already the subtitle.
    let streamLabel: String?

    init(context: PlaybackContext) {
        // AES-8: the series heads an episode's header when the meta cache knows it — the launch
        // title ("S1E4 · Name") repeated the subtitle line below it. The episode's own name then
        // moves to the subtitle: from the episode list, else out of that launch title (a launch
        // path without the list), so it is never lost. Without the series, the launch title stays
        // the title and the subtitle is built as before.
        let names = PlaybackTitleParts(context: context)
        title = names.series ?? context.title
        var parts: [String] = []
        var usedStreamLabel = false
        if let s = context.season, let e = context.episode {
            parts.append(String(localized: "S\(s) · E\(e)"))
            let listedName = context.episodes.first { $0.season?.value == s && $0.episode?.value == e }?.title
            let episodeName = names.series != nil ? names.episodeName : listedName
            if let episodeName, !episodeName.isEmpty {
                parts.append(episodeName)
            } else if let st = context.streamTitle, !st.isEmpty {
                parts.append(st); usedStreamLabel = true
            }
        } else if let st = context.streamTitle, !st.isEmpty {
            parts.append(st); usedStreamLabel = true
        }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        synopsis = context.synopsis.flatMap { $0.isEmpty ? nil : $0 }
        let still = context.episodeStill.flatMap { $0.isEmpty ? nil : $0 }
        poster = still ?? context.poster.flatMap { $0.isEmpty ? nil : $0 }
        landscapeArtwork = still != nil
        streamLabel = usedStreamLabel ? nil : context.streamTitle.flatMap { $0.isEmpty ? nil : $0 }
    }
}
