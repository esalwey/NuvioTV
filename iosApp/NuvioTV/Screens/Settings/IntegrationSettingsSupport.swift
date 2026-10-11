import SwiftUI
import SharedCore

// MARK: - TMDB enrichment groups

/// The eleven groups of a title TMDB can fill in or replace, in the order the shared settings list
/// them (`TmdbSettings.useTrailers` ... `useCollections`). One case per `TmdbSettingsRepository.setUseX`.
enum TmdbModule: String, CaseIterable, Hashable {
    case trailers, artwork, basicInfo, details, credits, productions, networks, episodes
    case seasonPosters, moreLikeThis, collections

    var title: String {
        switch self {
        case .trailers: return String(localized: "Trailers")
        case .artwork: return String(localized: "Artwork")
        case .basicInfo: return String(localized: "Basic Info")
        case .details: return String(localized: "Details")
        case .credits: return String(localized: "Credits")
        case .productions: return String(localized: "Productions")
        case .networks: return String(localized: "Networks")
        case .episodes: return String(localized: "Episodes")
        case .seasonPosters: return String(localized: "Season Posters")
        case .moreLikeThis: return String(localized: "More Like This")
        case .collections: return String(localized: "Collections")
        }
    }

    var subtitle: String {
        switch self {
        case .trailers: return String(localized: "Trailer candidates from TMDB videos for the trailer section")
        case .artwork: return String(localized: "Logo and backdrop images from TMDB")
        case .basicInfo: return String(localized: "Description, genres, and rating from TMDB")
        case .details: return String(localized: "Runtime, status, country, and language from TMDB")
        case .credits: return String(localized: "Cast with photos, director, and writer from TMDB")
        case .productions: return String(localized: "Production companies from TMDB")
        case .networks: return String(localized: "Networks with logos from TMDB")
        case .episodes: return String(localized: "Episode titles, overviews, thumbnails, and runtime from TMDB")
        case .seasonPosters: return String(localized: "Use TMDB season posters in the season selector for series")
        case .moreLikeThis: return String(localized: "TMDB recommendations on the title page")
        case .collections: return String(localized: "TMDB movie collections in release order")
        }
    }
}

/// Snapshot of the eleven `TmdbSettings.use*` flags. Every group defaults on, as in the shared settings.
struct TmdbModuleFlags: Equatable {
    private var values: [TmdbModule: Bool] = [:]

    init() {}

    init(_ settings: TmdbSettings) {
        values = [
            .trailers: settings.useTrailers,
            .artwork: settings.useArtwork,
            .basicInfo: settings.useBasicInfo,
            .details: settings.useDetails,
            .credits: settings.useCredits,
            .productions: settings.useProductions,
            .networks: settings.useNetworks,
            .episodes: settings.useEpisodes,
            .seasonPosters: settings.useSeasonPosters,
            .moreLikeThis: settings.useMoreLikeThis,
            .collections: settings.useCollections,
        ]
    }

    func isOn(_ module: TmdbModule) -> Bool { values[module] ?? true }
}

/// Backs the pushed "Enrichment Groups" page. The page is pushed over the Settings split, whose own
/// model stops watching while it is covered, so this page watches the TMDB settings itself.
@MainActor
final class TmdbModulesViewModel: ObservableObject {
    @Published private(set) var flags = TmdbModuleFlags()
    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        TmdbSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(TmdbSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TmdbSettings else { return }
            self.flags = TmdbModuleFlags(state)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func set(_ module: TmdbModule, _ enabled: Bool) {
        let repo = TmdbSettingsRepository.shared
        switch module {
        case .trailers: repo.setUseTrailers(value: enabled)
        case .artwork: repo.setUseArtwork(value: enabled)
        case .basicInfo: repo.setUseBasicInfo(value: enabled)
        case .details: repo.setUseDetails(value: enabled)
        case .credits: repo.setUseCredits(value: enabled)
        case .productions: repo.setUseProductions(value: enabled)
        case .networks: repo.setUseNetworks(value: enabled)
        case .episodes: repo.setUseEpisodes(value: enabled)
        case .seasonPosters: repo.setUseSeasonPosters(value: enabled)
        case .moreLikeThis: repo.setUseMoreLikeThis(value: enabled)
        case .collections: repo.setUseCollections(value: enabled)
        }
    }

    deinit { watcher?.cancel() }
}

// MARK: - MDBList rating providers

/// The eight MDBList rating providers. The ids are the shared `MdbListMetadataService.PROVIDER_*`
/// constants, in its default priority order; a rating's `source` carries the same id.
enum MdbListProviders {
    static let all = ["imdb", "tmdb", "tomatoes", "metacritic", "trakt", "letterboxd", "audience", "mal"]

    static func name(_ id: String) -> String {
        switch id {
        case "imdb": return "IMDb"
        case "tmdb": return "TMDB"
        case "tomatoes": return "Rotten Tomatoes"
        case "metacritic": return "Metacritic"
        case "trakt": return "Trakt"
        case "letterboxd": return "Letterboxd"
        case "audience": return String(localized: "Audience Score")
        case "mal": return "MyAnimeList"
        default: return id
        }
    }

    /// A full permutation of `all`: unknown ids dropped, missing ones appended (the shared setting
    /// already guarantees this; kept so a stale value can never break the page).
    static func normalized(_ order: [String]) -> [String] {
        var seen = Set<String>()
        let kept = order.filter { all.contains($0) && seen.insert($0).inserted }
        return kept + all.filter { !seen.contains($0) }
    }

    /// Scale of each provider's number, as the phone app shows it: one decimal for IMDb, Letterboxd
    /// and MyAnimeList, a percentage for Rotten Tomatoes and Audience Score, a whole number for the rest.
    static func formattedValue(_ id: String, _ value: Double) -> String {
        switch id {
        case "imdb", "letterboxd", "mal":
            return String(format: "%.1f", value)
        case "tomatoes", "audience":
            return "\(Int(value.rounded()))%"
        default:
            return String(Int(value.rounded()))
        }
    }
}

/// Backs the pushed "Ratings Providers" page (switches + order); same reasoning as `TmdbModulesViewModel`.
@MainActor
final class MdbListProvidersViewModel: ObservableObject {
    @Published private(set) var enabled: Set<String> = Set(MdbListProviders.all)
    @Published private(set) var order: [String] = MdbListProviders.all
    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        MdbListSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(MdbListSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MdbListSettings else { return }
            self.enabled = Set(MdbListProviders.all.filter { state.isProviderEnabled(providerId: $0) })
            self.order = MdbListProviders.normalized(state.providerOrder)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func setEnabled(_ providerId: String, _ isOn: Bool) {
        MdbListSettingsRepository.shared.setProviderEnabled(providerId: providerId, value: isOn)
    }

    /// Moves one provider a step earlier (`-1`) or later (`+1`); tvOS has no drag and drop.
    func move(_ providerId: String, by offset: Int) {
        var next = order
        guard let index = next.firstIndex(of: providerId) else { return }
        let target = index + offset
        guard next.indices.contains(target) else { return }
        next.swapAt(index, target)
        order = next
        MdbListSettingsRepository.shared.setProviderOrder(order: next)
    }

    deinit { watcher?.cancel() }
}
