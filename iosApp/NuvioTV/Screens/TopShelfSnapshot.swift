import Combine
import Foundation
import SharedCore

/// Bridge between the app and the Top Shelf extension. The extension can't link SharedCore, so
/// the app mirrors the active profile's continue-watching rail into a small JSON snapshot in the
/// shared App Group container; the extension reads it and renders `TVTopShelfSectionedContent`.
///
/// `TopShelfItemSnapshot` is duplicated (structurally) in the extension's `ContentProvider.swift`
/// — keep the two Codable shapes in sync if fields change.
enum TopShelf {
    /// Must match the App Group registered on BOTH the app and extension targets in
    /// Signing & Capabilities, and the id in the extension's ContentProvider.
    static let appGroupId = "group.com.nuvio.media.NuvioTV"
    static let snapshotFilename = "top-shelf.json"

    /// The custom URL scheme the extension's actions launch the app with (registered on the
    /// NuvioTV target under Info → URL Types).
    static let urlScheme = "nuviotv"

    /// tvOS only permits writes inside Library/Caches of a group container (the container root
    /// is read-only under tvOS's no-persistent-storage policy). Caches can theoretically be
    /// purged, but the app rewrites the snapshot on every progress change, so that's fine.
    static var snapshotDirectoryURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent("Library/Caches", isDirectory: true)
    }

    static var snapshotURL: URL? {
        snapshotDirectoryURL?.appendingPathComponent(snapshotFilename)
    }
}

/// One continue-watching entry, flattened to what the Top Shelf needs (art + labels) plus what a
/// deep link needs to resume playback or open the title (ids, type, season/episode).
struct TopShelfItemSnapshot: Codable {
    let videoId: String
    let parentMetaId: String
    let parentMetaType: String
    let title: String
    let episodeTitle: String?
    let season: Int?
    let episode: Int?
    let poster: String?
    let background: String?
    let progressPercent: Double?
}

struct TopShelfSnapshot: Codable {
    let generatedAtEpochMs: Int64
    let items: [TopShelfItemSnapshot]
}

/// Lives at the ContentView root (started once a profile is entered). Watches the shared
/// watch-progress state and rewrites the App Group snapshot on every change — including profile
/// switches, since the repository re-emits for the newly scoped profile.
@MainActor
final class TopShelfUpdater: ObservableObject {
    private var watcher: FlowWatcher?
    private var sourceWatcher: FlowWatcher?
    private var traktSettingsWatcher: FlowWatcher?
    private var lastDaysCap: Int32?

    func start() {
        guard watcher == nil else { return }
        WatchProgressRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] _ in
            DispatchQueue.main.async { self?.writeSnapshot() }
        }
        // BUG-75: the row's gates (active provider's dropped-show filter + recency window) live
        // outside uiState — a source switch or days-cap edit must rewrite the snapshot too.
        sourceWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.activeSourceState) { [weak self] _ in
            DispatchQueue.main.async { self?.writeSnapshot() }
        }
        traktSettingsWatcher = FlowWatcherKt.watch(TraktSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let state = emitted as? TraktSettingsUiState else { return }
            DispatchQueue.main.async {
                guard let self, self.lastDaysCap != state.continueWatchingDaysCap else { return }
                self.lastDaysCap = state.continueWatchingDaysCap
                self.writeSnapshot()
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        sourceWatcher?.cancel()
        sourceWatcher = nil
        traktSettingsWatcher?.cancel()
        traktSettingsWatcher = nil
        lastDaysCap = nil
    }

    private func writeSnapshot() {
        guard let url = TopShelf.snapshotURL else {
            print("[TopShelf] App Group container is nil — App Groups capability missing/unsigned on the app target")
            return
        }

        // BUG-75: same provider-aware row Home builds (dropped shows and out-of-window entries
        // filtered), scanned short — Top Shelf only ever shows the first 10.
        let entries = WatchProgressRepository.shared.continueWatchingRow(limit: 20)
        let items = entries.prefix(10).map { entry in
            TopShelfItemSnapshot(
                videoId: entry.videoId,
                parentMetaId: entry.parentMetaId,
                parentMetaType: entry.parentMetaType,
                title: entry.title,
                episodeTitle: entry.episodeTitle,
                season: entry.seasonNumber?.value,
                episode: entry.episodeNumber?.value,
                poster: entry.poster,
                background: entry.background ?? entry.episodeThumbnail,
                progressPercent: entry.progressPercent.map { Double(truncating: $0) }
            )
        }
        let snapshot = TopShelfSnapshot(
            generatedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
            items: Array(items)
        )

        // Encode on main (cheap, ≤10 tiny items); write atomically so the extension never reads
        // a torn file.
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = TopShelf.snapshotDirectoryURL
        DispatchQueue.global(qos: .utility).async {
            do {
                if let directory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try data.write(to: url, options: .atomic)
                print("[TopShelf] wrote \(snapshot.items.count) items to \(url.path)")
            } catch {
                print("[TopShelf] write failed: \(error)")
            }
        }
    }
}
