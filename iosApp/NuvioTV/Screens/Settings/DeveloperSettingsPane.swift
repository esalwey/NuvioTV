import SwiftUI
import SharedCore

/// VIS-01: the hidden Developer pane. Every probe, readout and A/B lever that used to sit under
/// Settings › About lives here now, so a public build's About pane shows only Version, Build, tvOS,
/// Device and Source code.
///
/// Unlocked by pressing Version seven times in About (`AboutSettingsPane`), persisted in
/// UserDefaults (`DeveloperMode.unlockedKey`), so it survives relaunches and works on the Release
/// IPAs testers run (an `#if DEBUG` gate would have hidden it from them). Once unlocked, Settings
/// gains a "Developer" category after About (`SettingsCategory.developer`); "Hide Developer
/// Settings" at the bottom of this pane switches every probe off and hides the category again.
///
/// The rows, keys and readouts below moved here verbatim from `AboutSettingsPane` (their own
/// comments still describe the original rationale); only the plain About rows stayed behind, and
/// the Commit row moved here with the probes.
struct DeveloperSettingsPane: View {
    /// BUG-42 (beta.13.5): the reporter can't `defaults write` on a sideload, so the release-safe
    /// hero probe gets a visible switch. Read once at launch by `HomeHeroProbe.enabled`, hence the
    /// relaunch note in the subtitle.
    @AppStorage("debug.homeHeroProbe") private var heroDiagnostics = false
    @State private var heroProbeLines: [String] = []

    /// BUG-89/BUG-66 (beta.18-rc2): the exact same shape as the hero probe above, for the pinned
    /// ROW SETTLE machinery — `PinnedRowSettleProbe`, whose buffer records the regime, one line per
    /// resolved settle decision, and the visibility belt's state changes. Launch-latched for the
    /// same reason (`PinnedRowSettleProbe.enabled` is a `static let`), hence the relaunch note in
    /// the subtitle, and its own key so the two captures never crowd each other out of one buffer.
    @AppStorage("debug.pinnedRowSettleProbe") private var rowSettleDiagnostics = false
    @State private var rowSettleProbeLines: [String] = []

    /// BUG-66 evidence probe (2026-09-10): `TabBarStateProbe` records the SYSTEM tab bar's own
    /// on-device GEOMETRY (frame/alpha/hidden/minimized), which no existing instrument has ever
    /// captured — the "Tab Bar Diagnostics" toggle further down this pane (`TabBarProbe`, bound to
    /// `debug.tabBarProbe`) only ever read a scroll-view offset/inset. Distinct title and key so
    /// the two never collide (see `TabBarStateProbe`'s own doc comment for the naming judgment
    /// call). Same launch-latched/persisted-buffer/paged-readout shape as `PinnedRowSettleProbe`
    /// above, reusing that type's `displayOrder`/`displayPages` directly — both are pure functions
    /// over a plain `[String]`, unrelated to that enum's own buffer, so there was nothing to
    /// extract or duplicate.
    @AppStorage("debug.tabBarStateProbe") private var tabBarStateDiagnostics = false
    @State private var tabBarStateProbeLines: [String] = []

    /// BUG-87 rc12 follow-up: the No Zoom reach-hold A/B (`PinnedRowTitle.FocusModeFlags
    /// .reachHoldsLift`, `PinnedRowGeometry.plan`'s `floorLift`). Default OFF — this row exists so
    /// Christian can flip it live on his own Apple TV and A/B the Row Settle Diagnostics pane
    /// above, not for testers: it costs the Large hero-off panel a synopsis line when on, which is
    /// exactly why it ships defaulted off rather than as the No Zoom behavior outright. Live, no
    /// relaunch — `HomeView`'s `@AppStorage` and `PinnedRowTitleTracking`'s both react immediately,
    /// same as the two Appearance focus flags they sit beside.
    @AppStorage(PinnedRowTitle.noZoomReachHoldsLiftKey) private var noZoomReachHoldsLift = false

    /// BUG-30/66/62 (beta.14): same release-safe pattern as the hero probe above, but the readout
    /// is a live in-memory snapshot (`TabBarProbe`) rather than a persisted log — see that type's
    /// doc comment for why.
    @AppStorage("debug.tabBarProbe") private var tabBarDiagnostics = false
    @Environment(\.tabBarVisibility) private var tabBarVisibility

    /// T5 (BUG-30/42): the reporter is on a sideload and can't `defaults write`, so the one
    /// lawful A/B lever over the clipped tab-bar reappearance —
    /// `HomeScrollEdgeStyleModifier` (HomeView.swift ~L1307-1325; its own comment records it is
    /// NOT one of the six banned scroll-changing rounds) — needs a Settings switch too.
    /// `@AppStorage` on both ends (this toggle and `HomeView.homeScrollEdgeHard`), unlike the
    /// hero probe above: the change is LIVE, not launch-latched, so a tester can A/B it without
    /// relaunching between tries. Default stays off — shipped behavior is byte-identical until
    /// toggled.
    @AppStorage("debug.homeScrollEdgeHard") private var scrollEdgeHard = false

    /// BUG-64: both raw toggles `CardFocusMode.resolve` reads, so this pane can show the resolved
    /// mode next to the settings a tester's photo needs to be checked against.
    /// BUG-74: the reporter saw "no streams" on titles that played fine on mobile, and the one
    /// fact that would have settled it in a day — the id we sent the addons was `tmdb:…`, not
    /// `tt…` — was only ever written to a console no sideloaded tester has. Same release-safe
    /// toggle pattern as the two probes above; live in-session (no relaunch), since the capture
    /// protocol is "turn on, open the failing title, press Play, come back here, photograph".
    @AppStorage("debug.streamProbe") private var streamDiagnostics = false

    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    /// BUG-81 (Wave F item C): same release-safe toggle pattern as the three probes above — a
    /// tester on a release sideload can't `defaults write com.nuvio.media.NuvioTV debug.trailerProbe
    /// -bool YES`, so `TrailerZoomProbe`'s buffer gets its own switch, live in-session (no relaunch:
    /// the capture protocol is "turn on, open the zoomed title, let it play ~10s, come back here and
    /// photograph").
    @AppStorage("debug.trailerDiagnostics") private var trailerDiagnostics = false
    /// Bumped by the "Reset trailer zoom cache" button so `trailerZoomCacheCount` below — a plain
    /// read of a non-`@Published` singleton — has a `@State` dependency to invalidate on, the same
    /// way `heroProbeLines`/`StreamProbe.lines` get their re-renders from a toggle or a `TimelineView`
    /// tick rather than from Combine.
    @State private var trailerZoomCacheGeneration = 0

    /// BUG-41 (Wave F item D, DetailView.swift): `debug.detailScrollAB`/`debug.detailScrollProbe`
    /// are both LIVE reads on the DetailView side (`DetailScrollAB.leg`, `DetailScrollProbe.enabled`)
    /// — F-C only owns the About-pane control surface here, not the probe or the A/B legs themselves.
    @AppStorage("debug.detailScrollAB") private var detailScrollAB = 0
    @AppStorage("debug.detailScrollProbe") private var detailScrollProbeEnabled = false

    /// FEAT-33 (Wave 1, agent C): same release-safe toggle pattern as the probes above —
    /// `CollectionFocusFrameProbe`'s buffer and `CollectionFocusAB`'s knob (`CollectionsUI.swift`,
    /// `CollectionFocusFrameProbe.swift`) are both keyed off these two, live in-session except the
    /// A/B leg, which is read once at launch (`CollectionFocusAB.leg`) — flipping the picker here
    /// only takes effect on the next launch, hence the subtitle below.
    @AppStorage("debug.collectionFrameProbe") private var collectionFrameProbe = false
    @AppStorage("debug.collectionFocusAB") private var collectionFocusAB = 0
    /// Wave 2 fallbacks for the two system components that replaced app-drawn ones and still need
    /// a device check: the system search field (decision D2, read by `SearchView` at launch) and
    /// the system digit-entry PIN screen (spec gap 16, read live by `PinEntryView`). The same keys
    /// can be set with a launch argument (`-debug.searchLegacyField YES`, `-debug.pinLegacyPad YES`).
    @AppStorage("debug.searchLegacyField") private var searchLegacyField = false
    @AppStorage(PinEntryView.legacyPadKey) private var pinLegacyPad = false

    private var trailerZoomCacheCount: Int {
        _ = trailerZoomCacheGeneration // dependency only — see the property's doc comment
        return TrailerZoomCache.shared.count
    }

    var body: some View {
        Group {
            SettingsSection(String(localized: "settings.developer.title", defaultValue: "Developer", comment: "Settings category and section title for the hidden developer and diagnostics pane")) {
                SettingsValueRow(
                    title: String(localized: "Commit"),
                    value: Self.commitSHA
                )
                SettingsToggleRow(
                    title: String(localized: "Hero Paint Diagnostics"),
                    subtitle: heroDiagnostics
                        ? String(localized: "Relaunch, wait 90 seconds without touching the remote, then photograph this pane.")
                        : String(localized: "Turn on if asked to capture a hero artwork report, then relaunch the app"),
                    isOn: $heroDiagnostics
                )

                if heroDiagnostics, !heroProbeLines.isEmpty {
                    // H-1A (beta.15): `heroProbeLines` is now head-preserving — the first 16 lines
                    // (the launch head a tester's photo needs) plus, once the tail actually evicts,
                    // one "… N lines elided …" marker and the most recent 32 (see `HomeHeroProbe.log`)
                    // — up to 49 rows total. No special-casing needed here: the marker is just another
                    // string in the array, this `ForEach` already renders any count, and `SettingsSection`
                    // lives inside a native `List`, so the section scrolls naturally as the row count grows.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(heroProbeLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 20, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hero_probe_lines")
                    // The XCUI harness reads the WHOLE buffer through the hidden single-Text probe
                    // below (`hero_probe_blob`) — the List row clips to visible height, so the
                    // per-line `Text` children beyond the fold never enter the accessibility tree and
                    // a snapshot walk of this container sees only the first line or two. (An
                    // `.accessibilityElement(children: .combine)` + `.accessibilityValue` variant was
                    // tried first and did not surface the value on the tvOS 26.5 runtime.) Same
                    // one-hidden-Text pattern as `debug_ux6` (DetailView.swift).
                    .overlay(alignment: .topLeading) {
                        Text(heroProbeLines.joined(separator: "\n"))
                            .font(.system(size: 4))
                            .opacity(0.011)
                            .accessibilityIdentifier("hero_probe_blob")
                    }
                }

                // Grouped so this whole block occupies one slot in `SettingsSection`'s own
                // @ViewBuilder — PlaybackSettingsPane's "Playback" section already sits at the
                // 10-child ViewBuilder ceiling, and the six rows above plus the hero probe's two
                // slots leave no room to add these six ungrouped.
                Group {
                    SettingsToggleRow(
                        title: String(localized: "Tab Bar Diagnostics"),
                        subtitle: tabBarDiagnostics
                            ? String(localized: "Scroll-geometry and push/pop counters below \u{2014} photograph after testing")
                            : String(localized: "Turn on before walking Home down and back up, or running Detail push/pop cycles"),
                        isOn: $tabBarDiagnostics
                    )

                    // T5 (BUG-30/42): the lawful A/B lever for the clipped-reappear bug, next to the
                    // diagnostics toggle above since a device pass runs the two together — diagnose,
                    // then try the lever.
                    SettingsToggleRow(
                        title: String(localized: "Hard Top Scroll Edge (A/B)"),
                        subtitle: String(localized: "BUG-30: try if Home's tab bar still reappears clipped after scrolling up"),
                        isOn: $scrollEdgeHard
                    )

                    if tabBarDiagnostics {
                        // Live readout (Codex beta.14 r6): the probe's counters are plain statics
                        // with no publisher, and this pane can stay mounted while the tester bounces
                        // to Home, runs the protocol, and comes back — a static render would keep
                        // showing the pre-test values, which fakes the exact "callbacks stopped
                        // firing" signature the probe exists to detect. The 1 Hz TimelineView
                        // re-render is the entire invalidation story: every tick re-reads the
                        // statics. It only ticks while the toggle is on and the pane is on screen.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(TabBarProbe.tabNames, id: \.self) { tab in
                                    let state = TabBarProbe.scrollStates[tab] ?? TabBarProbe.ScrollState()
                                    // T1: y/i/r (offsetY / insetTop / residual) replace the old single
                                    // "off=" reading — the sign-fixed residual alone can't tell a
                                    // device pass whether the bar was expanded or minimized when it
                                    // fired, and that's exactly the distinction BUG-66 turns on.
                                    Text("\(tab) f=\(state.fireCount) t=\(state.lastFireMs) y=\(Int(state.lastOffsetY.rounded())) i=\(Int(state.lastInsetTop.rounded())) r=\(Int(state.lastResidual.rounded()))")
                                        .font(.system(size: 20, design: .monospaced))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Text("depth=\(tabBarVisibility.immersiveDepth) cycles=\(TabBarProbe.pushPopCycles)")
                                    .font(.system(size: 20, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("tab_bar_probe_lines")
                    }

                    SettingsToggleRow(
                        title: String(localized: "Stream Diagnostics"),
                        subtitle: streamDiagnostics
                            ? String(localized: "Stream lookups are logged below \u{2014} open the title that fails, press Play, then come back and photograph")
                            : String(localized: "Turn on if asked to capture why a title finds no streams"),
                        isOn: $streamDiagnostics
                    )

                    if streamDiagnostics {
                        // 1 Hz re-read for the same reason the tab-bar readout has one: `StreamProbe`
                        // is a plain static buffer with no publisher, and this pane stays mounted
                        // while the tester goes off to reproduce. A static render would show an empty
                        // log forever, which reads as "the probe is broken".
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            VStack(alignment: .leading, spacing: 2) {
                                if StreamProbe.lines.isEmpty {
                                    Text(String(localized: "No stream lookups yet \u{2014} press Play on the title that fails."))
                                        .font(.system(size: 20))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                } else {
                                    ForEach(Array(StreamProbe.lines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 20, design: .monospaced))
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("stream_probe_lines")
                    }

                    SettingsValueRow(
                        title: String(localized: "Focus Mode"),
                        value: "\(CardFocusMode.resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus))"
                    )
                    SettingsValueRow(
                        title: String(localized: "No Zoom on Focus"),
                        value: noZoomOnFocus ? String(localized: "On") : String(localized: "Off")
                    )
                    SettingsValueRow(
                        title: String(localized: "Accent Focus Ring"),
                        value: accentFocusRing ? String(localized: "On") : String(localized: "Off")
                    )
                    // FEAT-31 attribution: the font ships in this same branch (Theme.Font.uiFont,
                    // used by FEAT-33's own CollectionsUI.swift caption measurement). Added here
                    // rather than the plain About/credits rows above so this Group's ViewBuilder
                    // absorbs it without pushing the outer SettingsSection past its 10-child
                    // @ViewBuilder ceiling (see this file's header comment on that constraint).
                    SettingsValueRow(
                        title: String(localized: "Fonts"),
                        value: "Open Sans — SIL Open Font License 1.1"
                    )
                }

                // Grouped so this whole block (Trailer Diagnostics + BUG-41's Detail Scroll controls)
                // occupies one slot in `SettingsSection`'s own @ViewBuilder, same reasoning as the
                // block above it.
                Group {
                    SettingsToggleRow(
                        title: String(localized: "Trailer Diagnostics"),
                        subtitle: trailerDiagnostics
                            ? String(localized: "Open the title whose trailer looks zoomed, let it play 10 seconds, come back and photograph this pane.")
                            : String(localized: "Turn on if asked to capture why a trailer looks zoomed or letterboxed"),
                        isOn: $trailerDiagnostics
                    )

                    if trailerDiagnostics {
                        // 1 Hz re-read, same reasoning as the tab-bar/stream readouts above:
                        // `TrailerZoomProbe` is a plain lock-guarded buffer with no publisher.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let lines = TrailerZoomProbe.lines
                            VStack(alignment: .leading, spacing: 2) {
                                if lines.isEmpty {
                                    Text(String(localized: "No trailer measurements yet \u{2014} open a title and let its trailer play."))
                                        .font(.system(size: 20))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                } else {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 20, design: .monospaced))
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            // Hidden single-Text blob (mirrors `hero_probe_blob`): the visible
                            // per-line `Text` children beyond the List row's clipped height never
                            // enter the accessibility tree, so a UITest reads the WHOLE buffer
                            // through this one element instead.
                            .overlay(alignment: .topLeading) {
                                Text(lines.joined(separator: "\n"))
                                    .font(.system(size: 4))
                                    .opacity(0.011)
                                    .accessibilityIdentifier("trailer_probe_blob")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("trailer_probe_lines")
                    }

                    SettingsValueRow(
                        title: String(localized: "Trailer zoom cache"),
                        value: trailerZoomCacheCount == 1
                            ? String(localized: "1 entry")
                            : String(localized: "\(trailerZoomCacheCount) entries")
                    )

                    SettingsActionRow(title: String(localized: "Reset trailer zoom cache")) {
                        TrailerZoomCache.shared.removeAll()
                        trailerZoomCacheGeneration += 1
                    }

                    // BUG-41 (Wave F item D): the five-leg on-device A/B knob DetailView reads live —
                    // this pane is the only lawful lever a sideloaded tester has over it.
                    SettingsPickerRow(
                        title: String(localized: "Detail Scroll A/B"),
                        selection: $detailScrollAB,
                        options: [0, 1, 2, 3, 4],
                        label: { leg in
                            leg == 0 ? String(localized: "Off") : "\(leg)"
                        }
                    )

                    SettingsToggleRow(
                        title: String(localized: "Detail Scroll Probe"),
                        subtitle: String(localized: "BUG-41: logs a hitch counter for one Detail visit on Menu-back"),
                        isOn: $detailScrollProbeEnabled
                    )

                    // FEAT-33 (Wave 1, agent C): release-safe frame-timing probe for the Home
                    // collection row's focus-step animation. Same live-toggle pattern as the trailer
                    // diagnostics above it; only the A/B leg is launch-latched (`CollectionFocusAB`
                    // reads it once at process start), hence the relaunch note in the picker's row.
                    SettingsToggleRow(
                        title: String(localized: "Collection Frame Probe"),
                        subtitle: String(localized: "Frame timing per focus step on collection rows; requires relaunch to change the A/B leg"),
                        isOn: $collectionFrameProbe
                    )

                    // `|| enabled`: the harness passes `-debug.collectionFrameProbe YES`, which the
                    // sampler's `UserDefaults.bool(forKey:)` coerces but an `@AppStorage<Bool>` does
                    // not (the argument domain holds the String "YES"), so the readout must also
                    // honour the live read or a launch-arg run shows lines in the log and nothing here.
                    if collectionFrameProbe || CollectionFocusFrameProbe.enabled {
                        // 1 Hz re-read, same reasoning as the trailer/stream readouts above:
                        // `CollectionFocusFrameProbe` is a plain lock-guarded buffer with no publisher.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let lines = CollectionFocusFrameProbe.lines
                            VStack(alignment: .leading, spacing: 2) {
                                Text("refresh=\(UIScreen.main.maximumFramesPerSecond) leg=\(CollectionFocusAB.leg)")
                                    .font(.system(size: 20, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                if lines.isEmpty {
                                    Text(String(localized: "No focus steps measured yet \u{2014} walk a collection row on Home."))
                                        .font(.system(size: 20))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                } else {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 20, design: .monospaced))
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            // Hidden single-Text blob (mirrors `hero_probe_blob`/`trailer_probe_blob`):
                            // the visible per-line `Text` children beyond the List row's clipped
                            // height never enter the accessibility tree, so a UITest reads the WHOLE
                            // buffer through this one element instead.
                            .overlay(alignment: .topLeading) {
                                Text(lines.joined(separator: "\n"))
                                    .font(.system(size: 4))
                                    .opacity(0.011)
                                    .accessibilityIdentifier("collection_frame_blob")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("collection_frame_probe_lines")

                        SettingsActionRow(title: String(localized: "Clear")) {
                            CollectionFocusFrameProbe.clear()
                        }
                    }

                    SettingsPickerRow(
                        title: String(localized: "Collection Focus A/B"),
                        selection: $collectionFocusAB,
                        options: [0, 1, 2, 3],
                        label: { leg in
                            switch leg {
                            case 0: return String(localized: "0 as shipped")
                            case 1: return String(localized: "1 defer hero")
                            case 2: return String(localized: "2 no tile animation")
                            default: return String(localized: "3 both")
                            }
                        }
                    )

                    // BUG-89/BUG-66 (rc2). Nested in its own `Group` rather than added as two more
                    // siblings: the outer `SettingsSection` is already AT the 10-child @ViewBuilder
                    // ceiling (six value rows + the hero toggle + its lines block + these two Groups),
                    // and so is this Group once the toggle and its readout are counted separately.
                    // One nested Group is one child, which is the only room left — same constraint the
                    // two enclosing Groups were introduced for (see this file's header comment).
                    Group {
                        SettingsToggleRow(
                            title: String(localized: "Row Settle Diagnostics"),
                            subtitle: rowSettleDiagnostics
                                ? String(localized: "Relaunch, walk down every row on Home and back up, then photograph this pane")
                                : String(localized: "Turn on if asked to capture a row position report, then relaunch the app"),
                            isOn: $rowSettleDiagnostics
                        )

                        if rowSettleDiagnostics, !rowSettleProbeLines.isEmpty {
                            // BUG-100 (rc6, Steven's tester photo): newest-first ordering
                            // (`PinnedRowSettleProbe.displayOrder`) fixed WHICH lines are most
                            // valuable at the top, but rc7's photo showed the List row still clips
                            // after ~3 lines once this caption takes one — one clipped block can
                            // never show the 28-line rolling tail regardless of ordering.
                            //
                            // BUG-102 (rc7): PAGED instead. One List row PER PAGE of
                            // `PinnedRowSettleProbe.displayPages(...)`, a few lines each, so the
                            // tester scrolls the About LIST itself — native, focus-driven scrolling,
                            // not the block's own clipped height — and photographs one page at a
                            // time. See that function's doc comment for the exact chunking.
                            //
                            // The persisted order is untouched by any of this: `settle_probe_blob`
                            // below still joins `rowSettleProbeLines` as logged (chronological), not
                            // the reordered/paged display order, because the XCUI harness's readers
                            // depend on that shape.
                            Text(String(localized: "Newest first; the launch lines are at the end."))
                                .font(SettingsRowFont.subtitle)
                                .foregroundStyle(.secondary)

                            let pages = PinnedRowSettleProbe.displayPages(rowSettleProbeLines)
                            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageLines in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "Row Settle Diagnostics · page \(pageIndex + 1)/\(pages.count)"))
                                        .font(SettingsRowFont.subtitle)
                                        .foregroundStyle(.secondary)
                                    // Identical in shape to the hero probe's block above, including
                                    // `.truncationMode(.middle)`, which is load-bearing here rather
                                    // than cosmetic: a settle report is long, and the two ends are
                                    // exactly what a reader needs (the head carries
                                    // `row= margin= net= vh=`, the tail carries
                                    // `nudge=… endOfContent=… room=…`).
                                    ForEach(Array(pageLines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 20, design: .monospaced))
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // A native `List` only scrolls as far as focus can move — a page with
                                // no focusable content is a dead end the remote can never reach past.
                                // Same no-op-focusable pattern `PersonDetailView.topBlock` documents:
                                // Select does nothing, Menu still pops the screen as normal, this
                                // exists purely so the tester can swipe/click down to the next page.
                                .focusable()
                                .accessibilityIdentifier(pageIndex == 0 ? "settle_probe_lines" : "settle_probe_page_\(pageIndex + 1)")
                                .overlay(alignment: .topLeading) {
                                    if pageIndex == 0 {
                                        // Same hidden single-Text blob as `hero_probe_blob`: the List
                                        // row clips to visible height, so per-line children beyond the
                                        // fold never enter the accessibility tree and a harness walk
                                        // would read one or two lines. Joins the PERSISTED
                                        // (chronological) order, not the visible paged/reordered one —
                                        // harness readers that cross-reference this blob against a
                                        // device log depend on that shape being unchanged.
                                        Text(rowSettleProbeLines.joined(separator: "\n"))
                                            .font(.system(size: 4))
                                            .opacity(0.011)
                                            .accessibilityIdentifier("settle_probe_blob")
                                    }
                                }
                            }
                        }

                        // BUG-66 evidence probe (2026-09-10): nested in this SAME Group rather than as
                        // a new sibling of it — the outer `SettingsSection` and this Group's own
                        // parent `Group` are both already at the 10-child @ViewBuilder ceiling
                        // documented above this file's `Group` blocks, but THIS inner Group itself
                        // only held two children (the toggle and its conditional readout) before this
                        // addition, so there is room here without touching either ceiling.
                        SettingsToggleRow(
                            title: String(localized: "Tab Bar Geometry Diagnostics"),
                            subtitle: tabBarStateDiagnostics
                                ? String(localized: "Relaunch, scroll Home down ten rows and back up, then photograph this panel")
                                : String(localized: "Turn on if asked to capture the tab bar's on-device geometry, then relaunch the app"),
                            isOn: $tabBarStateDiagnostics
                        )

                        if tabBarStateDiagnostics, !tabBarStateProbeLines.isEmpty {
                            // Same newest-first, paged rendering as Row Settle Diagnostics above,
                            // reusing `PinnedRowSettleProbe.displayOrder`/`displayPages` directly (see
                            // this file's property doc comment on `tabBarStateProbeLines`).
                            Text(String(localized: "Newest first; the launch lines are at the end."))
                                .font(SettingsRowFont.subtitle)
                                .foregroundStyle(.secondary)

                            let tabBarStatePages = PinnedRowSettleProbe.displayPages(tabBarStateProbeLines)
                            ForEach(Array(tabBarStatePages.enumerated()), id: \.offset) { pageIndex, pageLines in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "Tab Bar Geometry Diagnostics · page \(pageIndex + 1)/\(tabBarStatePages.count)"))
                                        .font(SettingsRowFont.subtitle)
                                        .foregroundStyle(.secondary)
                                    ForEach(Array(pageLines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 20, design: .monospaced))
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Same no-op-focusable pattern as the Row Settle pages above: a native
                                // `List` only scrolls as far as focus can move, so a page needs a
                                // focusable anchor even though Select does nothing on it.
                                .focusable()
                                .accessibilityIdentifier(pageIndex == 0 ? "tab_bar_state_probe_lines" : "tab_bar_state_probe_page_\(pageIndex + 1)")
                                .overlay(alignment: .topLeading) {
                                    if pageIndex == 0 {
                                        // Hidden single-Text blob, same pattern as `settle_probe_blob`:
                                        // joins the PERSISTED (chronological) order, not the visible
                                        // paged/reordered one.
                                        Text(tabBarStateProbeLines.joined(separator: "\n"))
                                            .font(.system(size: 4))
                                            .opacity(0.011)
                                            .accessibilityIdentifier("tab_bar_state_probe_blob")
                                    }
                                }
                            }
                        }

                        // BUG-87 rc12 follow-up: fifth child of this Group (Row Settle toggle + its
                        // conditional readout, Tab Bar Geometry toggle + its conditional readout, now
                        // this) — the outer `SettingsSection` and this Group's own parent `Group` stay
                        // untouched; only this innermost Group gains a sibling.
                        SettingsToggleRow(
                            title: String(localized: "No Zoom Row Reach (A/B)"),
                            subtitle: noZoomReachHoldsLift
                                ? String(localized: "Rows reserve the zoom-mode band; the hero-off description loses a line at Large")
                                : String(localized: "BUG-87: try if row titles fade or bounce with No Zoom on Focus"),
                            isOn: $noZoomReachHoldsLift
                        )

                        // CW legacy diagnosis (REMAINING_FIX #1): sixth child of this Group, one view
                        // holding its toggle, Refresh and pages — the outer `SettingsSection` and this
                        // Group's parent stay at their ceiling, untouched. Live, no relaunch.
                        ContinueWatchingDiagnosticsRows()
                    }
                }
            }

            SettingsSection(
                String(localized: "settings.developer.fallbacks.title", defaultValue: "Fallbacks",
                       comment: "Developer settings section with switches that bring back the previous app-drawn controls"),
                footer: String(localized: "settings.developer.fallbacks.footer",
                               defaultValue: "Use these only if the system control misbehaves on this Apple TV. The search field change applies after relaunching the app.",
                               comment: "Footer under the developer fallback switches")
            ) {
                SettingsToggleRow(
                    title: String(localized: "settings.developer.searchLegacyField", defaultValue: "Plain Search Field",
                                  comment: "Developer switch: replace the system search field with a plain text field"),
                    isOn: $searchLegacyField
                )
                SettingsToggleRow(
                    title: String(localized: "settings.developer.pinLegacyPad", defaultValue: "App PIN Pad",
                                  comment: "Developer switch: use the app's own number pad instead of the system PIN screen"),
                    isOn: $pinLegacyPad
                )
            }

            SettingsSection(nil, footer: String(localized: "settings.developer.hide.footer", defaultValue: "Turns every diagnostic above off and hides this pane. Press Version in About seven times to show it again.", comment: "Footer under the button that hides the developer pane")) {
                SettingsDestructiveRow(
                    title: String(localized: "settings.developer.hide", defaultValue: "Hide Developer Settings", comment: "Button that hides the developer pane and turns its diagnostics off"),
                    systemImage: "eye.slash"
                ) {
                    DeveloperMode.lock()
                }
            }
        }
        .onAppear {
            heroProbeLines = UserDefaults.standard.stringArray(forKey: "debug.homeHeroProbe.lines") ?? []
            rowSettleProbeLines = UserDefaults.standard.stringArray(forKey: PinnedRowSettleProbe.linesKey) ?? []
            tabBarStateProbeLines = UserDefaults.standard.stringArray(forKey: TabBarStateProbe.linesKey) ?? []
        }
        // The shared-side sink is installed/removed here rather than at the toggle, so it also
        // recovers if the switch was flipped in a previous session (startup does the same call).
        .onChange(of: streamDiagnostics) { _, _ in StreamProbe.syncSink() }
    }

    /// Stamped by the same build phase from `git rev-parse --short=8 HEAD`.
    private static var commitSHA: String {
        let sha = (Bundle.main.object(forInfoDictionaryKey: "NuvioCommitSHA") as? String) ?? ""
        return sha.isEmpty ? "\u{2014}" : sha
    }
}

/// Persisted unlock state for the Developer pane (VIS-01), plus the reset that hides it again.
/// `nonisolated` so launch-latched probe gates (`TabBarStateProbe.enabled`) can read it from any
/// context, the same way they read their own `debug.*` keys.
enum DeveloperMode {
    nonisolated static let unlockedKey = "developer.unlocked"

    /// Presses on the About pane's Version row needed to unlock the pane.
    nonisolated static let unlockPressCount = 7

    nonisolated static var isUnlocked: Bool {
        UserDefaults.standard.bool(forKey: unlockedKey)
    }

    /// Every UserDefaults key a Developer row writes. Removing them returns each `@AppStorage`
    /// binding to its declared default (all off / leg 0), so a locked pane leaves no probe running.
    nonisolated static let diagnosticKeys: [String] = [
        "debug.homeHeroProbe",
        "debug.pinnedRowSettleProbe",
        "debug.tabBarStateProbe",
        "debug.tabBarProbe",
        "debug.homeScrollEdgeHard",
        "debug.streamProbe",
        "debug.trailerDiagnostics",
        "debug.detailScrollAB",
        "debug.detailScrollProbe",
        "debug.collectionFrameProbe",
        "debug.collectionFocusAB",
        "debug.cwDiagnostics",
        "debug.searchLegacyField",
        PinEntryView.legacyPadKey,
        PinnedRowTitle.noZoomReachHoldsLiftKey,
    ]

    /// Switches every diagnostic off and hides the Developer category. Launch-latched probes stop
    /// on the next launch, like they always have when their toggle is turned off.
    @MainActor
    static func lock() {
        let defaults = UserDefaults.standard
        for key in diagnosticKeys {
            defaults.removeObject(forKey: key)
        }
        StreamProbe.syncSink()
        defaults.set(false, forKey: unlockedKey)
    }
}
