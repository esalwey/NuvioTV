import SwiftUI
import SharedCore

/// The destination of a `TitleRoute`. Almost every title opens its Detail page; a Jellyfin / Emby
/// collection (box set) has no page of its own and opens as a poster grid of its members instead,
/// the same screen "See All" opens. The shared catalog decides, so a collection that arrives from
/// Home, Search, the Library or another grid is handled in one place.
struct TitleDestinationView: View {
    let preview: MetaPreview

    var body: some View {
        if let target = ServerCatalog.shared.collectionTarget(meta: preview) {
            CatalogGridView(route: CatalogRoute(key: "collection:\(preview.id)", title: preview.name, target: target))
        } else {
            DetailView(preview: preview)
        }
    }
}

extension CatalogRoute {
    /// A grid that is not a Home section: a server collection's members.
    init(key: String, title: String, target: any CatalogTarget) {
        self.key = key
        self.title = title
        self.target = target
    }
}
