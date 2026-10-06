//
//  ContentProvider.swift
//  NuvioTopShelf
//
//  Created by Christian Turnbull on 7/3/26.
//

import Foundation
import TVServices

/// Top Shelf extension: renders the Continue Watching rail on the Apple TV home screen.
///
/// No SharedCore here — the extension can't link the KMP framework. The main app mirrors the
/// active profile's continue-watching entries into `top-shelf.json` in the shared App Group
/// container (see the app's `TopShelfSnapshot.swift`); this provider just reads and maps it.
///
/// Actions deep-link back into the app on the `nuviotv://` scheme:
///   click (display) → nuviotv://title?…    play button → nuviotv://resume?…
class ContentProvider: TVTopShelfContentProvider {

    // Keep in sync with the app's TopShelf enum (TopShelfSnapshot.swift).
    private static let appGroupId = "group.com.nuvio.media.NuvioTV"
    private static let snapshotFilename = "top-shelf.json"
    private static let urlScheme = "nuviotv"

    // Mirrors the app's Codable shapes (TopShelfSnapshot.swift).
    private struct ItemSnapshot: Codable {
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

    private struct Snapshot: Codable {
        let generatedAtEpochMs: Int64
        let items: [ItemSnapshot]
    }

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
        else { return nil }

        // tvOS group containers are only writable under Library/Caches — the app writes there.
        let fileURL = containerURL
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(Self.snapshotFilename)
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.items.isEmpty
        else {
            return nil  // falls back to the static Top Shelf image
        }

        let items = snapshot.items.compactMap { topShelfItem(for: $0) }
        guard !items.isEmpty else { return nil }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }

    private func topShelfItem(for entry: ItemSnapshot) -> TVTopShelfSectionedItem? {
        let item = TVTopShelfSectionedItem(identifier: entry.videoId)
        item.title = itemTitle(for: entry)
        item.imageShape = .poster
        if let poster = entry.poster, let url = URL(string: poster) {
            item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
        }

        if let display = displayURL(for: entry) {
            item.displayAction = TVTopShelfAction(url: display)
        }
        if let play = resumeURL(for: entry) {
            item.playAction = TVTopShelfAction(url: play)
        }
        return item
    }

    private func itemTitle(for entry: ItemSnapshot) -> String {
        if let season = entry.season, let episode = entry.episode {
            return "\(entry.title) · S\(season)E\(episode)"
        }
        return entry.title
    }

    private func displayURL(for entry: ItemSnapshot) -> URL? {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "title"
        components.queryItems = [
            URLQueryItem(name: "id", value: entry.parentMetaId),
            URLQueryItem(name: "type", value: entry.parentMetaType),
            URLQueryItem(name: "name", value: entry.title),
            URLQueryItem(name: "poster", value: entry.poster),
        ]
        return components.url
    }

    private func resumeURL(for entry: ItemSnapshot) -> URL? {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "resume"
        var query = [
            URLQueryItem(name: "videoId", value: entry.videoId),
            URLQueryItem(name: "type", value: entry.parentMetaType),
            URLQueryItem(name: "title", value: entry.title),
            URLQueryItem(name: "parentMetaId", value: entry.parentMetaId),
        ]
        if let season = entry.season {
            query.append(URLQueryItem(name: "season", value: String(season)))
        }
        if let episode = entry.episode {
            query.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        components.queryItems = query
        return components.url
    }
}
