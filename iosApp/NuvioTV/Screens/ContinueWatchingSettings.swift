import Foundation
import SharedCore

/// How a Continue Watching card is drawn. Mirrors the shared `ContinueWatchingSectionStyle`
/// (Card / Wide / Poster), as a Swift enum so views can switch exhaustively and Settings can hand it
/// to a `Picker`.
enum ContinueWatchingCardStyle: String, CaseIterable, Hashable {
    /// 16:9 artwork with the title underneath (the original Apple TV look).
    case card
    /// The same artwork with the episode line under the title.
    case wide
    /// Portrait poster artwork.
    case poster

    init(shared: ContinueWatchingSectionStyle) {
        // Compared with `==` rather than switched on: Kotlin enums are not guaranteed to import as
        // an exhaustively-switchable Swift enum (see SettingsViewModel.librarySourceModeKey).
        if shared == .wide {
            self = .wide
        } else if shared == .poster {
            self = .poster
        } else {
            self = .card
        }
    }

    var shared: ContinueWatchingSectionStyle {
        switch self {
        case .card: return .card
        case .wide: return .wide
        case .poster: return .poster
        }
    }

    var title: String {
        switch self {
        case .card: return String(localized: "Card")
        case .wide: return String(localized: "Wide")
        case .poster: return String(localized: "Poster")
        }
    }

    var detail: String {
        switch self {
        case .card: return String(localized: "Landscape artwork with the title underneath")
        case .wide: return String(localized: "Landscape artwork with the episode underneath")
        case .poster: return String(localized: "Portrait poster artwork")
        }
    }
}

/// The order of the Continue Watching row. Mirrors the shared `ContinueWatchingSortMode`.
enum ContinueWatchingOrder: String, CaseIterable, Hashable {
    /// Most recently watched first.
    case recent
    /// Released episodes first, episodes that have not aired yet at the end.
    case streaming
    /// Episodes that have not aired yet leave the row and wait in Upcoming.
    case splitUpcoming

    init(shared: ContinueWatchingSortMode) {
        if shared == .streamingStyle {
            self = .streaming
        } else if shared == .splitUpcoming {
            self = .splitUpcoming
        } else {
            self = .recent
        }
    }

    var shared: ContinueWatchingSortMode {
        switch self {
        case .recent: return .default_
        case .streaming: return .streamingStyle
        case .splitUpcoming: return .splitUpcoming
        }
    }

    var title: String {
        switch self {
        case .recent: return String(localized: "Most Recent")
        case .streaming: return String(localized: "Aired First")
        case .splitUpcoming: return String(localized: "Upcoming Separately")
        }
    }

    var detail: String {
        switch self {
        case .recent: return String(localized: "Everything by when you last watched it")
        case .streaming: return String(localized: "Episodes that have aired first, upcoming ones at the end")
        case .splitUpcoming: return String(localized: "Episodes that have not aired move to the Upcoming row")
        }
    }
}

/// A Swift snapshot of the shared Continue Watching preferences (`ContinueWatchingPreferencesUiState`),
/// minus the dismissed-card bookkeeping. Equatable so a publisher only re-renders on a real change.
/// Shared by Settings (editing) and Home (rendering).
struct ContinueWatchingSettings: Equatable {
    var isVisible = true
    var style = ContinueWatchingCardStyle.card
    var order = ContinueWatchingOrder.recent
    var useEpisodeThumbnails = true
    var blurUnwatched = false
    var upNextFromFurthestEpisode = true
    var showUnairedNextUp = true
    var showResumePromptOnLaunch = true

    init() {}

    init(_ state: ContinueWatchingPreferencesUiState) {
        isVisible = state.isVisible
        style = ContinueWatchingCardStyle(shared: state.style)
        order = ContinueWatchingOrder(shared: state.sortMode)
        useEpisodeThumbnails = state.useEpisodeThumbnails
        blurUnwatched = state.blurNextUp
        upNextFromFurthestEpisode = state.upNextFromFurthestEpisode
        showUnairedNextUp = state.showUnairedNextUp
        showResumePromptOnLaunch = state.showResumePromptOnLaunch
    }

    /// The live shared state, or the defaults while it has not loaded.
    static func current() -> ContinueWatchingSettings {
        ContinueWatchingPreferencesRepository.shared.ensureLoaded()
        guard let state = ContinueWatchingPreferencesRepository.shared.uiState.value_ as? ContinueWatchingPreferencesUiState else {
            return ContinueWatchingSettings()
        }
        return ContinueWatchingSettings(state)
    }

    /// Episode stills only exist on the landscape styles; a poster card never uses them.
    var showsEpisodeThumbnails: Bool { style != .poster && useEpisodeThumbnails }
}
