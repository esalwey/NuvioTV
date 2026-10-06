import SwiftUI
import SharedCore

/// The Settings tab: a two-pane split — a native `List` of categories on the left (~1/3), the
/// selected category's pane rendered inside a native `List` on the right (~2/3), under one page
/// title. Each category's rows live in their own `*SettingsPane` file; the shared row primitives
/// live in Settings/SettingsRowViews.swift.
///
/// beta.15 §C (C2): this was a hand-rolled `HStack` of custom `SettingsRowButtonStyle` buttons in
/// a `ScrollView`. Everything focus- and colour-related is now the system's job — no custom
/// `ButtonStyle`, no `hoverEffect`, no focus-derived label colours (the BUG-45 sidebar
/// special-case and the BUG-65 published-focus-environment-key hack are gone from this file).
///
/// ## Focus graph (written before the code, per the tvOS skill's workflow)
///
/// **Default focus.** F15: the sidebar `List` carries
/// `.defaultFocus($focusedCategory, selectedCategory, priority: .userInitiated)` — on a cold mount
/// that is the first row (Account & Services), and after a theme-change remount it is whichever
/// category the user was standing in, so picking a theme swatch no longer throws them to the top.
/// `.userInitiated` makes the same rule apply when the user moves INTO the sidebar (from the tab
/// bar, or back from a pushed sub-page), not only when the system picks an initial focus — the
/// earlier `prefersDefaultFocus(_:in:)` scope only covered the latter, so entering Settings from
/// the tab bar could land on whichever row sat under the bar instead of the selected category.
/// There is no `@FocusState` write on appear: the default-focus rule is the only mechanism.
///
/// **Sidebar.**
/// - Up / Down walk the eight categories (nine once the hidden Developer pane is unlocked). Focus *is* selection: `onChange(of: focusedCategory)`
///   writes `selectedCategory`, so the detail pane live-previews the focused category (the
///   Settings.app behaviour the old screen had, kept deliberately).
/// - Up from the first row leaves the list upward and lands on the app's tab bar (the standard
///   tvOS top-edge exit). Down from the last row does nothing — the list ends.
/// - Left does nothing: the sidebar is the leading edge of the screen.
/// - Right enters the detail `List` and lands on its first focusable row.
///
/// **Detail.**
/// - Up / Down walk the rows and sections; the `List` scrolls to reveal.
/// - Left from any row returns to the sidebar, on the row that is still selected (the sidebar
///   keeps its focus memory, so the walk resumes where it left off).
/// - Right does nothing at row level. Inside a row it is the control's own business: a `Toggle`
///   ignores it, a `Menu { Picker }` opens on Select, not on Right.
/// - Up from the first detail row leaves upward to the tab bar; Down from the last does nothing.
///
/// **Empty / error panes (BUG-47 class).** A pane whose `List` has no focusable row cannot be
/// entered: Right from the sidebar is a no-op and focus stays on the category row — it is never
/// stranded, and Menu still exits cleanly. Every pane today has at least one focusable control in
/// every state (e.g. Advanced offers "Start Remote Setup" when the server is stopped), and every
/// pushed sub-page a `SettingsLinkRow` presents must keep one too.
///
/// **Menu.** Exactly one level per press, all of it the system's default — this file installs no
/// `onExitCommand` anywhere. Inside an open `Menu`/`Picker` popover it dismisses the popover; on a
/// page pushed by a `SettingsLinkRow` it pops back to the detail list; at the `NavigationStack`
/// root (the split itself) it leaves Settings for the app's tab bar. An `.alert` is dismissed by
/// its own Cancel button.
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @StateObject private var trakt = TraktViewModel()
    @StateObject private var simkl = SimklViewModel()
    @StateObject private var debrid = DebridViewModel()
    @StateObject private var remote = RemoteSetupViewModel()
    @StateObject private var plugins = PluginsViewModel()
    @StateObject private var badges = BadgeSettingsViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @State private var confirmingSignOut = false
    @State private var confirmingTraktDisconnect = false
    @State private var confirmingSimklDisconnect = false
    /// Provider id pending a debrid disconnect confirmation (drives the alert).
    @State private var debridDisconnectId: String?
    /// "Use the official server?" confirmation (self-hosted → api.nuvio.tv switch-back).
    @State private var confirmingUseOfficial = false
    /// Which category's sections are shown in the detail pane. Non-optional (panes and the pane
    /// switch below read it directly); the `List`'s selection binding adapts it.
    ///
    /// A `@Binding` owned by `ContentView`, NOT local `@State`: `ContentView` pins
    /// `.id(appTheme.themeName)` on the app root, so choosing a theme swatch in the Appearance pane
    /// remounts this whole view. While this was `@State` that remount reset the split to
    /// `.accountServices` — the user pressed a colour and was thrown to the top of Settings with
    /// nothing visibly changed. Same fix, and same reason, as `selectedTab`.
    @Binding var selectedCategory: SettingsCategory
    /// Theme name whose swatch should reclaim focus after a theme-change remount (see
    /// `ContentView.pendingThemeSwatchFocus`); the Appearance pane consumes and clears it.
    @Binding var pendingThemeSwatchFocus: String?
    /// FEAT-30/31: which Appearance row ("navigation" / "typeface") should reclaim focus after a
    /// remount (see `ContentView.pendingAppearanceRowFocus`); the Appearance pane consumes and
    /// clears it, same contract as `pendingThemeSwatchFocus`.
    @Binding var pendingAppearanceRowFocus: String?
    @FocusState private var focusedCategory: SettingsCategory?
    /// VIS-01: the hidden Developer category is listed only once Version has been pressed seven
    /// times in About (`DeveloperMode`). Hiding it again while it is selected falls back to About.
    @AppStorage(DeveloperMode.unlockedKey) private var developerUnlocked = false
    /// FEAT-7: "Default" shows the category icon; "Minimal" drops it for a denser sidebar. Set
    /// from the Appearance pane's Settings Style chips.
    @AppStorage("settings_style") private var settingsStyle = "default"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // One title for the whole split (HIG Split views: never one per pane).
                Text("Settings")
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.top, Theme.Spacing.lg)

                GeometryReader { geo in
                    HStack(spacing: 0) {
                        categorySidebar
                            .frame(width: max(400, geo.size.width / 3))

                        detailPane
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // Wave 2 (decision D1): the shell is the system `.sidebarAdaptable` sidebar, which
            // owns Menu at a tab root itself, so the old `.sidebarMenuReveal()` hook is gone.
            .background(Theme.Palette.background.ignoresSafeArea())
        }
        .onChange(of: developerUnlocked) { _, unlocked in
            if !unlocked, selectedCategory == .developer { selectedCategory = .about }
        }
        .onAppear {
            model.start()
            trakt.start()
            simkl.start()
            debrid.start()
            plugins.start()
            badges.start()
        }
        .onDisappear {
            model.stop()
            trakt.stop()
            simkl.stop()
            debrid.stop()
            plugins.stop()
            badges.stop()
            remote.stop()
        }
        .alert(
            "Apply changes from browser?",
            isPresented: Binding(
                get: { remote.pendingChange != nil },
                set: { if !$0 { remote.rejectPending() } }
            )
        ) {
            Button("Apply") { remote.confirmPending() }
            Button("Decline", role: .cancel) { remote.rejectPending() }
        } message: {
            Text(remote.pendingSummary)
        }
        .alert("Disconnect Trakt?", isPresented: $confirmingTraktDisconnect) {
            Button("Disconnect", role: .destructive) { trakt.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Trakt access token is revoked. Your Trakt history is untouched.")
        }
        .alert("Disconnect Simkl?", isPresented: $confirmingSimklDisconnect) {
            Button("Disconnect", role: .destructive) { simkl.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Simkl authorization is cleared. Your Simkl history is untouched.")
        }
        .alert(
            String(localized: "Disconnect debrid provider?", defaultValue: "Disconnect Debrid Provider?",
                   comment: "Alert title before removing a debrid provider key"),
            isPresented: Binding(
                get: { debridDisconnectId != nil },
                set: { if !$0 { debridDisconnectId = nil } }
            )
        ) {
            Button("Disconnect", role: .destructive) {
                if let id = debridDisconnectId { debrid.disconnect(id) }
                debridDisconnectId = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this provider's key from this profile. Streams will no longer resolve through it.")
        }
        .alert(
            auth.isAnonymous
                ? String(localized: "Switch to a Nuvio account?", defaultValue: "Switch to a Nuvio Account?",
                         comment: "Alert title before a guest signs in to a Nuvio account")
                : String(localized: "Sign out?", defaultValue: "Sign Out?",
                         comment: "Alert title before signing out"),
            isPresented: $confirmingSignOut
        ) {
            Button(auth.isAnonymous ? String(localized: "Continue") : String(localized: "Sign Out"), role: .destructive) {
                // Clears the session AND wipes local data (AccountDataCleaner seam), then the root
                // gate drops to the Welcome screen where an account can be signed in.
                auth.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                auth.isAnonymous
                    ? "Guest data on this Apple TV (profiles, library, watch progress) will be cleared. You can then sign in on the welcome screen."
                    : "Local data on this Apple TV will be cleared. Your synced data stays in your Nuvio account."
            )
        }
        .alert("Use the official server?", isPresented: $confirmingUseOfficial) {
            Button("Switch", role: .destructive) {
                // Fire-and-forget into the shared controller: clears the session + local data,
                // saves the official config, resets the Supabase client and re-inits auth — the
                // root gate drops to Welcome (which unmounts Settings).
                ServerConnectionController.shared.useOfficial()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You\u{2019}ll be signed out of the self-hosted server and local data on this Apple TV will be cleared. Nuvio will reconnect to api.nuvio.tv.")
        }
    }

    /// Right column: the selected pane's sections inside a native `List`. `settingsUsesNativeList`
    /// tells the shared `settingsSection(_:)` helper it may emit a real `Section` here (it stays
    /// on the legacy stack everywhere else — see SettingsRowViews.swift).
    @ViewBuilder
    private var detailPane: some View {
        if selectedCategory == .addons {
            // Wave 2 (decision D1, VIS-13): Add-ons is no longer a tab. `AddonsView` already
            // renders its own system `List`, so it is hosted directly rather than nested inside
            // another one. Its `.navigationTitle` would put a second title in the bar above the
            // split's own "Settings" title, so the bar is hidden at this root only; pages pushed
            // from it keep theirs.
            AddonsView(embedded: true)
                .toolbar(.hidden, for: .navigationBar)
        } else {
            List {
                pane
            }
            .environment(\.settingsUsesNativeList, true)
        }
    }

    /// The detail pane's content for the currently selected sidebar category. Only the selected
    /// category's pane is built (not the others), matching the previous per-section filtering —
    /// keeps focus + perf clean.
    @ViewBuilder
    private var pane: some View {
        switch selectedCategory {
        case .accountServices:
            AccountServicesSettingsPane(
                trakt: trakt,
                simkl: simkl,
                debrid: debrid,
                confirmingSignOut: $confirmingSignOut,
                confirmingTraktDisconnect: $confirmingTraktDisconnect,
                confirmingSimklDisconnect: $confirmingSimklDisconnect,
                debridDisconnectId: $debridDisconnectId,
                confirmingUseOfficial: $confirmingUseOfficial
            )
        case .playback:
            PlaybackSettingsPane(model: model)
        case .appearance:
            AppearanceSettingsPane(
                model: model,
                badges: badges,
                pendingThemeSwatchFocus: $pendingThemeSwatchFocus,
                pendingAppearanceRowFocus: $pendingAppearanceRowFocus
            )
        case .homeScreen:
            HomeScreenSettingsPane(model: model)
        case .contentSources:
            ContentSourcesSettingsPane(model: model, plugins: plugins)
        case .addons:
            // Hosted by `detailPane` outside the `List`; never reached through this switch.
            EmptyView()
        case .advanced:
            AdvancedSettingsPane(remote: remote)
        case .about:
            AboutSettingsPane()
        case .developer:
            if developerUnlocked {
                DeveloperSettingsPane()
            } else {
                AboutSettingsPane()
            }
        }
    }

    /// Sidebar rows: every category, minus Developer until it is unlocked.
    private var visibleCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { $0 != .developer || developerUnlocked }
    }

    /// Left column: one focusable row per category, in a native `List`. Focusing a row
    /// live-selects it (the tvOS Settings pattern); Right enters the pane.
    ///
    /// Rows are `Button`s, not bare `Label`s: a plain `Label` inside `List(selection:)` is NOT
    /// focusable on tvOS (C0 spike finding), so selection alone can't drive the walk. No
    /// `foregroundStyle` here on purpose — the system inverts the row's label colour on the focus
    /// platter, which is what BUG-45's hand-rolled three-way colour switch was working around.
    private var categorySidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(visibleCategories) { category in
                Button {
                    selectedCategory = category
                } label: {
                    if settingsStyle == "minimal" {
                        Text(category.title)
                            .font(Theme.Font.body)
                    } else {
                        // FEAT-31 (rc2 tester report, 2026-09-06): the category labels carried no font
                        // token, so a `List` row's system default rendered them while every other
                        // Settings label took the Open Sans face. Both branches now read `Theme.Font.body`.
                        // HStack, not `Label`: the system label's icon-to-title spacing is too tight in a tvOS
                        // List row (device pass 2026-08-28, and the tester's "icons overlap the text" report) —
                        // this matches the detail rows' `SettingsRowLabel` spacing instead.
                        // Icon `.secondary` at rest (monochrome, like tvOS Settings), `.primary`
                        // under the focus platter — same `SettingsAccentTint` the detail rows use. The label itself keeps
                        // NO explicit colour (BUG-45: an accent label here was white-on-white for
                        // the White theme's near-white accent).
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: category.icon)
                                .settingsAccentTint()
                                // Decorative: `Label` used to fold the symbol into one
                                // accessibility element; the raw HStack must not let VoiceOver
                                // announce the symbol's generated name before the title.
                                .accessibilityHidden(true)
                            Text(category.title)
                                .font(Theme.Font.body)
                        }
                    }
                }
                .tag(category)
                .focused($focusedCategory, equals: category)
            }
        }
        // F15: the default follows the SELECTED category rather than always the first row. On a
        // cold mount `selectedCategory` is `.accountServices` — the first row — so the documented
        // "entering Settings lands on Account & Services" behaviour is unchanged. After a
        // theme-change remount it lands back on the category the user was actually in, and
        // (because focus IS selection here) the `onChange` below then re-writes the same value
        // instead of clobbering it with the first row's. `.userInitiated` applies it to the
        // user's own moves into the sidebar too (tab bar → Settings), not only to system picks.
        .defaultFocus($focusedCategory, selectedCategory as SettingsCategory?, priority: .userInitiated)
        .onChange(of: focusedCategory) { _, newValue in
            // Live-preview the focused category in the detail pane.
            if let newValue { selectedCategory = newValue }
        }
    }

    /// `List(selection:)` wants an optional binding; the screen's own state is non-optional so the
    /// pane switch (and the panes) never deal with "no category".
    private var sidebarSelection: Binding<SettingsCategory?> {
        Binding(
            get: { selectedCategory },
            set: { if let newValue = $0 { selectedCategory = newValue } }
        )
    }
}

/// Settings categories for the split-view sidebar. Order here is the sidebar order.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountServices
    case playback
    case appearance
    case homeScreen
    case contentSources
    /// Wave 2 (decision D1): the former Add-ons tab, hosted in Settings.
    case addons
    case advanced
    case about
    /// VIS-01: hidden until unlocked from About (see `SettingsView.visibleCategories`).
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accountServices: return String(localized: "Account & Services")
        case .playback: return String(localized: "Playback")
        case .appearance: return String(localized: "Appearance")
        case .homeScreen: return String(localized: "Home Screen")
        case .contentSources: return String(localized: "Content Sources")
        case .addons: return String(localized: "Add-ons")
        case .advanced: return String(localized: "Advanced")
        case .about: return String(localized: "About")
        case .developer:
            return String(localized: "settings.developer.title", defaultValue: "Developer", comment: "Settings category and section title for the hidden developer and diagnostics pane")
        }
    }

    var icon: String {
        switch self {
        case .accountServices: return "person.crop.circle"
        case .playback: return "play.rectangle"
        case .appearance: return "paintbrush"
        case .homeScreen: return "house"
        case .contentSources: return "square.stack.3d.up"
        case .addons: return "puzzlepiece.extension"
        case .advanced: return "gearshape.2"
        case .about: return "info.circle"
        case .developer: return "hammer"
        }
    }
}
