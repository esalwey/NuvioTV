import Combine
import SwiftUI
import UIKit
import SharedCore
// Kotlin's `Collection` model collides with Swift's stdlib `Collection` protocol, and plain
// `SharedCore.Collection` doesn't work either (the framework also exports a *class* named
// `SharedCore`, which wins the qualification). A scoped import shadows the stdlib name in this
// file; the typealias gives the rest of the target an unambiguous name.
import class SharedCore.Collection

/// The shared Kotlin `Collection` model (a group of folders), aliased to dodge the name collision.
typealias NuvioCollection = Collection

// Collections (browse-only, Phase 5b): renders collections curated on mobile — the cloud sync
// already delivers them (SyncManager.pullAllForProfile → CollectionSyncService.pullFromServer).
// A collection appears on Home as a row of folder tiles; a folder opens a tabbed paginated grid
// backed entirely by the shared `FolderDetailRepository`. Structural editing stays on mobile; the
// one on-device edit is a tmdb source's Discover filters (`TmdbFilterEditorView`, from the
// folder grid's Edit Filters button).

/// Navigation value for a collection folder's detail grid. Hashes on the stable ids; carries the
/// titles for the destination's initial render (same wrapper approach as `TitleRoute`).
struct FolderRoute: Hashable {
    let collectionId: String
    let folderId: String
    let folderTitle: String
    /// BUG-38 (folder page): the folder's configured title logo, carried so the page's first
    /// frame already has it — the repository's `folder` lands a beat later. Identity (==/hash)
    /// stays collectionId + folderId; this is display-only. The backdrop is deliberately NOT
    /// drawn on this page (round three, reporter: "if we keep the background image inside, it
    /// makes the text unreadable depending on the image") — it belongs to the Home hero.
    let titleLogoUrl: String?

    init(collectionId: String, folder: CollectionFolder) {
        self.collectionId = collectionId
        self.folderId = folder.id
        self.folderTitle = folder.title
        self.titleLogoUrl = folder.titleLogoUrl.nonBlankTrimmed
    }

    static func == (lhs: FolderRoute, rhs: FolderRoute) -> Bool {
        lhs.collectionId == rhs.collectionId && lhs.folderId == rhs.folderId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(collectionId)
        hasher.combine(folderId)
    }
}

/// One collection as a horizontal row of focusable folder tiles (Home).
struct CollectionRowView: View {
    let collection: NuvioCollection
    /// BUG-38 round three: the focused folder (nil when nothing in this row holds focus), so
    /// Home can hand the folder's configured backdrop + title logo to the pinned hero exactly
    /// the way a catalog row's `onItemFocusChange` hands it a title — the reporter's actual ask
    /// was the Home page, not the folder page.
    var onFolderFocusChange: ((CollectionFolder?) -> Void)? = nil
    @FocusState private var focusedFolderId: String?
    /// BUG-108: read here only for `rowGap`'s doc and `liftedTileZIndex` — the tile's own
    /// treatments read the same keys inside `FolderTile`.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// Pinned-hero card reach (UX-7 extension, device rounds 4–5) — see `rowCardTopReach` /
    /// `rowCardBottomReach` in BrowseComponents for the mechanism. 0 (no-op) outside pinned Home.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach
    /// BUG-87/89 (rc11): see `EnvironmentValues.rowCardLinkFrameFloor`. 0 for every row but Home's
    /// last.
    @Environment(\.rowCardLinkFrameFloor) private var cardLinkFrameFloor
    @Environment(\.posterStyle) private var style

    /// Wave 4 item 6 (tester: the section title sliding onto his "Streaming Services" tiles): the
    /// SHORTEST artwork height in this row, handed to the pinned title's slide clamp so its
    /// intrusion is a fraction of the tile rather than a fixed 46pt — which on a Small square
    /// folder tile (183pt) was a quarter of the artwork, landing on the centred wordmark that IS
    /// the tile's content. See `PinnedRowTitle.maxSlide`.
    ///
    /// The MINIMUM, not the average: this row is deliberately mixed-shape (poster / landscape /
    /// square folders side by side, top-aligned so their reach frames share a top edge), one title
    /// rides over all of them, and the clamp has to protect the tile with the least room. Empty
    /// rows fall back to the poster height — nothing is drawn over, and it matches what a folder
    /// added later would most likely be.
    private var shortestTileHeight: CGFloat {
        collection.folders
            .map { FolderTile.artworkHeight(for: $0, style: style) }
            .min() ?? style.height
    }

    /// BUG-108 / BUG-106: ring mode's lift is a UNIFORM scale of `1 + 2 × 20 / artworkHeight`, so a
    /// 16:9 folder tile grows `2 × 20 × 16/9 ≈ 71pt` of width at every Poster Size — ≈35.5 per side,
    /// which overruns `rowGap` (28) by ≈7.5 and lands the raised tile's 4pt ring on its neighbour's
    /// artwork. Exactly the BUG-106 arithmetic and exactly the BUG-106 dial, applied whenever this
    /// mixed-shape row holds a landscape folder at all (square tiles grow 20/side → 8 clear,
    /// posters ≈13.3/side → ≈14.7 clear, so they keep `rowGap`).
    ///
    /// NOT gated on the ring setting, for two reasons: the native `.borderless` lift grows the tile
    /// by a comparable amount in the default mode, and a row gap that changed with an Appearance
    /// toggle would move this row's scroll geometry under the focus engine. Nothing in the pinned
    /// math reads the gap (`shortestTileHeight`, `shelfMinHeight` and `focusedTileLockupExtent` are
    /// all vertical).
    private var rowGap: CGFloat {
        collection.folders.contains { $0.posterShape == PosterShape.landscape }
            ? Theme.Spacing.landscapeLiftRowGap
            : Theme.Spacing.rowGap
    }

    /// BUG-108: ring mode's lift is SwiftUI's own `.scaleEffect`, which — unlike the native lift —
    /// does not composite the focused card into its own layer, so without an explicit zIndex the
    /// raised tile (and its ring, and its drop shadow) can draw UNDER its unfocused neighbours.
    /// `PosterCard` carries the same rule (PosterCard.swift, `.zIndex(focusMode.raisesFocusedCard …)`);
    /// the difference is WHERE: this one has to sit on the `LazyHStack`'s own child — a zIndex
    /// inside the `NavigationLink` label has no siblings to order against.
    private func liftedTileZIndex(_ folder: CollectionFolder) -> Double {
        let raises = CardFocusMode.resolve(accentFocusRing: accentFocusRing,
                                           noZoomOnFocus: noZoomOnFocus).raisesFocusedCard
        return raises && focusedFolderId == folder.id ? 1 : 0
    }

    /// Wave 4 item 2 (the source fix; tester repro: scroll a mixed-shape collection row right,
    /// then back up — the pinned title parks ON the card artwork, worst at Large).
    ///
    /// `LazyHStack` sizes itself to its REALIZED subviews only. This row deliberately mixes
    /// shapes — poster folders are `1.5 × style.width` tall, square/landscape folders are only
    /// `style.width` tall (`FolderTile.artworkHeight` takes that height from the row's width dial
    /// on purpose — see that function's own comment) — so scrolling past the last poster-shaped
    /// tile drops the stack's natural height by up to `0.5 × style.width` (≈134pt at Large), then
    /// regrows it scrolling back. The up-reveal's settle target is computed against whatever
    /// height happened to be realized at that moment, so a rest taken mid this collapse/regrow
    /// settles against stale geometry and the overlaid title parks on the artwork instead of
    /// above it.
    ///
    /// The fix: float the stack's height on a floor that does NOT depend on which tiles are
    /// currently realized — the max artwork height over `collection.folders`, the MODEL array
    /// (scroll-stable, unlike the `LazyHStack`'s realized children), plus the fixed vertical
    /// chrome every realized subview carries around its own artwork inside this stack:
    ///
    ///     minHeight = maxArtworkHeight                  // tallest folder's own artwork
    ///               + Theme.Spacing.sm                  // FolderTile's VStack spacing between
    ///                                                    //   its artwork ZStack and its caption
    ///               + folderCaptionHeight                // Theme.Font.cardTitle (.caption2)
    ///                                                    //   single-line caption — see that
    ///                                                    //   constant's own comment for the 23pt
    ///               + cardTopReach + cardBottomReach     // the reach padding: NOT inside
    ///                                                    //   FolderTile — CollectionRowView adds
    ///                                                    //   it OUTSIDE the tile, directly on the
    ///                                                    //   NavigationLink button label, so it
    ///                                                    //   is still part of what the LazyHStack
    ///                                                    //   would naturally realize as height
    ///
    /// The caption term is a constant worst case, not a per-folder measurement: every folder tile
    /// carries the same VStack spacing and, whenever it's showing plain text rather than an
    /// already-loaded title logo, the same single-line caption. Charging it even for a tile
    /// currently mid-logo-load only makes the floor very slightly taller than that one tile's own
    /// realized height — `minHeight` absorbs that as harmless extra room below the shelf, never a
    /// clip. Classic mode (`cardTopReach == 0`) gets the same floor for free: it can only ever
    /// GROW the shelf up to its tallest tile's natural size, never shrink one, so it is a no-op
    /// wherever classic already rendered correctly.
    private var shelfMinHeight: CGFloat {
        // PER-FOLDER floor (Codex 2026-08-29 P2 ×2): the max of each folder's artwork PLUS that
        // folder's OWN caption chrome — a caption on a shorter tile must not be billed to the
        // tallest artwork (no rendered child has that combined height, and the oversized frame
        // floats classic mode's centered children), and an all-hidden row gets no caption term
        // at all. The caption height comes from live type metrics, not a constant: the caption
        // is semantic `.caption2`, which grows under Larger Text — a fixed 23pt floor would sit
        // below the realized tile and the LazyHStack would still collapse on recycle, the exact
        // instability this frame exists to prevent.
        // Alignment note (Codex 2026-08-29 P2 round 3): the floor is applied `.top`-aligned in
        // BOTH modes. It can legitimately exceed every rendered child — a folder with
        // hideTitle=false whose title LOGO loads drops its text caption, a state unknowable at
        // layout time — and top alignment turns that overshoot into stable bottom padding
        // instead of a centered mid-frame float that jumps when the logo arrives.
        let captionChrome = Theme.Spacing.sm + Self.folderCaptionHeight
        let maxTileHeight = collection.folders
            .map { FolderTile.artworkHeight(for: $0, style: style) + ($0.hideTitle ? 0 : captionChrome) }
            .max() ?? style.height
        // BUG-87/89 (rc11): the scroll-stable floor must agree with the per-label floor
        // (`rowCardLinkFrameFloor`) or a recycle pass can still collapse the stack below the
        // height the last row's labels are actually holding.
        return max(maxTileHeight + cardTopReach + cardBottomReach, cardLinkFrameFloor)
    }

    /// `Theme.Font.cardTitle` (`.caption2`) single-line height under the CURRENT content size
    /// category — 23pt at default scale (Theme.swift's own record for this style), taller under
    /// Larger Text. `FolderTile`'s caption uses this style with `lineLimit(1)` and no extra
    /// vertical padding.
    private static var folderCaptionHeight: CGFloat {
        Theme.Font.uiFont(for: .caption2).lineHeight.rounded(.up)
    }

    /// BUG-89: `shelfMinHeight`'s arithmetic, reachable statically so `HomeView.rowsInsets` can
    /// size its bottom inset against the LAST Home row's height before any `CollectionRowView`
    /// instance for it has ever been laid out (the row it needs to measure may not even be
    /// visible yet — it is the one below the fold). `cardTopReach`/`cardBottomReach` are read from
    /// an environment on the live instance; here they are the fixed pinned-mode values `HomeView`
    /// always sets (`Theme.Size.heroPinnedRowTopPad` / `heroPinnedRowBottomReach`) — this helper
    /// has no other caller, so that is never an approximation.
    ///
    /// Adds this row's own vertical chrome around the shelf: in pinned mode the section-title
    /// `Text` above the shelf is NOT rendered (`:205`, overlaid instead), so the row's total
    /// height is exactly the shelf plus its own top/bottom padding — `Theme.Spacing.lg` (24) top
    /// (`:249`, pinned branch) and `Theme.Spacing.sm` (12) bottom (`:250`), with no extra `VStack`
    /// spacing term (a single child has none).
    static func pinnedRowHeight(collection: NuvioCollection, style: PosterStyle) -> CGFloat {
        let cardTopReach = Theme.Size.heroPinnedRowTopPad
        let cardBottomReach = Theme.Size.heroPinnedRowBottomReach
        let captionChrome = Theme.Spacing.sm + Self.folderCaptionHeight
        let maxTileHeight = collection.folders
            .map { FolderTile.artworkHeight(for: $0, style: style) + ($0.hideTitle ? 0 : captionChrome) }
            .max() ?? style.height
        let shelfMinHeight = maxTileHeight + cardTopReach + cardBottomReach
        return shelfMinHeight + Theme.Spacing.lg + Theme.Spacing.sm
    }

    /// Distance from this row's TOP edge to the FOCUSED folder tile's lockup BOTTOM — the bound the
    /// settle re-reveal's correction must respect (Codex r11 P2-2).
    ///
    /// Only this row needs to state it. `shelfMinHeight` floors the shelf at the TALLEST folder's
    /// lockup, and the `LazyHStack` is top-aligned in pinned mode, so a focused square or landscape
    /// tile (which takes its height from `style.width`, not `style.height` — see
    /// `FolderTile.artworkHeight`) ends far above the row's own bottom edge. Bounding the correction
    /// by the row bottom therefore reported little or no room on exactly the tiles the tester's
    /// "Streaming Services" complaint was about, refusing a correction the focused tile could have
    /// absorbed whole and handing the title to the visibility belt to hide instead.
    ///
    /// The arithmetic walks the same layout the row builds: row top → the shelf's pinned top
    /// padding (`Spacing.lg`, matched to `heroPinnedRowTitleInset`'s assumption) → the card reach
    /// band the `NavigationLink` label carries → the tile's own artwork and, only when the tile is
    /// actually RENDERING one, its caption chrome. Nil while nothing here holds focus, or in
    /// classic mode, where the row's own frame is already the right bound.
    ///
    /// The caption term goes through `FolderTile.rendersTextCaption` rather than `hideTitle` alone
    /// (Codex r11 round 2): a folder whose `titleLogoUrl` has LOADED draws the logo instead of the
    /// text, so charging the chrome anyway overstated the protected bottom by ~31pt and refused
    /// corrections that were perfectly safe — reintroducing, on exactly the wordmark tiles this
    /// bound exists for, the title-on-artwork the corrector is supposed to remove.
    ///
    /// Error direction, applied the same way as the shortest-vs-focused argument above:
    /// over-counting only refuses corrections (recoverable, and the belt still hides the title),
    /// while under-counting pushes real artwork past the fold (not recoverable). So every state
    /// that still shows the text — no logo URL, load failed, and the TRANSITIONAL still-loading
    /// state — keeps the chrome; only a confirmed cache hit drops it.
    ///
    /// Staleness note: `ArtworkStore.cached` is not observable, so a logo that finishes loading
    /// while its tile is already focused does not by itself re-render this row — the extent stays
    /// on the conservative (chrome-counted) side until the next body pass. The logo's arrival does
    /// change the tile's layout, so the row's own `onGeometryChange` re-fires and the MEASUREMENT
    /// refreshes; it is only this parameter that waits. In practice the next focus move recomputes
    /// it (`focusedFolderId` is a body dependency), and by the time a tile is focused its logo has
    /// almost always already loaded — it has been on screen. Conservative direction, bounded
    /// window, no correctness hazard.
    private var focusedTileLockupExtent: CGFloat? {
        guard cardTopReach > 0,
              let focusedFolderId,
              let folder = collection.folders.first(where: { $0.id == focusedFolderId })
        else { return nil }
        let caption = FolderTile.rendersTextCaption(for: folder)
            ? Theme.Spacing.sm + Self.folderCaptionHeight
            : 0
        return Theme.Spacing.lg + cardTopReach
            + FolderTile.artworkHeight(for: folder, style: style) + caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Pinned mode overlays the title inside the shelf's reach band instead (see
            // CatalogRowView's structural comment — out-of-bounds frames froze the focus
            // engine; all paddings must stay positive).
            if cardTopReach == 0 {
                Text(collection.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                // Pinned: TOP-aligned so mixed-shape folders (poster/landscape/square heights)
                // all start their reach frames at the same y — center alignment shifted the
                // shorter tiles' frames below the overlaid title, breaking the reveal-contains-
                // title invariant for them (Codex review). Classic keeps center, as ever.
                LazyHStack(alignment: cardTopReach > 0 ? .top : .center,
                           spacing: rowGap) {
                    ForEach(collection.folders, id: \.id) { folder in
                        NavigationLink(value: FolderRoute(collectionId: collection.id, folder: folder)) {
                            FolderTile(
                                folder: folder,
                                collectionBackdropUrl: collection.backdropImageUrl,
                                collectionId: collection.id,
                                // Focus truth from the row's own FocusState (Codex rounds 3-5:
                                // a second .focused binding collides with focusedFolderId's, and
                                // the ring must hug the tile artwork, so it's drawn inside).
                                stillFocused: focusedFolderId == folder.id
                            )
                                .padding(.top, cardTopReach)
                                .padding(.bottom, cardBottomReach)
                                // BUG-87/89 (rc11): transparent floor on the REVEALED frame — 0 for
                                // every row but Home's last. `.top` so the artwork and caption do
                                // not move a point.
                                .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                       alignment: .top)
                        }
                        // BUG-108: this label draws its own ring AND (since rc10) its own ring-mode
                        // lift, so ring mode must take the native `.borderless` lift away from it —
                        // `CardButtonLift.card`, the default. On the native lift the ring stayed at
                        // base geometry while the artwork rose (rc9 device photos).
                        .cardFocusButtonStyle()
                        .posterButtonShape()   // BUG-32/BUG-25: without this the system radius overrides Corners
                        .focused($focusedFolderId, equals: folder.id)
                        // BUG-109: a stable identity for native focus restoration after the folder page
                        // pops — parity with CatalogRowView's `.id(item.id)` on its cards.
                        .id(folder.id)
                        .zIndex(liftedTileZIndex(folder))
                    }
                }
                // Wave 4 item 2: floor the stack's height independent of scroll position — see
                // `shelfMinHeight`'s own comment for the collapse/regrow mechanism this fixes and
                // the arithmetic. Alignment matches the stack's own, so the extra room a shorter
                // realized frame needs to reach the floor distributes the same way the tiles
                // themselves are already aligned (top in pinned mode, center in classic).
                .frame(minHeight: shelfMinHeight, alignment: .top)
                // Always positive — the reach lives inside the buttons (see CatalogRowView).
                // Pinned TOP matches the catalog/CW shelves' 24pt: `heroPinnedRowTitleInset`
                // assumes a 24 + reach band, and the tighter 12pt here left the overlaid title
                // only ~36pt of clearance — overlapping folder art at larger text sizes
                // (Codex review, device-pass gating round). Classic keeps the original 12.
                .padding(.top, cardTopReach > 0 ? Theme.Spacing.lg : Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.sm)
            }
            // BUG-103 (u/mrStevenx3, 2026-09-10 photos + video): this row was the only Home row
            // still clipped to its own padded bounds, so its first and last visible tiles were cut
            // ~60 pt inside the screen edges while every catalog row (`CatalogRowView`,
            // BrowseComponents.swift) bleeds to the edge through the same modifier. Unlike the
            // catalog rows there is no `RowLeadingEdgeClip` here on purpose: BUG-92's leading-edge
            // clip exists for the inline trailer's rightward morph, and a folder tile has no
            // trailer — its only bleed past the padded edge is the native lift + ring, the exact
            // allowance that clip lets through anyway.
            .scrollClipDisabled()
            .overlay(alignment: .topLeading) {
                if cardTopReach > 0 {
                    Text(collection.title)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        // BUG-37: same clip-edge slide the catalog/CW shelves got — short
                        // real-swipe rests must never leave this row's title off-screen.
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                        // Codex r7 P2: `isFocused` picks which clearance the belt judges this row
                        // by — only a FOCUSED row's tiles are raised by the focus treatment.
                        //
                        // Codex r9 P2 / BUG-108: this row's cards now resolve through
                        // `CardFocusMode` like every other pinned row's — `FolderTile` carries
                        // `CardArtworkFocusLift`, so its zoom-on rise IS
                        // `heroPinnedRowFocusLiftAllowance` in both zoom modes rather than the
                        // native lift's ~20pt by coincidence. `.plainBorderless` described the
                        // pre-BUG-108 architecture and is gone; the published allowance is
                        // unchanged either way (`focusLiftAllowance` charges 20 unless No Zoom).
                        .pinnedRowTitleTracking(rowKey: collection.id,
                                                artworkHeight: shortestTileHeight,
                                                isFocused: focusedFolderId != nil,
                                                treatment: .cardTreatment)
                        .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                        .allowsHitTesting(false)
                }
            }
        }
        .focusSection()
        // Settle re-reveal (2026-08-30) — one line, same as every other pinned row; see
        // `pinnedRowSettleTracking` in BrowseComponents. This row is the mixed-shape one, so it is
        // also the one whose stale-relayout rests Wave 4 item 2 could only floor, not correct.
        // `focusedLockupExtent` (Codex r11 P2-2): this is the one mixed-shape pinned row, so its
        // own frame — floored at the TALLEST tile — overstates where the focused tile actually
        // ends. See `focusedTileLockupExtent`.
        .pinnedRowSettleTracking(rowKey: collection.id,
                                 isFocused: focusedFolderId != nil,
                                 focusedLockupExtent: focusedTileLockupExtent)
        // BUG-112 (Item A)
        .pinnedRowUpFallbackTarget(rowKey: collection.id,
                                   firstId: collection.folders.first?.id,
                                   focus: $focusedFolderId)
        .onChange(of: focusedFolderId) { _, id in
            // FEAT-33 (Wave 1, agent C; Codex r1): armed BEFORE the callback below. The callback
            // is synchronous, so with the default leg its `reportRowFocus` hero work — and any
            // main-thread stall it causes — would already be over before the display link took
            // its first sample; the 600 ms window is long enough to cover everything that follows.
            // `rowKey` is the collection title (readable off a tester's photo of the About pane)
            // rather than `collection.id` — the id is opaque and this probe's whole point is a
            // human reading the summary line, not code matching on it.
            if CollectionFocusFrameProbe.enabled, let id {
                let focusedFolder = collection.folders.first { $0.id == id }
                // Parenthesized so `.nonBlankTrimmed` (the `Optional<String>` extension below)
                // resolves against the flattened `String?` the chain produces, rather than the
                // compiler trying to continue unwrapping through it.
                let gif = focusedFolder?.focusGifEnabled == true && (focusedFolder?.focusGifUrl).nonBlankTrimmed != nil
                CollectionFocusFrameSampler.shared.arm(rowKey: collection.title, gif: gif)
            }
            onFolderFocusChange?(id.flatMap { fid in collection.folders.first { $0.id == fid } })
        }
    }
}

/// A single folder tile: cover art (or emoji / initial fallback) shaped per the folder's
/// `tileShape` (poster / landscape / square), following the user's Poster Style width.
/// BUG-38 (beta.13): release-safe cover-resolution probe — `defaults write com.nuvio.media.NuvioTV
/// debug.collectionCoverProbe -bool YES`, greppable `[CollectionCover]`. One line per folder tile
/// naming which artwork fields the synced payload actually carried, which one the tile drew, the
/// folder's source kinds, and — the part nothing else can answer — the raw JSON keys on that folder
/// that this build does NOT read (`CollectionRepository.unknownFolderKeysFromRawPayload`). A cover
/// another client wrote under a spelling we don't decode shows up there by name. Same house
/// pattern as `HomeGeometryProbe`/`TrailerProbe` (not `#if DEBUG`: the reporter runs release).
enum CollectionCoverProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.collectionCoverProbe")
    @MainActor private static var logged = Set<String>()

    @MainActor static func report(folder: CollectionFolder, collectionId: String, collectionBackdropUrl: String?, shown: String) {
        guard enabled else { return }
        func present(_ value: String?) -> Int { (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? 0 : 1 }
        let unknown = (CollectionRepository.shared.unknownFolderKeysFromRawPayload()["\(collectionId)|\(folder.id)"] as? [String]) ?? []
        let sourceKinds = folder.resolvedSources.map { source -> String in
            if source.isTmdb { return "tmdb:\(source.tmdbSourceType ?? "?")" }
            if source.isTrakt { return "trakt" }
            return "addon"
        }
        let line = String(
            format: "[CollectionCover] collection=%@ folder=%@ title=%@ own=%d heroBackdrop=%d collectionBackdrop=%d logo=%d emoji=%d gif=%d shape=%@ sources=[%@] unknownKeys=[%@] shown=%@",
            collectionId, folder.id, folder.title, present(folder.coverImageUrl), present(folder.heroBackdropUrl),
            present(collectionBackdropUrl), present(folder.titleLogoUrl), present(folder.coverEmoji),
            present(folder.focusGifUrl), folder.tileShape, sourceKinds.joined(separator: ","),
            unknown.joined(separator: ","), shown
        )
        // De-duplicated on the WHOLE line: the locally persisted payload renders first and the
        // cloud pull re-renders — a synced change to any field (or to the unknown keys) must log
        // again, only a byte-identical re-render is quiet.
        guard !logged.contains(line) else { return }
        logged.insert(line)
        NSLog("%@", line)
    }
}

struct FolderTile: View {
    let folder: CollectionFolder
    /// BUG-38 (2026-08-10 re-specification): the parent collection's user-configured
    /// `backdropImageUrl` — configurable in mobile's collection editor and synced for as long as
    /// the field has existed, but rendered by NO client until now. Folder-level artwork still
    /// wins (it's the more specific pick); this only replaces the positional first-item fallback
    /// that showed the reporter "the first movie from my home list" instead of their own artwork.
    var collectionBackdropUrl: String? = nil
    /// BUG-38 probe: folder ids are unique per COLLECTION, so the diagnostics key on both.
    var collectionId: String = ""

    /// Caller-supplied focus truth for the ring drawn on the artwork (Codex 2026-08-29 rounds
    /// 3-5): this tile has no focus treatment of its own, and the ring must hug the ARTWORK frame —
    /// only this view knows it — not the padded outer button bounds. Named for the no-zoom still
    /// ring it was added for; since BUG-102 (rc9) it gates the accent ring in zoom-on mode too.
    var stillFocused: Bool = false

    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// BUG-102: with zoom on and the accent ring on, every `PosterCard` in the neighbouring rows
    /// wore the ring and this tile drew nothing (it only knew the still ring). Same key as every
    /// other card, resolved through `PlainLabelRing` (PosterCard.swift).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// BUG-108: in ring mode this tile owns its lift, so the ring it draws on its own artwork rides
    /// that lift instead of standing still under the native one. `.still` (a no-op) in both other
    /// modes — see `PlainLabelRing.lift` for why it must never be `.systemLift` here.
    private var artworkLift: CardFocusMode {
        PlainLabelRing.lift(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    /// BUG-38 display-time fallback: genre folders are TMDB DISCOVER sources, which
    /// `TmdbCollectionSourceResolver.importMetadata` never mints a cover for (only
    /// COLLECTION/COMPANY/NETWORK/PERSON get one) — upstream mobile has the same gap. Resolved
    /// lazily by `FolderCoverResolver` (shared, in-memory-cached, never persisted) and rendered
    /// through the exact same `CachedAsyncImage` slot as a real cover. Stays nil for folders that
    /// already have a cover or a user-chosen emoji — see the `.task` guard below.
    @State private var fallbackCoverUrl: String?

    /// BUG-38: `CollectionFolder.titleLogoUrl` (shared model, `CollectionModels.kt:194`) was
    /// populated upstream but never read by any client. Loaded the same way `HeroLogo`
    /// (HomeView.swift) loads the Home hero's logo — through the shared `ArtworkStore` so it
    /// benefits from the same memory/disk cache as every other artwork on this tile — rather
    /// than a bare `AsyncImage`, which would re-fetch on every scroll recycle.
    @State private var titleLogoImage: UIImage?

    /// Resolved logo URL, or nil when the folder has none (blank/whitespace-only counts as
    /// absent, same trimming rule the cover/emoji checks below use).
    ///
    /// Also nil when the folder has its OWN cover (2026-08-08 device pass regression): service
    /// folders ship covers with the wordmark baked in — and upstream never renders titleLogoUrl
    /// anywhere — so overlaying the logo doubles the wordmark (filmed: prime video / Disney+ /
    /// HBO Max all twice on the Services row). The overlay exists to name a tile whose artwork
    /// doesn't name itself: genre DISCOVER folders (no cover — the tiles BUG-38 was filed about)
    /// and resolved first-item-art fallbacks keep it; explicit covers suppress it. Gated HERE,
    /// not at the render site, so the fetch task never loads the image and the plain-text title
    /// below (`titleLogoImage == nil`) stays visible on suppressed tiles.
    ///
    /// BUG-38 (beta.13): a refined gate keyed on TMDB company/network sources was tried and REVERTED
    /// on the 2026-08-18 device pass — the fork's curated Services folders (Netflix / Prime /
    /// Disney+ / HBO Max) are addon-sourced with a wordmark cover AND a titleLogoUrl, so the refined
    /// gate doubled every wordmark on the row (BUG-52 back, seen live). No provenance field exists to
    /// tell "cover already names the folder" from "user cover next to a logo", and the doubled
    /// wordmark is the worse failure, so any own cover keeps suppressing the logo. The
    /// `[CollectionCover]` probe (`debug.collectionCoverProbe`) is what answers the reporter's
    /// "title images don't show" — it names the payload keys this build reads and doesn't.
    private var titleLogoURL: URL? { Self.titleLogoURL(for: folder) }

    /// The gate above, as a static so `CollectionRowView` can ask the same question without
    /// re-deriving (and drifting from) its precedence rules — the same reason
    /// `artworkHeight(for:style:)` is a static.
    static func titleLogoURL(for folder: CollectionFolder) -> URL? {
        let ownCover = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(ownCover?.isEmpty ?? true) { return nil }
        guard let raw = folder.titleLogoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Whether this folder's tile is currently rendering its plain-text caption BELOW the artwork
    /// — i.e. whether the caption chrome is part of its lockup height right now.
    ///
    /// Mirrors the render condition exactly (`!folder.hideTitle && titleLogoImage == nil`, see the
    /// caption's own branch): a loaded title logo REPLACES the text. `titleLogoImage` is the tile's
    /// own `@State`, but it is populated from `ArtworkStore` — and the tile's `.task` takes a
    /// synchronous `ArtworkStore.cached` hit as "render immediately" — so a warm cache answers this
    /// without reaching into the child's state.
    ///
    /// The three nil cases stay on the caption side, which is the correct direction: no logo URL,
    /// still loading, and load failure all render the text, so all three keep the chrome.
    static func rendersTextCaption(for folder: CollectionFolder) -> Bool {
        guard !folder.hideTitle else { return false }
        guard let url = titleLogoURL(for: folder) else { return true }
        return ArtworkStore.cached(url) == nil
    }

    private var tileWidth: CGFloat {
        folder.posterShape == PosterShape.landscape ? style.width * 16 / 9 : style.width
    }

    /// See the BUG-102 note on the `.scaleEffect` below.
    private var reservesRingBand: Bool {
        PlainLabelRing.reservesBand(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    private var tileHeight: CGFloat { FolderTile.artworkHeight(for: folder, style: style) }

    /// A folder tile's ARTWORK height, without instantiating the tile — the pinned row needs it up
    /// front to size its title's slide clamp (Wave 4 item 6; see `PinnedRowTitle.maxSlide`).
    ///
    /// The square/landscape branches taking their height from `style.WIDTH` is correct, not a typo
    /// for `style.height`: a folder tile's shape is defined against the row's width dial, so
    /// landscape = `width × 16/9` wide by `width` tall (a true 16:9) and square = `width × width`
    /// (a true square). What follows is that non-poster tiles are simply SHORTER than a poster
    /// (`width` / `width × 1.5`), which is why a FIXED title intrusion eats a much larger share of
    /// them — the clamp is where that is fixed, not here: growing these tiles would change card
    /// layout heights, and the pinned focus-engine regime (link frames resting under the clip edge;
    /// this row's `LazyHStack` is top-aligned in pinned mode precisely so mixed shapes keep a
    /// common reach-frame top) is calibrated against the heights as they stand.
    static func artworkHeight(for folder: CollectionFolder, style: PosterStyle) -> CGFloat {
        switch folder.posterShape {
        case PosterShape.landscape: return style.width
        case PosterShape.square: return style.width
        default: return style.height
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack {
                // BUG-38: falls back to a resolved cover only when the folder has neither an
                // explicit cover nor a user-chosen emoji (the emoji is a deliberate pick — it
                // always wins). The emoji check lives HERE too, not just in the `.task` guard
                // (Codex review): a folder edited in place to gain an emoji keeps this view's
                // `@State` for one render before the re-keyed task clears it, and the stale
                // fallback must not cover the fresh emoji even for that frame.
                // Trimmed-blank checks (Codex review): the editor/import path can persist
                // whitespace-only values, which Kotlin-side code already treats as absent —
                // an untrimmed check here would classify them as explicit and leave the tile
                // blank (unusable URL, no fallback resolution).
                let ownCover = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let emoji = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines)
                // BUG-38 re-specification: the folder's own configured backdrop, then the parent
                // collection's — both are the user's deliberate artwork and must beat the
                // positional first-item fallback. The folder-level field outranks the emoji (a
                // more specific pick for THIS tile); the collection-level one is shared by every
                // folder in the row, so a folder-level emoji still wins over it.
                let folderBackdrop = folder.heroBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let collectionBackdrop = collectionBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasOwnCover = !(ownCover?.isEmpty ?? true)
                let hasFolderBackdrop = !(folderBackdrop?.isEmpty ?? true)
                let hasCollectionBackdrop = !(collectionBackdrop?.isEmpty ?? true)
                let hasEmoji = !(emoji?.isEmpty ?? true)
                let cover: String? = hasOwnCover ? ownCover
                    : hasFolderBackdrop ? folderBackdrop
                    : hasEmoji ? nil
                    : hasCollectionBackdrop ? collectionBackdrop
                    : fallbackCoverUrl
                let gifUrl: String? = folder.focusGifUrl
                let shownKind = hasOwnCover ? "own"
                    : hasFolderBackdrop ? "folderBackdrop"
                    : hasEmoji ? "emoji"
                    : hasCollectionBackdrop ? "collectionBackdrop"
                    : (fallbackCoverUrl == nil ? "none" : "fallback")
                let _ = CollectionCoverProbe.report(folder: folder, collectionId: collectionId, collectionBackdropUrl: collectionBackdropUrl, shown: shownKind)

                // BUG-19: the cover is mounted for the tile's WHOLE lifetime — it used to live in
                // the `else` branch of an `isFocused` test, so every D-pad step destroyed one
                // image pipeline and built another (a new @StateObject loader, a new
                // CachedAsyncImage, and — worse — a full AnimatedGifImage teardown that freed the
                // expanded GIF frame array on the main thread). That teardown/rebuild, not the
                // animation, is the 700–830 ms per-step main-thread hang the tester measured.
                if let cover, !cover.isEmpty {
                    CachedAsyncImage(string: cover)
                } else {
                    LinearGradient(
                        colors: [Theme.Palette.accent.opacity(0.55), Theme.Palette.background],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(hasEmoji ? emoji! : String(folder.title.prefix(1)))
                        .font(Theme.Font.hero)
                }

                // BUG-38: an overlay ON TOP of whatever cover just rendered above (own cover,
                // resolved fallback, or the gradient+emoji/initial placeholder) — never a new
                // cover source, so the precedence chain above is untouched. Lower-leading,
                // matching the tile's own title text alignment below (`VStack(alignment:
                // .leading)`). Sits BELOW the focus GIF in z-order (added first here, so the
                // GIF layer below draws over it) — mirrors mobile's own logo-under-motion
                // layering and the tile's existing "GIF over cover" order.
                if let logoImage = titleLogoImage {
                    Image(uiImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: tileWidth * 0.82, maxHeight: tileHeight * 0.36)
                        .frame(width: tileWidth, height: tileHeight, alignment: .bottomLeading)
                        .padding(Theme.Spacing.xs)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        // When the logo replaces the plain-text name below the tile, this image
                        // becomes the control's only name-bearing content — without an explicit
                        // label VoiceOver reads an unlabeled image (Codex round 3).
                        .accessibilityLabel(folder.title)
                }

                if folder.focusGifEnabled, let gifUrl, !gifUrl.isEmpty {
                    // Also mounted persistently, layered OVER the cover. Focus no longer changes
                    // view identity: it flips `isAnimating`, which starts/stops the UIImageView and
                    // cross-fades the GIF's opacity (AnimatedGifImage owns that fade — only it
                    // knows whether the frames have decoded yet, and it keeps the cover showing
                    // until they have). `fallback: nil` because the cover above already covers the
                    // loading/failure case; passing it here would decode the same artwork twice.
                    // The GIF's download+decode is deferred to this tile's FIRST focus, so a
                    // 15-tile Services row doesn't decode 15 GIFs the moment the row appears.
                    // BUG-39: `targetSize` is this tile's own rendered point size — already known
                    // synchronously here from `posterStyle`/`folder.posterShape`, no need to wait
                    // on a UIKit layout pass — so the decoder can downsample to roughly what's
                    // actually displayed instead of a fixed worst-case guess.
                    AnimatedGifImage(
                        string: gifUrl,
                        fallback: nil,
                        isAnimating: isFocused,
                        targetSize: CGSize(width: tileWidth, height: tileHeight)
                    )
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            // BUG-105 (u/mrStevenx3, 2026-09-10: "depth effect does not apply to images in
            // collections"): this tile never carried the card-depth rail every PosterCard /
            // LandscapeCard / SagaCard wears. Attached BEFORE the ring-band `.scaleEffect` below so
            // the rail scales with the artwork and traces the picture, not the outer tile box —
            // the same "rail hugs the INSET artwork" rule BUG-91 set for PosterCard. `.posters` is
            // the surface a collection tile reads as (the Settings toggle that governs poster rows).
            .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
            // 2026-08-30 no-zoom investigation: same overpaint as TileFocusLift's ring, same fix —
            // the ring used to strokeBorder straight over this tile's own cover/logo/GIF stack.
            // That stack's internal layout (the logo overlay in particular) is pinned to this
            // view's own `tileWidth`/`tileHeight` instance properties, so it can't be redrawn at a
            // smaller size the way PosterCard redraws its own artwork frame — shrunk in place with
            // the same static, never-focus-linked `.scaleEffect` TileFocusLift uses instead, which
            // leaves the `.overlay` below measuring the TRUE, unscaled tile bounds.
            // BUG-102 (rc9): the band is reserved whenever a ring may ever draw (`ringInset`'s
            // rule — accent ring on OR no-zoom on), not only in still mode, so the accent ring
            // lands in the vacated margin instead of over the artwork's edge.
            .scaleEffect(
                x: reservesRingBand && tileWidth > 0 ? max(0, tileWidth - 2 * ringWidth) / tileWidth : 1,
                y: reservesRingBand && tileHeight > 0 ? max(0, tileHeight - 2 * ringWidth) / tileHeight : 1
            )
            .overlay {
                // Still ring (no-zoom) or accent ring (setting on, zoom on or off) on the artwork
                // itself — `PlainLabelRing` holds the precedence, shared with CastCard.
                if let ring = PlainLabelRing.resolve(accentFocusRing: accentFocusRing,
                                                     noZoomOnFocus: noZoomOnFocus,
                                                     focused: stillFocused) {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(ring.color, lineWidth: ringWidth)
                }
            }
            // BUG-108 probe (test56): the tile box the ring is drawn on, inside the lift —
            // `.scaleEffect` is render-only, so in ring/no-zoom modes the drawn picture is
            // `ringWidth` smaller on each edge than this rect; test56's assertions are relative
            // (rise/growth), so this is the right box for them. Armed only by
            // `-debug.cardGeometryProbe YES`, DEBUG only.
            .modifier(DebugAXIdentifier("folder_artwork"))
            // BUG-108 (u/mrStevenx3, rc9 device photos: with the ring on, the collection tile's
            // picture lifts out of its ring): this tile's lift hangs HERE — outside the ring overlay
            // above, outside the ring band's `.scaleEffect`, outside `.nuvioCardDepth`'s rail, and
            // outside the `.clipShape` — so all four are one SwiftUI layer that scales together.
            // Attached after the overlay on purpose: the overlay must keep measuring the TRUE,
            // unscaled tile bounds (the band-scale comment above), and the lift must be the
            // outermost of the pair so it carries both.
            //
            // `stillFocused`, not `@Environment(\.isFocused)`: the ring is drawn off the ROW's own
            // FocusState (Codex 2026-08-29 rounds 3-5 — a second `.focused` binding collides with
            // `focusedFolderId`), and a lift keyed on a different truth could scale the artwork in a
            // frame where the ring is not drawn, which is the very split this bug is about.
            //
            // `artworkHeight: tileHeight` is what keeps the rise at exactly
            // `heroPinnedRowFocusLiftAllowance` (20pt) for all three tile shapes, so the pinned
            // row's clip budget (`PinnedRowTitle.focusLiftAllowance`, already 20 for this row) is
            // unchanged by this commit.
            .modifier(CardArtworkFocusLift(
                mode: artworkLift,
                isFocused: stillFocused,
                artworkHeight: tileHeight,
                cornerRadius: style.cornerRadius
            ))
            // BUG-108 probe (test56): the tile's LAYOUT box, outside the lift. `.scaleEffect` is
            // render-only, so this rect must NOT move when the tile lifts — that is the negative
            // control that proves the rise costs the row no reflow.
            .modifier(DebugAXIdentifier("folder_card"))
            // BUG-38: keyed on the folder's Kotlin data-class hash (NOT `isFocused` — see the
            // BUG-19 comment above on why this tile must never key off focus), so a cloud-sync
            // edit that keeps the folder's id but changes its sources/cover/emoji re-runs the
            // task and re-consults the resolver under the new source signature (Codex review —
            // an unkeyed `.task` on a `ForEach(id: \.id)` row never re-fires for such edits).
            // `FolderCoverResolver` caches per folder-id+source-signature, so recycled
            // LazyHStack tiles and unchanged re-renders resolve instantly from that cache.
            // BUG-38 re-specification (Codex gate 0): the collection backdrop participates in the
            // cover precedence above, so it must participate in this task's identity too — a cloud
            // sync that clears ONLY the collection backdrop leaves the folder's own hash unchanged,
            // and without it here the fallback resolution this guard skipped on the first run would
            // never happen, parking the tile on the gradient placeholder.
            .task(id: "\(folder.hash())|\(collectionBackdropUrl ?? "")") {
                // Recompute from scratch each (re)run: a folder that GAINED a real cover or an
                // emoji must drop a previously resolved fallback rather than keep rendering it.
                fallbackCoverUrl = nil
                // Trimmed like the render path above — whitespace-only values are "absent".
                guard folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                guard folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                // BUG-38 re-specification: a configured backdrop (folder- or collection-level)
                // renders instead of the resolved fallback, so don't spend the resolution.
                guard folder.heroBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                guard collectionBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    FolderCoverResolver.shared.fallbackCoverUrl(folder: folder) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                // Codex review: `.task(id:)` cancellation doesn't abort the Kotlin call —
                // a superseded task can resume here AFTER its replacement finished and would
                // otherwise install a cover from the old source set over the new one.
                guard !Task.isCancelled else { return }
                guard let resolved, !resolved.isEmpty else { return }
                fallbackCoverUrl = resolved
            }
            // BUG-38: independent of the cover-fallback task above (different cache, different
            // key) — mirrors `HeroLogo`'s own load: a synchronous `ArtworkStore.cached` check
            // first (so a warm logo never flashes in), then the async fetch.
            .task(id: titleLogoURL) {
                guard let titleLogoURL else {
                    titleLogoImage = nil
                    return
                }
                if let cached = ArtworkStore.cached(titleLogoURL) {
                    titleLogoImage = cached
                    return
                }
                titleLogoImage = nil
                if let fetched = try? await ArtworkStore.fetch(titleLogoURL) {
                    // `ArtworkStore.fetch` deliberately completes shared work even after this
                    // task is cancelled, so a superseded request can resume here after its
                    // replacement — never install a stale folder's logo (Codex round 1).
                    guard !Task.isCancelled, self.titleLogoURL == titleLogoURL else { return }
                    withAnimation(.easeIn(duration: 0.25)) { titleLogoImage = fetched }
                }
            }

            // BUG-38: the logo overlay replaces this plain-text name once it loads — the text
            // stays as the fallback (no logo URL, load failure, or still loading).
            if !folder.hideTitle && titleLogoImage == nil {
                Text(folder.title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: tileWidth, alignment: .leading)
                    // BUG-108: in ring mode the artwork grows DOWNWARD by the same 20pt it rises,
                    // so the caption follows its bottom edge exactly as every other card's does.
                    // 0 in both other modes: the native lift moves the whole label itself, and
                    // still mode moves nothing. Render-only `.offset`, so the lockup's measured
                    // height is unchanged and `shortestTileHeight`/`shelfMinHeight` do not move.
                    .modifier(CardCaptionFocusDrop(
                        mode: artworkLift, isFocused: stillFocused, artworkHeight: tileHeight
                    ))
            }
        }
        // FEAT-33 (Wave 1, agent C): leg 2/3 of `debug.collectionFocusAB` drops this animation
        // entirely to test whether it's the source of the reported 30fps-looking focus step.
        // Identical to shipping behavior with the knob off (the default).
        // BUG-108: `reduceMotion` added because this animation now wraps `CardArtworkFocusLift`'s
        // manual scale. That modifier honours Reduce Motion by passing a nil animation; a blanket
        // `.animation` out here would animate the scale anyway and undo it.
        .animation(CollectionFocusAB.dropTileAnimation || reduceMotion
                   ? nil : .easeOut(duration: 0.15),
                   value: isFocused)
    }
}

/// Backs `FolderDetailView`. The shared `FolderDetailRepository` is a singleton keyed by
/// `initialize(collectionId:folderId:)` — one folder screen at a time, `clear()` on exit.
@MainActor
final class FolderDetailViewModel: ObservableObject {
    /// The selected tab's tmdb source when its Discover filters can be edited on-device
    /// (`TmdbFilterEditorView`). Identifiable so it can drive `.fullScreenCover(item:)`.
    struct EditableSource: Identifiable {
        let collectionId: String
        let folderId: String
        /// Index into `folder.resolvedSources` (what `TmdbSourceFilterEditor.begin` takes).
        let sourceIndex: Int
        let title: String
        var id: String { "\(collectionId)|\(folderId)|\(sourceIndex)" }
    }

    @Published private(set) var folderTitle: String
    /// BUG-38 (folder page): `CollectionFolder.titleLogoUrl` as the page title — the key the
    /// Home tile deliberately does NOT draw over a folder's own cover (BUG-52: the logo over a
    /// self-naming cover doubled every wordmark). Blank/whitespace counts as absent, the same
    /// trimming rule the tile applies to every payload URL. The folder's `heroBackdropUrl` is
    /// the HOME hero's business (round three), not this page's.
    @Published private(set) var titleLogoUrl: String?
    @Published private(set) var tabs: [FolderTab] = []
    @Published private(set) var selectedTabIndex = 0
    @Published private(set) var items: [MetaPreview] = []
    @Published private(set) var isLoading = true
    @Published private(set) var canLoadMore = false
    @Published private(set) var tabIsLoading = false
    /// Non-nil when the selected tab is a filter-consuming tmdb source (DISCOVER / COMPANY /
    /// NETWORK — LIST/COLLECTION/PERSON/DIRECTOR ignore Discover filters at resolve time).
    @Published private(set) var editableSource: EditableSource?

    private let collectionId: String
    private let folderId: String
    private var watcher: FlowWatcher?

    init(route: FolderRoute) {
        collectionId = route.collectionId
        folderId = route.folderId
        folderTitle = route.folderTitle
        titleLogoUrl = route.titleLogoUrl
    }

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(FolderDetailRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? FolderDetailUiState else { return }
            if let folder = state.folder {
                self.folderTitle = folder.title
                self.titleLogoUrl = folder.titleLogoUrl.nonBlankTrimmed
            }
            self.tabs = state.tabs
            self.selectedTabIndex = Int(state.selectedTabIndex)
            self.items = state.selectedTab?.items ?? []
            self.isLoading = state.isLoading
            self.canLoadMore = state.selectedTabCanLoadMore
            self.tabIsLoading = state.selectedTab?.isLoading ?? false
            self.editableSource = Self.editableSource(
                in: state,
                collectionId: self.collectionId,
                folderId: self.folderId
            )
        }
        FolderDetailRepository.shared.initialize(collectionId: collectionId, folderId: folderId)
    }

    /// Re-runs `initialize` for the same folder after the filter editor saved: the repository's
    /// retained-inputs guard (UX-14) sees the changed `folder` and does a full refetch; when
    /// nothing changed (Cancel) it early-returns and keeps the grid as-is.
    func reload() {
        let previousTab = selectedTabIndex
        FolderDetailRepository.shared.initialize(collectionId: collectionId, folderId: folderId)
        // A full re-init rebuilds the tabs with index 0 selected; put the user back on the tab
        // whose filters they just edited (tabs are built synchronously inside initialize).
        let tabCount = (FolderDetailRepository.shared.uiState.value_ as? FolderDetailUiState)?.tabs.count ?? 0
        if previousTab > 0, previousTab < tabCount {
            FolderDetailRepository.shared.selectTab(index: Int32(previousTab))
        }
    }

    /// Maps the selected tab back to its `resolvedSources` index. FolderDetailRepository builds
    /// one tab per source, with an "All" tab first when `showAllTab` (`tabIndex = showAll ?
    /// sourceIndex + 1 : sourceIndex`, FolderDetailRepository.kt:278). Addon sources whose
    /// catalog can't be materialised are skipped while building tabs, which would shift the
    /// indices — so the offset result is verified against the folder's sources and corrected by
    /// identity when it doesn't line up.
    private static func editableSource(
        in state: FolderDetailUiState,
        collectionId: String,
        folderId: String
    ) -> EditableSource? {
        let tabs = state.tabs
        let tabIndex = Int(state.selectedTabIndex)
        guard tabs.indices.contains(tabIndex) else { return nil }
        let tab = tabs[tabIndex]
        guard !tab.isAllTab, let source = tab.source, source.isTmdb else { return nil }
        // Same fallback as the shared `CollectionSource.tmdbType()`: unknown/missing → DISCOVER.
        let rawType: String? = source.tmdbSourceType
        let type = (rawType ?? "DISCOVER").uppercased()
        if ["LIST", "COLLECTION", "PERSON", "DIRECTOR"].contains(type) { return nil }

        var sourceIndex = tabIndex - (state.showAllTab ? 1 : 0)
        if let resolved = state.folder?.resolvedSources {
            let aligned = resolved.indices.contains(sourceIndex) && resolved[sourceIndex] == source
            if !aligned, let match = resolved.firstIndex(where: { $0 == source }) {
                sourceIndex = match
            }
        }
        guard sourceIndex >= 0 else { return nil }
        return EditableSource(
            collectionId: collectionId,
            folderId: folderId,
            sourceIndex: sourceIndex,
            title: tab.label
        )
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        // UX-14: `onDisappear` also fires when a pushed title screen merely COVERS this grid —
        // `clear()` here meant popping back rebuilt the grid at the top. `detach()` cancels
        // in-flight loads but keeps the repository's state, so `initialize()`'s same-key
        // early-return preserves the items (and the lazy grid's scroll position) on pop-back.
        // Same UX-13 contract as CatalogGridViewModel.stop() → CatalogRepository.detach().
        FolderDetailRepository.shared.detach()
    }

    func selectTab(_ index: Int) {
        FolderDetailRepository.shared.selectTab(index: Int32(index))
    }

    /// Infinite scroll: page the selected tab when focus nears the end of the grid.
    func itemAppeared(at index: Int) {
        guard canLoadMore, index >= items.count - 8 else { return }
        FolderDetailRepository.shared.loadMoreSelectedTab()
    }
}

/// A collection folder's contents: tab chips (one per source + "All") over an adaptive paginated
/// poster grid. All view modes render as the tabbed grid on tvOS (v1 simplification). Pushed within
/// the Home stack, so `TitleRoute` resolves against the ancestor's destination.
struct FolderDetailView: View {
    @StateObject private var model: FolderDetailViewModel

    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.dismiss) private var dismiss
    /// Drives the TMDB filter editor cover for the selected tab's tmdb source.
    @State private var editing: FolderDetailViewModel.EditableSource?

    init(route: FolderRoute) {
        _model = StateObject(wrappedValue: FolderDetailViewModel(route: route))
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Same grid rules as `CatalogGridView`: fixed-width columns at the HIG's 40pt gap, and the
    /// HIG's 5-column 320×480 poster at accessibility text sizes (spec §3.1 / §10).
    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var cardWidth: CGFloat {
        accessibilityLayout
            ? Theme.Grid.itemWidth(columns: Theme.Grid.posterColumnsAccessibility)
            : posterStyle.width
    }
    private var cardHeight: CGFloat {
        accessibilityLayout ? cardWidth * 1.5 : posterStyle.height
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: Theme.Grid.spacing)]
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            // BUG-38 round three: the folder's backdrop is NOT painted behind this page any
            // more (it shipped that way in beta.14; the reporter found it made the page text
            // unreadable depending on the image). The logo-as-title stays; the backdrop moved
            // to the Home hero, which follows the focused folder tile.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        // H-2: the parent collection's title ("Genres", "Services de
                        // Streaming") used to render as a caption above this logo — a
                        // tvOS-only invention (mobile's `hideTitle` is tile-scoped, not this)
                        // that a tester flagged 2026-08-22. Removed unconditionally; the
                        // folder page header is logo-only now, so the wrapping VStack that
                        // once held both is gone too.
                        FolderHeroTitle(title: model.folderTitle, logoUrl: model.titleLogoUrl)
                        Spacer()
                        // On-device TMDB Discover filter editing for the selected tmdb tab
                        // (upstream 0fc4616b's exclusion filters + the existing include fields).
                        // Only shown for filter-consuming sources; doubles as the empty state's
                        // focus anchor (BUG-47) when the source currently matches nothing.
                        if let source = model.editableSource {
                            Button {
                                editing = source
                            } label: {
                                Label("Edit Filters", systemImage: "line.3.horizontal.decrease.circle")
                                    .font(Theme.Font.meta)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("folder.editFilters")
                        }
                    }

                    if model.tabs.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.md) {
                                ForEach(Array(model.tabs.enumerated()), id: \.offset) { index, tab in
                                    TabChip(
                                        label: tab.label,
                                        isSelected: index == model.selectedTabIndex
                                    ) {
                                        model.selectTab(index)
                                    }
                                }
                            }
                            .padding(.vertical, Theme.Spacing.sm)
                        }
                    }

                    if model.items.isEmpty {
                        if model.isLoading || model.tabIsLoading {
                            HStack(spacing: Theme.Spacing.md) {
                                ProgressView()
                                Text("Loading\u{2026}").foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .padding(.top, Theme.Spacing.xl)
                        } else {
                            // VIS-14: the system empty state.
                            ContentUnavailableView {
                                Label(String(localized: "catalog.empty.title",
                                             defaultValue: "No Titles",
                                             comment: "Catalog grid and collection folder: title shown when there is nothing to show"),
                                      systemImage: "film.stack")
                            } description: {
                                Text("Nothing here yet.")
                            } actions: {
                                // BUG-47 class: a pushed screen with no focusable content strands
                                // focus on the ancestor tab bar, where Menu exits the app instead
                                // of popping. The Edit Filters button anchors focus when present;
                                // otherwise keep a Go Back control here (same as CatalogGridView).
                                if model.editableSource == nil {
                                    Button("Go Back") { dismiss() }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .padding(.top, Theme.Spacing.xl)
                        }
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Grid.rowSpacing) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                NavigationLink(value: TitleRoute(preview: item)) {
                                    PosterCard(
                                        title: item.name,
                                        imageURL: item.poster,
                                        width: accessibilityLayout ? cardWidth : nil,
                                        height: accessibilityLayout ? cardHeight : nil
                                    )
                                }
                                .cardFocusButtonStyle()
                                .posterButtonShape()
                                // F13: shared long-press menu (library, watched).
                                .posterContextMenu(item)
                                .onAppear { model.itemAppeared(at: index) }
                            }
                        }

                        if model.canLoadMore || model.tabIsLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, Theme.Spacing.lg)
                        }
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // House pattern for full-screen flows (`ProfileEditTarget`, DetailView's players). On
        // dismiss — Save, Cancel, or Menu — re-run initialize: the repository's retained-inputs
        // guard refetches only when the folder actually changed.
        .fullScreenCover(item: $editing, onDismiss: { model.reload() }) { source in
            TmdbFilterEditorView(target: source)
        }
    }
}

/// A focusable pill used for the folder's source tabs.
///
/// BUG-49: the old hand-rolled label owned its color AND drew its own capsule fill, both blind
/// to focus — a focused-but-unselected chip painted near-white text on the chip style's
/// near-white platter, and any label-side fix would still leave the label's own dark capsule
/// covering that platter. `ChipButtonStyle(selected:)` already resolves fill and label for all
/// four focus×selection states (a brighter neutral platter and semibold label at rest when selected (VIS-03), white platter + dark label on
/// focus), so the chip must not override either.
/// BUG-38 (folder page hero): the folder's `titleLogoUrl` as the page title when it loads —
/// the same ArtworkStore path `HeroLogo` (HomeView) uses for the Home hero's logo — and the
/// plain `screenTitle` text until then / when there is none. The logo is capped to the pinned
/// Home hero's logo slot so a 1:1 genre badge and a wide wordmark both sit on one baseline.
private struct FolderHeroTitle: View {
    let title: String
    private let url: URL?
    @State private var image: UIImage?

    init(title: String, logoUrl: String?) {
        self.title = title
        self.url = logoUrl.flatMap(URL.init(string:))
        // Codex round 1: seed synchronously from the cache, exactly as `HeroLogo` does — a
        // reopened folder whose logo is already in ArtworkStore must not flash its text title
        // for one frame before the `.task` consults the same cache.
        _image = State(initialValue: ArtworkStore.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: Theme.Size.heroLogoMaxWidth, maxHeight: Theme.Size.heroLogoSlotHeightPinned, alignment: .leading)
                    .accessibilityLabel(title)
            } else {
                Text(title)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        // Codex round 1: when a logo is configured, text-while-loading and the loaded logo share
        // ONE fixed-height slot, so the swap cannot resize the header and shove the tabs/grid
        // while focus is live. No logo configured → no slot: the page keeps its old text metrics.
        .frame(height: url == nil ? nil : Theme.Size.heroLogoSlotHeightPinned, alignment: .leading)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ArtworkStore.cached(url) {
                image = hit
                return
            }
            image = nil
            let fetched = try? await ArtworkStore.fetch(url)
            // Codex round 1: `.task(id:)` cancels this task when the URL changes, but
            // `ArtworkStore.fetch` lets shared work run to completion — so a superseded fetch can
            // land after its replacement. Never install a result for a URL that is no longer ours.
            guard !Task.isCancelled, let fetched else { return }
            withAnimation(.easeIn(duration: 0.25)) { image = fetched }
        }
    }
}

private extension Optional where Wrapped == String {
    /// Blank/whitespace-only payload URLs count as absent — the rule every other cover/logo
    /// check in this file applies (the editor/import path can persist whitespace-only values).
    var nonBlankTrimmed: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private struct TabChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
        }
        .buttonStyle(.chip(selected: isSelected))
    }
}
