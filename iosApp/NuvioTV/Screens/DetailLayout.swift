import SharedCore

/// The lower sections of the detail page that Settings → Detail Page can switch on and off and put
/// in order. Actions and Overview are not here: they are the header block and only toggle
/// (`DetailLayout.showsActions` / `showsOverview`).
enum DetailSection: Hashable, CaseIterable {
    case production, episodes, cast, collection, trailers, moreLikeThis, comments, details

    /// The shared `MetaScreenSectionKey.name` this section is stored under.
    init?(kotlinName: String) {
        switch kotlinName {
        case "PRODUCTION": self = .production
        case "EPISODES": self = .episodes
        case "CAST": self = .cast
        case "COLLECTION": self = .collection
        case "TRAILERS": self = .trailers
        case "MORE_LIKE_THIS": self = .moreLikeThis
        case "COMMENTS": self = .comments
        case "DETAILS": self = .details
        default: return nil
        }
    }
}

/// Backdrop treatment behind the detail page (shared `MetaScreenBackgroundMode`).
enum DetailBackgroundMode: Hashable, CaseIterable {
    /// Sharp backdrop (and the muted trailer loop), as the page has always looked.
    case normal
    /// The backdrop as a soft, darkened wash.
    case cinematic
    /// A tint taken from the backdrop, with the artwork fading into it.
    case dominantColor

    /// `MetaScreenBackgroundMode.name`.
    init(kotlinName: String) {
        switch kotlinName {
        case "Cinematic": self = .cinematic
        case "DominantColor": self = .dominantColor
        default: self = .normal
        }
    }

    /// The persisted key the shared repository parses (`MetaScreenBackgroundMode.parse`).
    var key: String {
        switch self {
        case .normal: return "normal"
        case .cinematic: return "cinematic"
        case .dominantColor: return "dominant_color"
        }
    }

    var title: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .cinematic: return String(localized: "Cinematic")
        case .dominantColor: return String(localized: "Dominant Color")
        }
    }

    var summary: String {
        switch self {
        case .normal:
            return String(localized: "The sharp backdrop, with the trailer playing behind the page when it has one.")
        case .cinematic:
            return String(localized: "A soft, darkened wash of the backdrop. No trailer in the background.")
        case .dominantColor:
            return String(localized: "A tint taken from the backdrop, with the artwork fading into it. No trailer in the background.")
        }
    }
}

/// How the episodes of the selected season are laid out (shared `MetaEpisodeCardStyle`).
enum DetailEpisodeCardStyle: Hashable, CaseIterable {
    /// A shelf of 16:9 stills.
    case horizontal
    /// One row per episode: still, title and synopsis.
    case list

    /// `MetaEpisodeCardStyle.name`.
    init(kotlinName: String) {
        self = kotlinName == "List" ? .list : .horizontal
    }

    var key: String {
        switch self {
        case .horizontal: return "horizontal"
        case .list: return "list"
        }
    }

    var title: String {
        switch self {
        case .horizontal: return String(localized: "Horizontal")
        case .list: return String(localized: "List")
        }
    }
}

/// What the shared Detail Page settings ask of `DetailView`, boiled down to plain values so the
/// page can compare, order and gate without touching Kotlin types.
struct DetailLayout: Equatable {
    var showsActions = true
    var showsOverview = true
    /// Enabled lower sections, in display order.
    var sections: [DetailSection] = DetailLayout.defaultSections
    var backgroundMode: DetailBackgroundMode = .normal
    var episodeCardStyle: DetailEpisodeCardStyle = .horizontal
    var blurUnwatchedEpisodes = false

    /// The page as it was before the layout became configurable (and the Apple TV's default order).
    static let defaultSections: [DetailSection] = [
        .production, .episodes, .cast, .collection, .trailers, .moreLikeThis, .comments, .details,
    ]

    init() {}

    /// From plain values: the enabled lower section keys in order (`MetaScreenSectionKey.name`),
    /// the two header toggles and the layout options (`.name` of the Kotlin enums).
    init(
        lowerSectionNames: [String],
        showsActions: Bool,
        showsOverview: Bool,
        backgroundModeName: String,
        episodeCardStyleName: String,
        blurUnwatchedEpisodes: Bool
    ) {
        var seen = Set<DetailSection>()
        sections = lowerSectionNames.compactMap(DetailSection.init(kotlinName:)).filter { seen.insert($0).inserted }
        self.showsActions = showsActions
        self.showsOverview = showsOverview
        backgroundMode = DetailBackgroundMode(kotlinName: backgroundModeName)
        episodeCardStyle = DetailEpisodeCardStyle(kotlinName: episodeCardStyleName)
        self.blurUnwatchedEpisodes = blurUnwatchedEpisodes
    }

    /// From the shared settings state. `MetaScreenSectionLayout` applies the Apple TV default order
    /// while the stored order is the untouched synced one.
    init(state: MetaScreenSettingsUiState) {
        let lower = MetaScreenSectionLayout.shared.lowerSectionKeys(items: state.items).map { $0.name }
        self.init(
            lowerSectionNames: lower,
            showsActions: Self.isOn("ACTIONS", in: state.items),
            showsOverview: Self.isOn("OVERVIEW", in: state.items),
            backgroundModeName: state.backgroundMode.name,
            episodeCardStyleName: state.episodeCardStyle.name,
            blurUnwatchedEpisodes: state.blurUnwatchedEpisodes
        )
    }

    /// A section missing from the list counts as on (the shared default).
    private static func isOn(_ keyName: String, in items: [MetaScreenSectionItem]) -> Bool {
        items.first { $0.key.name == keyName }?.enabled ?? true
    }
}
