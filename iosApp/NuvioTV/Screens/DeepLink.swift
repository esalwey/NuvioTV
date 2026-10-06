import Foundation
import SwiftUI
import SharedCore

/// Deep links into the app, launched by the Top Shelf extension (and any future external entry
/// points). Two forms, both on the `nuviotv://` scheme:
///
///   nuviotv://resume?videoId=…&type=…&title=…&parentMetaId=…&season=…&episode=…
///     → straight into the stream picker for that video (continue watching).
///
///   nuviotv://title?id=…&type=…&name=…&poster=…
///     → the title's Detail page (wrapped in its own NavigationStack).
enum DeepLink: Identifiable {
    case resume(type: String, videoId: String, title: String, parentMetaId: String, season: Int?, episode: Int?)
    case title(preview: MetaPreview)

    var id: String {
        switch self {
        case .resume(_, let videoId, _, _, _, _): return "resume:\(videoId)"
        case .title(let preview): return "title:\(preview.id)"
        }
    }

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme == TopShelf.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name] = item.value
        }
        // With custom schemes the action lands in `host` ("nuviotv://resume?…").
        switch url.host ?? components.path {
        case "resume":
            guard let videoId = params["videoId"], !videoId.isEmpty else { return nil }
            return .resume(
                type: params["type"] ?? "movie",
                videoId: videoId,
                title: params["title"] ?? "",
                parentMetaId: params["parentMetaId"] ?? videoId,
                season: params["season"].flatMap(Int.init),
                episode: params["episode"].flatMap(Int.init)
            )
        case "title":
            guard let id = params["id"], !id.isEmpty else { return nil }
            return .title(preview: MetaPreview(
                id: id,
                type: params["type"] ?? "movie",
                name: params["name"] ?? "",
                poster: params["poster"],
                banner: nil,
                logo: nil,
                posterShape: PosterShape.poster,
                description: nil,
                releaseInfo: nil,
                rawReleaseDate: nil,
                popularity: nil,
                voteCount: nil,
                imdbRating: nil,
                genres: []
            ))
        default:
            return nil
        }
    }
}

/// Full-screen host for a deep-linked Detail page. Owns its own NavigationStack (the tab stacks
/// aren't reachable from a cover) with the same destinations the tab roots register, so pushes
/// from Detail (posters, cast, studios) all resolve.
struct DeepLinkTitleView: View {
    let preview: MetaPreview

    var body: some View {
        NavigationStack {
            DetailView(preview: preview)
                .navigationDestination(for: TitleRoute.self) { route in
                    DetailView(preview: route.preview)
                }
                .navigationDestination(for: PersonRoute.self) { route in
                    PersonDetailView(personId: route.id, personName: route.name)
                }
                .navigationDestination(for: EntityRoute.self) { route in
                    EntityBrowseView(route: route)
                }
        }
    }
}
