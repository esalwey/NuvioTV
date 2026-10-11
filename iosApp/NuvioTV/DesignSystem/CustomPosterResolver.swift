import Combine
import SwiftUI
import SharedCore

/// The surfaces a custom poster URL pattern can be switched on for. Raw values are the keys the
/// shared `CustomPosterScreen` enum stores and syncs, so a Swift surface and the Kotlin screen it
/// stands for never drift apart.
enum CustomPosterSurface: String, CaseIterable {
    case home
    case continueWatching = "continue_watching"
    case collections
    case library
    case search
    case details
}

/// The title a card shows, as far as the custom poster pattern cares: its ids and which surface
/// draws it. Built from whatever model the call site already holds.
struct CustomPosterTarget {
    let id: String
    let type: String
    let imdbId: String?
    let surface: CustomPosterSurface
    /// A 16:9 card: resolved with `{shape}` = landscape, and only when the pattern has `{shape}`.
    var landscape = false

    init(id: String, type: String, imdbId: String? = nil, surface: CustomPosterSurface, landscape: Bool = false) {
        self.id = id
        self.type = type
        self.imdbId = imdbId
        self.surface = surface
        self.landscape = landscape
    }

    init(_ item: MetaPreview, _ surface: CustomPosterSurface) {
        let metaId: String = item.id
        self.init(id: metaId, type: item.type, imdbId: nil, surface: surface)
    }

    init(_ item: NuvioLibraryItem, _ surface: CustomPosterSurface) {
        let metaId: String = item.id
        let imdb: String? = item.imdbId
        self.init(id: metaId, type: item.type, imdbId: imdb, surface: surface)
    }

    var asLandscape: CustomPosterTarget {
        var copy = self
        copy.landscape = true
        return copy
    }
}

/// The user's custom poster URL pattern and the surfaces it applies to (Settings > Appearance >
/// Custom Posters, or the phone setup page). Swapping a poster is a pure URL rewrite done where the
/// card draws, so every cached model stays untouched and a switch takes effect at once.
struct CustomPosterConfig: Equatable {
    var pattern = ""
    var enabledSurfaces: Set<String> = Set(CustomPosterSurface.allCases.map(\.rawValue))

    static let off = CustomPosterConfig()

    init() {}

    init(from state: CustomPosterUiState) {
        pattern = state.pattern
        enabledSurfaces = Set(state.enabledScreenKeys)
    }

    var isActive: Bool { !pattern.isEmpty }

    /// The artwork a card should load: the custom URL with the title's own artwork as the
    /// fallback when it fails to load, or just the original when nothing applies (no pattern, the
    /// surface switched off, a title the pattern cannot be filled for).
    func artwork(for target: CustomPosterTarget?, original: String?) -> (primary: String?, fallback: String?) {
        guard isActive, let target, enabledSurfaces.contains(target.surface.rawValue) else {
            return (original, nil)
        }
        let resolved = CustomPosterUrlResolver.shared.resolveForTitle(
            pattern: pattern,
            metaId: target.id,
            type: target.type,
            shape: target.landscape ? "landscape" : "poster",
            explicitImdbId: target.imdbId
        )
        guard let resolved, !resolved.isEmpty, resolved != original else { return (original, nil) }
        return (resolved, original)
    }
}

private struct CustomPosterConfigKey: EnvironmentKey {
    static let defaultValue = CustomPosterConfig.off
}

private struct CustomPosterSurfaceKey: EnvironmentKey {
    static let defaultValue = CustomPosterSurface.home
}

extension EnvironmentValues {
    var customPosterConfig: CustomPosterConfig {
        get { self[CustomPosterConfigKey.self] }
        set { self[CustomPosterConfigKey.self] = newValue }
    }

    /// The surface the cards below belong to, for the shared row views (`CatalogRowView` serves
    /// both Home and Search). Defaults to Home.
    var customPosterSurface: CustomPosterSurface {
        get { self[CustomPosterSurfaceKey.self] }
        set { self[CustomPosterSurfaceKey.self] = newValue }
    }
}

/// Observes the shared `CustomPosterUrlRepository` and republishes a value `CustomPosterConfig` for
/// the environment. Owned at the app root next to `PosterStyleModel`; profile scoped (the repository
/// reloads on a profile switch and after a synced profile blob lands).
@MainActor
final class CustomPosterModel: ObservableObject {
    @Published private(set) var config = CustomPosterConfig.off

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        CustomPosterUrlRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(CustomPosterUrlRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? CustomPosterUiState else { return }
            let next = CustomPosterConfig(from: state)
            if next != self.config { self.config = next }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}

extension View {
    /// Marks the cards below as belonging to `surface` for the custom poster switches.
    func customPosterSurface(_ surface: CustomPosterSurface) -> some View {
        environment(\.customPosterSurface, surface)
    }
}
