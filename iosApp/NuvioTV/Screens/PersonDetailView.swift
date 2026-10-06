import SwiftUI
import SharedCore

/// Detail screen for a cast/crew member (TMDB-backed). Shows photo, name, life dates, known-for, a
/// short biography, and their movie/TV credits as focusable poster rows. Pushed from the Detail
/// screen's cast row via `PersonRoute` (only when the person has a `tmdbId`).
///
/// Relies on the ancestor `NavigationStack` (Home / Search / Library) for navigation: credit posters
/// push `TitleRoute`, which those stacks already resolve to `DetailView`.
struct PersonDetailView: View {
    let personId: Int
    let personName: String

    @StateObject private var model: PersonDetailViewModel

    /// BUG-34: anchors `.prefersDefaultFocus` on the header/bio block so initial focus can never
    /// settle on a credit poster (see `topBlock` for the full story).
    @Namespace private var topFocusNamespace
    /// Drives the focus affordance on the otherwise non-interactive `topBlock`.
    @FocusState private var topFocused: Bool

    init(personId: Int, personName: String) {
        self.personId = personId
        self.personName = personName
        _model = StateObject(wrappedValue: PersonDetailViewModel(personId: personId))
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    topBlock

                    // Each row is its own focus region, so vertical D-pad moves land on the row's
                    // nearest poster instead of geometrically skipping past it (same reason as
                    // DetailView's EpisodesSection).
                    creditsRow(title: String(localized: "Movies"), items: model.person?.movieCredits ?? [])
                        .focusSection()
                    creditsRow(title: String(localized: "TV Shows"), items: model.person?.tvCredits ?? [])
                        .focusSection()

                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.xl)
                    } else if model.failed {
                        Text("Couldn\u{2019}t load details for \(personName). A TMDB API key is required for cast profiles.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Scope must wrap every focus candidate on the page (top block + both credit
                // rows) for `prefersDefaultFocus` on the top block to win.
                .focusScope(topFocusNamespace)
            }
        }
        .onAppear { model.start() }
    }

    // MARK: - Sections

    /// Header + biography as ONE focusable — but non-interactive — region.
    ///
    /// BUG-34: the credit posters used to be this page's only focusable views, so the instant the
    /// async credits landed (~0.5s after open) the focus engine claimed the first Movies poster and
    /// focus-scrolled the page down, stranding the header and biography above the viewport with no
    /// upward focus candidate to get back to. Making the top region focusable fixes both halves:
    /// it exists from the very first frame (the header renders from `personName` before the fetch
    /// returns), so it takes initial focus and *keeps* it when the credits arrive, and it gives
    /// D-pad Up out of the first credit row somewhere real to land.
    ///
    /// Select does nothing here on purpose — `.focusable()` without an action is inert, so this
    /// stays a reading surface, and Menu still pops the screen (no `onExitCommand` anywhere).
    private var topBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            headerBlock

            if let bio = model.person?.biography, !bio.isEmpty {
                Text(bio)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    // Keeps the focusable region shorter than the screen. A focus target taller
                    // than the viewport can only be scrolled to its nearest edge, which would put
                    // the header back off-screen when arrowing Up out of the credits — the exact
                    // symptom being fixed. TMDB bios run arbitrarily long, so they get capped.
                    .lineLimit(8)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        // Full-bleed width so an Up move from *any* poster (rows scroll horizontally, so a poster
        // can sit far to the right) still finds this block geometrically above it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { topFocusPlatter }
        .focusable()
        .focused($topFocused)
        .prefersDefaultFocus(true, in: topFocusNamespace)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.15), value: topFocused)
    }

    /// Focus affordance for `topBlock`. Drawn outside the block's bounds via negative padding so
    /// the unfocused layout is byte-identical to before the fix (no content shift on focus).
    private var topFocusPlatter: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.hero)
            .fill(Theme.Palette.surface.opacity(topFocused ? 0.9 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.hero)
                    .strokeBorder(Color.white.opacity(topFocused ? 0.55 : 0), lineWidth: 2) // neutral by design: the HIG contract bans accent focus rings (FEAT-14 is opt-in only)
            )
            .padding(-Theme.Spacing.md)
    }

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            photo
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(model.person?.name ?? personName)
                    .font(Theme.Font.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if !lifeLine.isEmpty {
                    Text(lifeLine)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                if let known = model.person?.knownFor, !known.isEmpty {
                    // BUG-68 (partial): the department VALUE arrives as TMDB's raw English
                    // string ("Acting"), so a French UI read "Connu(e) pour : Acting". The
                    // biography itself already requests the Metadata Language with an English
                    // fallback — TMDB simply has no localized bios for many people (verified
                    // against tmdb.org's own French page for Harold Perrineau) — but the
                    // department is a closed vocabulary we can localize ourselves.
                    Text("Known for: \(Self.localizedDepartment(known))")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// BUG-68: TMDB's `known_for_department` is a small closed vocabulary, always delivered in
    /// English regardless of the request language. Unknown values pass through untranslated.
    private static func localizedDepartment(_ raw: String) -> String {
        switch raw {
        case "Acting": return String(localized: "Acting")
        case "Directing": return String(localized: "Directing")
        case "Writing": return String(localized: "Writing")
        case "Production": return String(localized: "Production")
        case "Crew": return String(localized: "Crew")
        case "Sound": return String(localized: "Sound")
        case "Camera": return String(localized: "Camera")
        case "Editing": return String(localized: "Editing")
        case "Art": return String(localized: "Art")
        case "Visual Effects": return String(localized: "Visual Effects")
        case "Costume & Make-Up": return String(localized: "Costume & Make-Up")
        case "Lighting": return String(localized: "Lighting")
        default: return raw
        }
    }

    private var photo: some View {
        AsyncImage(url: URL(string: model.person?.profilePhoto ?? "")) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.Palette.surface
                    Image(systemName: "person.fill")
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .frame(width: Theme.Size.posterWidth, height: Theme.Size.posterWidth * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    @ViewBuilder
    private func creditsRow(title: String, items: [MetaPreview]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    // HIG grid gap (40pt), the same as every other shelf.
                    LazyHStack(spacing: Theme.Grid.spacing) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCard(
                                    title: item.name,
                                    imageURL: item.poster,
                                    width: Theme.Size.miniPosterWidth,
                                    height: Theme.Size.miniPosterHeight
                                )
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                            // F13: shared long-press menu (library, watched).
                            .posterContextMenu(item)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: - Derived

    private var lifeLine: String {
        var parts: [String] = []
        if let born = model.person?.birthday, !born.isEmpty { parts.append(String(localized: "Born \(born)")) }
        if let died = model.person?.deathday, !died.isEmpty { parts.append(String(localized: "Died \(died)")) }
        if let place = model.person?.placeOfBirth, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: "  \u{00B7}  ")
    }
}
