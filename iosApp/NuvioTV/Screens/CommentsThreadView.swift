import SwiftUI
import SharedCore

/// A Trakt comment thread to show full screen: a title's, or one episode's (`season` and `episode`
/// set). Identifiable so it can drive `.fullScreenCover(item:)`.
struct CommentsThreadRoute: Identifiable {
    let meta: MetaDetails
    var season: Int?
    var episode: Int?
    /// "S2E4 · Title" for an episode thread; nil for the title's own.
    var heading: String?

    var id: String { "\(meta.id)|\(season.map(String.init) ?? "-")|\(episode.map(String.init) ?? "-")" }
}

/// Pages through one comment thread (`TraktCommentsSwiftBridge`: a Kotlin throw would end the
/// process, the bridge turns every failure into nil). The first page is usually already in the
/// shared repository's cache, so the thread opens instantly from the inline section.
@MainActor
final class CommentsThreadModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    @Published private(set) var comments: [TraktCommentReview] = []
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isLoadingMore = false
    @Published private(set) var totalCount = 0

    let route: CommentsThreadRoute
    private var currentPage = 0
    private var pageCount = 1
    /// Bumped on every (re)start so a late completion of an abandoned load cannot apply.
    private var generation = 0
    private var started = false

    init(route: CommentsThreadRoute) {
        self.route = route
    }

    var hasMore: Bool { phase == .loaded && currentPage < pageCount }

    func start() {
        guard !started else { return }
        started = true
        load(page: 1)
    }

    func retry() {
        started = true
        generation += 1
        currentPage = 0
        pageCount = 1
        comments = []
        isLoadingMore = false
        phase = .loading
        load(page: 1)
    }

    func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        load(page: currentPage + 1)
    }

    private func load(page: Int) {
        let token = generation
        isLoadingMore = page > 1
        let completion: (TraktCommentsPage?, Error?) -> Void = { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.apply(result, page: page)
            }
        }
        if let season = route.season, let episode = route.episode {
            TraktCommentsSwiftBridge.shared.episodePageOrNull(
                meta: route.meta,
                season: Int32(season),
                episode: Int32(episode),
                page: Int32(page),
                forceRefresh: false,
                completionHandler: completion
            )
        } else {
            TraktCommentsSwiftBridge.shared.pageOrNull(
                meta: route.meta,
                page: Int32(page),
                forceRefresh: false,
                completionHandler: completion
            )
        }
    }

    private func apply(_ result: TraktCommentsPage?, page: Int) {
        isLoadingMore = false
        guard let result else {
            // A failed first page is an error screen; a failed later page keeps what is shown and
            // leaves "Load More" to try again.
            if page == 1 { phase = .failed }
            return
        }
        currentPage = page
        pageCount = max(Int(result.pageCount), page)
        totalCount = Int(result.itemCount)
        var seen = Set(comments.map(\.id))
        let fresh = result.items.filter { seen.insert($0.id).inserted }
        comments.append(contentsOf: fresh)
        phase = .loaded
    }
}

/// Full-screen list of a comment thread. Menu dismisses the cover (the system's own behaviour);
/// more pages load as the end of the list comes into view, with an explicit "Load More" row as the
/// fallback.
struct CommentsThreadView: View {
    @StateObject private var model: CommentsThreadModel
    @State private var expanded: Set<Int64> = []
    @Environment(\.dismiss) private var dismiss

    init(route: CommentsThreadRoute) {
        _model = StateObject(wrappedValue: CommentsThreadModel(route: route))
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    header
                    content
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(Theme.Spacing.screen)
            }
        }
        .onAppear { model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(model.route.heading ?? String(localized: "Comments"))
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if model.route.heading != nil {
                Text("Comments")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if model.totalCount > 0 {
                Text("\(model.totalCount) from Trakt")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(.bottom, Theme.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 240)
        case .failed:
            emptyState(
                String(localized: "Comments could not be loaded."),
                detail: String(localized: "Check your connection and that Trakt is connected in Settings."),
                showsRetry: true
            )
        case .loaded:
            if model.comments.isEmpty {
                emptyState(
                    String(localized: "No comments yet."),
                    detail: String(localized: "Comments come from Trakt. Connect your account in Settings to read them."),
                    showsRetry: false
                )
            } else {
                ForEach(model.comments, id: \.id) { comment in
                    TraktCommentCard(
                        comment: comment,
                        isExpanded: expanded.contains(comment.id),
                        toggle: { toggle(comment.id) }
                    )
                }
                footer
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if model.hasMore {
            Button {
                model.loadMore()
            } label: {
                Label("Load More Comments", systemImage: "arrow.down.circle")
                    .font(Theme.Font.body)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            // Reaching the end of the list asks for the next page by itself.
            .onAppear { model.loadMore() }
        }
    }

    private func emptyState(_ title: String, detail: String, showsRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(detail)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.lg) {
                if showsRetry {
                    Button("Try Again") { model.retry() }
                        .buttonStyle(.bordered)
                }
                // A page with nothing focusable would leave the remote with nothing to land on.
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xl)
    }

    private func toggle(_ id: Int64) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// One comment as a focusable card (the system `.card` lockup of spec 5.3): select reveals a
/// spoiler or the full text of a long comment. Used by the inline Comments section and the full
/// thread, so both read the same.
struct TraktCommentCard: View {
    let comment: TraktCommentReview
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let hidesForSpoiler = (comment.spoiler || comment.hasSpoilerContent) && !isExpanded
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.md) {
                    Text(comment.authorDisplayName)
                        .font(Theme.Font.meta)
                        .foregroundStyle(.primary)
                    if let rating = comment.rating?.value {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .accessibilityHidden(true)
                            Text("\(rating)/10")
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    }
                    if let date = Self.dateText(comment) {
                        Text(date)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    if comment.review {
                        Text("Review")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if hidesForSpoiler {
                    Label("Contains spoilers \u{2014} press to reveal", systemImage: "eye.slash")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(comment.comment)
                        .font(Theme.Font.body)
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
    }

    private static func dateText(_ comment: TraktCommentReview) -> String? {
        let raw: String? = comment.createdAt
        guard let raw, raw.count >= 10 else { return nil }
        return String(raw.prefix(10))
    }
}
