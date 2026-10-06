import SwiftUI
import SharedCore

/// Root gate. Auth state decides the outer screen (splash → welcome → app); once authenticated
/// (guest or account), the "Who's watching?" profile picker gates the main tab shell. Choosing a
/// profile drives per-profile data scoping (via `ActiveProfileProvider`) and, for signed-in
/// accounts, kicks off the full cloud pull for that profile.
struct ContentView: View {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var profiles = ProfilesViewModel()
    @StateObject private var posterStyle = PosterStyleModel()
    @StateObject private var cardDepth = CardDepthStyleModel()
    @StateObject private var appTheme = AppThemeModel()
    /// H-1B-ii (beta.15): Home's view model lives HERE, above the `.id(appTheme.themeName)` rebuild
    /// boundary applied to the `Group` below, so a theme flip (which a profile-scoped sync pull can
    /// deliver minutes after cold launch) rebuilds Home's VIEWS without rebuilding Home's DATA.
    /// While `HomeView` owned it via `@StateObject`, that rebuild produced a second
    /// `HomeViewModel` — replayed StateFlow publish (duplicate hero head), a second forced
    /// `HomeRepository.refresh`, and two hero paint pipelines alive across the swap: the tester's
    /// "doubled hero". `HomeView` now only `acquire()`s / `release()`s it (refcounted because
    /// SwiftUI inserts the incoming subtree before removing the outgoing one), and this view hard-
    /// stops it on profile exit below — the teardown Home's view lifetime used to do implicitly.
    ///
    /// Codex wave-4 (P1) — `@State`, NOT `@StateObject`, and load-bearing exactly like
    /// `MainTabView.tabBarVisibility` (T3): `@State` on a reference type stores the instance once
    /// with the same lifetime but WITHOUT subscribing this view to `objectWillChange`. With
    /// `@StateObject`, every hero/row/progress publication would re-evaluate the entire app root
    /// (Group + MainTabView) — restoring the shell-wide invalidation storm T3 removed. Only
    /// `HomeView` (via `@ObservedObject`) is supposed to observe this model.
    @State private var home = HomeViewModel()
    @StateObject private var topShelf = TopShelfUpdater()
    @State private var entered = false
    /// Upstream 519510591 + 6761ebabb: true while "Who's watching?" was opened from inside the app
    /// (Settings → Switch Profile, via `\.switchProfile`) instead of as the launch gate: picking the running profile,
    /// or Menu, then goes straight back without a PIN, a repository fan-out or a cloud pull.
    @State private var switchingProfile = false
    @State private var selectedTab = 0
    /// Which Settings category the split view is showing. Owned HERE, above the
    /// `.id(appTheme.themeName)` rebuild boundary, for exactly the reason `selectedTab` is: picking
    /// a theme swatch re-identifies the whole tree, and while this was a plain `@State` inside
    /// `SettingsView` the split snapped back to the first category (Account & Services) on every
    /// theme change — so pressing a colour looked like it had done nothing at all, which is how the
    /// "the theme picker doesn't work" report reads on screen.
    @State private var settingsCategory: SettingsCategory = .accountServices
    /// Set when the user picks a theme swatch, cleared once the Appearance pane has taken focus
    /// back. Owned HERE for the same reason as `settingsCategory`: the swatch press re-identifies
    /// the whole tree, and focus — unlike state — cannot survive a remount at all, so it fell to
    /// the tab bar and the user was thrown to the top of Settings. The hint lets the rebuilt pane
    /// put focus back on the swatch it was on. Not persisted: a cold launch must never steal
    /// focus into Appearance.
    @State private var pendingThemeSwatchFocus: String?
    /// FEAT-30/31: same job as `pendingThemeSwatchFocus`, for the two Appearance rows that also
    /// remount the whole tree when pressed — the navigation-style picker (tabs ↔ sidebar) and the
    /// UI-font picker (see the `.id` below). Owned HERE for the identical reason: focus cannot
    /// survive a remount at all, so without a hint the rebuilt pane drops the user at the top of
    /// Settings and the row they just changed looks like it did nothing.
    ///
    /// Wave 1 (agent A) only OWNS the state and threads it as far as `MainTabView` — the Settings
    /// files belong to another wave, so `SettingsView`'s signature is deliberately untouched here.
    /// Not persisted: a cold launch must never steal focus into Appearance.
    @State private var pendingAppearanceRowFocus: String?
    /// FEAT-31: the UI font family (`"system"` default / `"openSans"`). Also purely a rebuild-key
    /// input — `Theme.Font` resolves the family itself, and its tokens are static reads that only
    /// re-evaluate when the tree is re-identified, exactly like `Theme.Palette.accent`.
    @AppStorage(Theme.AppFontFamily.defaultsKey) private var uiFont = "system"
    /// Deep link currently presented (Top Shelf → resume / title). Held until the user is past
    /// the auth + profile gates when the app is cold-launched from the Top Shelf.
    @State private var deepLink: DeepLink?
    @State private var pendingDeepLinkURL: URL?
    /// The player asked for the title's details page during a Top Shelf resume (Up Next cancel,
    /// "Back to Details", the end of a movie or finale): shown once the resume cover has closed.
    @State private var deepLinkDetailAfterResume: MetaPreview?
    @Environment(\.scenePhase) private var scenePhase

    /// Upstream 519510591 + 6761ebabb: the picker's way back into the profile the app is running
    /// (nil at the launch gate). No PIN, no fan-out, no pull — the repositories still hold it.
    private var returnToRunningProfile: (() -> Void)? {
        guard switchingProfile else { return nil }
        return {
            switchingProfile = false
            profiles.resumeSessionProfile()
            entered = true
        }
    }

    var body: some View {
        Group {
            switch auth.gate {
            case .loading:
                ZStack {
                    Theme.Palette.background.ignoresSafeArea()
                    ProgressView()
                        .tint(Theme.Palette.accent)
                }
            case .welcome:
                WelcomeView(model: auth)
            case .main:
                if entered {
                    MainTabView(
                        activeProfile: profiles.activeProfile,
                        // H-1B-ii: handed down (not re-created) so the theme `.id()` rebuild of
                        // this Group cannot re-create Home's data pipeline.
                        home: home,
                        onSwitchProfile: { switchingProfile = true; entered = false },
                        selectedTab: $selectedTab,
                        settingsCategory: $settingsCategory,
                        pendingThemeSwatchFocus: $pendingThemeSwatchFocus,
                        pendingAppearanceRowFocus: $pendingAppearanceRowFocus,
                        // FEAT-25 (Codex beta.14 r8): the app-root deep-link cover (Top Shelf)
                        // presents over the whole shell without touching tab selection or push
                        // depth — it must count as covering Home, or the hero trailer plays
                        // audibly beneath DeepLinkTitleView/StreamPickerView.
                        rootCoverActive: deepLink != nil
                    )
                    .environmentObject(auth)
                } else {
                    // `reseedNow()` BEFORE `entered = true`: the chosen profile's theme must be
                    // applied while only this picker is mounted, or MainTabView mounts under the
                    // boot-time theme and the async watcher delivery remounts the whole shell
                    // ~70ms later (see AppThemeModel.reseedNow).
                    ProfileSelectionView(
                        model: profiles,
                        onSelected: { switchingProfile = false; appTheme.reseedNow(); entered = true },
                        onReturnToApp: returnToRunningProfile
                    )
                }
            }
        }
        .environment(\.posterStyle, posterStyle.style)
        .environment(\.cardDepthStyle, cardDepth.style)
        // NOTE — deliberately NO app-root `.tint(Theme.Palette.accent)`. It looks like the obvious
        // way to make stock controls follow the theme, and it was tried (2026-08-25, sim-verified
        // via test43's `43b` capture): on tvOS it repaints the `Menu { Picker }` row's LABEL PILL
        // with the accent, and the pill's label is drawn in a colour chosen for the default grey
        // fill — the Settings Style / Size / Corners rows became solid accent bars with invisible
        // text. Settings gets its accent from explicit, per-element tinting in the row kit
        // (`SettingsAccentTint` in SettingsRowViews.swift) instead, which never touches a control's
        // background.
        // Theme change → rebuild the tree so every static Theme.Palette.accent read re-evaluates.
        // Focus resets on change; the state that would visibly strand the user — the selected tab
        // and the Settings category — is held above this boundary so it survives.
        //
        // FEAT-31 joins the key: `uiFont` is read through `Theme.Font`'s static cache, the same
        // static-read pattern `Palette.accent` uses, so it needs the same re-identification to
        // take effect. (VIS-16 retired the FEAT-30 `sidebar_style` term: the shell is always the
        // system sidebar now.) Selected tab, Settings category and the two focus hints above are
        // all held ABOVE this boundary, so a font change costs the user nothing but the rebuild.
        // STAB-10: `AppThemeModel` holds a synced theme change back while a full-screen cover
        // (the player, a deep link) is up, so this rebuild never tears a cover down mid-play.
        .id("\(appTheme.themeName)|\(uiFont)")
        .onAppear {
            auth.start()
            posterStyle.start()
            cardDepth.start()
            appTheme.start()
            #if DEBUG
            // FEAT-5 device diagnostic: prints what the external-player probe sees. A scheme
            // missing from LSApplicationQueriesSchemes logs a "not allowed to query" console
            // error and returns false; a declared scheme with no installed handler returns
            // false silently — so this output distinguishes plist problems from the target
            // player simply not registering its URL scheme on tvOS.
            for scheme in ["infuse", "vlc-x-callback", "outplayer", "open-vidhub", "vidhub"] {
                if let url = URL(string: "\(scheme)://") {
                    print("[ExtPlayerProbe] canOpenURL(\(scheme)://) = \(UIApplication.shared.canOpenURL(url))")
                }
            }
            let players = ExternalPlayerPlatform.shared.availablePlayers()
            print("[ExtPlayerProbe] availablePlayers = \(players.map { "\($0.id):\($0.name)" })")
            #endif
        }
        .onChange(of: auth.gate) { _, newGate in
            // Signing out (or a remote session invalidation) tears the shell down to the gate.
            // STAB-10 / STAB-01 (UI half): ONLY `.welcome` is a sign-out. A transient `.loading`
            // (a token refresh in flight) must not drop the profile, stop Home's pipeline or send
            // the user back to "Who's watching?": the body shows the spinner meanwhile and the
            // shell comes back as it was once the gate returns to `.main`.
            if newGate == .welcome {
                entered = false
                switchingProfile = false
                // H-1B-ii: hard teardown of Home's (profile-scoped) watchers. `home` now outlives
                // `HomeView`, so leaving the signed-in state no longer implicitly stops them the
                // way the old view-lifetime `onDisappear → model.stop()` did. Redundant with the
                // `entered` handler below when we were entered (the hard stop is idempotent), but
                // required on its own when the gate drops while sitting on the profile picker.
                home.stop()
            }
        }
        // Top Shelf snapshot mirrors the active profile's continue watching; only meaningful
        // once a profile is entered (data is profile-scoped).
        .onChange(of: entered) { _, isEntered in
            if isEntered {
                topShelf.start()
                if let url = pendingDeepLinkURL {
                    pendingDeepLinkURL = nil
                    if !ExternalPlaybackCallbacks.handle(url) { deepLink = DeepLink.parse(url) }
                }
            } else {
                // Sign-out wipes local progress first, so the watcher's final emission already
                // rewrote the snapshot empty before we stop observing.
                topShelf.stop()
                // H-1B-ii: `entered == false` is BOTH "switch profile" (the MainTabView
                // `onSwitchProfile` closure) and the sign-out path. Everything `home` observes is
                // profile-scoped, and it now outlives `HomeView`, so the profile exit must tear it
                // down explicitly — exactly what Home's view lifetime used to do implicitly. Hard
                // stop, not `release()`: it must drop regardless of who still holds it, and the
                // unmounting HomeView's own `release()` is absorbed by the model.
                home.stop()
                // Periodic activity polling is profile-scoped too, and "switch profile" keeps the
                // selected profile active in the repository — without this the loop started at
                // profile entry keeps pulling every 15 min while the picker is up. Idempotent
                // with the sign-out path's cancelAccountSync (Codex 2026-08-24).
                SyncManager.shared.stopPeriodicNuvioSyncPull()
            }
        }
        .onOpenURL { url in
            if auth.gate == .main, entered {
                // Infuse coming back from a hand-off (x-callback-url): recorded, never a deep link —
                // parsing it as one would close a deep-link cover the viewer returns to.
                if ExternalPlaybackCallbacks.handle(url) { return }
                deepLink = DeepLink.parse(url)
            } else {
                // Cold launch from the Top Shelf: apply once the profile gate is passed.
                pendingDeepLinkURL = url
            }
        }
        .fullScreenCover(item: $deepLink, onDismiss: {
            // "Back to Details" from a Top Shelf resume lands on the title's page.
            guard let preview = deepLinkDetailAfterResume else { return }
            deepLinkDetailAfterResume = nil
            deepLink = .title(preview: preview)
        }) { link in
            switch link {
            case .resume(let type, let videoId, let title, let parentMetaId, let season, let episode):
                StreamPickerView(
                    type: type,
                    videoId: videoId,
                    // CW-1: the Top Shelf item carries the progress record's title — the series name.
                    title: ProgressRecordTitles.pickerTitle(title: title, season: season, episode: episode,
                                                            episodeTitle: nil),
                    parentMetaId: parentMetaId,
                    season: season,
                    episode: episode,
                    seriesTitle: title,
                    onLeaveToDetails: {
                        deepLinkDetailAfterResume = MetaPreview(
                            id: parentMetaId,
                            type: type,
                            name: title,
                            poster: nil,
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
                        )
                    }
                )
            case .title(let preview):
                DeepLinkTitleView(preview: preview)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Foreground/background sync lifecycle (mirrors mobile's AppVisibility collector in
            // MainAppContent). SyncManager self-guards: no-op unless signed in with a real account.
            // Divergence from mobile: iOS maps willResignActive → Background; on tvOS we only stop
            // the periodic loop on a real .background, not the transient .inactive that fires
            // during app-switcher overlays — restarting the loop is cheap, churn is not.
            switch newPhase {
            case .active:
                guard auth.gate == .main, entered else { return }
                // No force: the 2-minute activity-pull freshness gate inside SyncManager decides.
                SyncManager.shared.requestForegroundPull(
                    profileId: ProfileRepository.shared.activeProfileId,
                    force: false
                )
                SyncManager.shared.startPeriodicNuvioSyncPull(
                    profileId: ProfileRepository.shared.activeProfileId
                )
                // Re-register this device/session on foreground (self-throttled to once per
                // 15 min inside DeviceSessionRegistration unless force is passed).
                Task {
                    _ = try? await DeviceSessionRegistration.shared.registerIfAuthenticated(force: false)
                }
            case .background:
                SyncManager.shared.stopPeriodicNuvioSyncPull()
            default:
                break
            }
        }
        #if DEBUG
        // `debug.mpvSmokeURL`: present the real player over the root for sim validation of the
        // libmpv path (see MPVSmokeTest.swift).
        .modifier(MPVSmokeModifier())
        #endif
    }
}

/// Selection values of the tab shell, as `Int` constants because `selectedTab` (an `Int`) is owned by
/// `ContentView` above the theme `.id()` boundary and `TabBarVisibility.setHomeTabSelected` keys
/// off `home`. Values are stable across the VIS-16 reshuffle; 3 (Add-ons) and 5 (Profile) are
/// retired and must not be reused for something else.
enum MainTab {
    static let home = 0
    static let search = 1
    static let library = 2
    static let settings = 4
}

/// The main app shell once a profile is selected.
///
/// VIS-16 / spec gap 8 (decision D1): a system `TabView` with `.sidebarAdaptable`, the Apple TV
/// app and Podcasts layout. tvOS draws the translucent sidebar, collapses it while content has
/// focus, reopens it on Menu from a tab root (and on a swipe past the leading edge), and exits to
/// the Home Screen on Menu from the sidebar. That replaces the FEAT-30 `SidebarOverlay`, the
/// tabs/sidebar toggle, the hidden-tab-bar focus blocker and `sidebarTopCompensation`.
///
/// Order follows the TV app: Search, Home, Library, then Settings. Add-ons moved into Settings and
/// the Profile tab is gone (VIS-13); Settings reaches "Who's watching?" through
/// `EnvironmentValues.switchProfile`. The tvOS 27 `tabViewSidebarHeader` profile chip is not used:
/// CI builds with the tvOS 26 SDK, where that symbol does not exist.
struct MainTabView: View {
    let activeProfile: NuvioProfile?
    /// H-1B-ii: Home's view model, owned by `ContentView` above the theme `.id()` boundary and
    /// merely PASSED THROUGH here. Deliberately a plain `let`, NOT `@ObservedObject`. Observing it
    /// would re-couple `MainTabView.body` to `HomeViewModel.objectWillChange`, so every Home
    /// publish (hero commit, row rebuild, continue-watching tick) would invalidate the shell and
    /// re-evaluate every `Tab` closure: precisely the T3/BUG-66 class documented on
    /// `tabBarVisibility` below. `HomeView` is the only view that should observe it, and it does.
    let home: HomeViewModel
    let onSwitchProfile: () -> Void
    /// Owned by ContentView (above the theme `.id()` rebuild boundary) so changing the theme in
    /// Settings doesn't dump the user back onto the Home tab.
    @Binding var selectedTab: Int
    /// Also owned by ContentView (above the theme `.id()` boundary), same reasoning as
    /// `selectedTab`: a theme change must not dump the user out of the Settings category they were
    /// standing in. Passed straight through to `SettingsView`.
    @Binding var settingsCategory: SettingsCategory
    /// See `ContentView.pendingThemeSwatchFocus`: threaded through for the same reason
    /// `settingsCategory` is, it must live above the theme rebuild boundary.
    @Binding var pendingThemeSwatchFocus: String?
    /// See `ContentView.pendingAppearanceRowFocus`.
    @Binding var pendingAppearanceRowFocus: String?
    /// FEAT-25: true while ContentView's app-root deep-link cover is presented, a fourth way Home
    /// gets covered that neither tab selection nor push depth can see (Codex beta.14 r8).
    var rootCoverActive: Bool = false

    /// Single shared instance for the whole tab shell, provided to every tab root (and anything
    /// they push, like `DetailView`) via `.environment(\.tabBarVisibility,)` below.
    ///
    /// T3 (beta.14 regression fix, load-bearing; do NOT revert to `@StateObject`): `@State` on a
    /// reference type stores the SAME instance for the same lifetime `@StateObject` would, but
    /// without subscribing this view to the object's `objectWillChange`. With `@StateObject`, ANY
    /// `@Published` mutation on it (including `homeSurfaceCovered`) invalidated `MainTabView` and
    /// re-evaluated every `Tab` closure, re-resolving `.toolbarVisibility` mid-transition (BUG-66).
    @State private var tabBarVisibility = TabBarVisibility()

    var body: some View {
        TabView(selection: $selectedTab) {
            // `role: .search` makes this the system search tab: the magnifying glass at the top
            // of the sidebar, and `.searchable` inside it gets the tvOS search keyboard
            // (dictation, the iPhone keyboard, the grid keyboard for game controllers).
            Tab("Search", systemImage: "magnifyingglass", value: MainTab.search, role: .search) {
                SearchView()
                    .tabBarImmersiveHide()
            }
            Tab("Home", systemImage: "house", value: MainTab.home) {
                HomeView(model: home)
                    .tabBarImmersiveHide()
            }
            Tab("Library", systemImage: "books.vertical", value: MainTab.library) {
                LibraryView()
                    .tabBarImmersiveHide()
            }
            // T4: Settings doesn't scroll meaningfully but still declares the same `.automatic`
            // preference through `tabBarImmersiveHide()` as every other root, so the resolved
            // `.toolbarVisibility` never changes on a plain tab switch (BUG-66).
            Tab("Settings", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView(
                    selectedCategory: $settingsCategory,
                    pendingThemeSwatchFocus: $pendingThemeSwatchFocus,
                    pendingAppearanceRowFocus: $pendingAppearanceRowFocus
                )
                    .tabBarImmersiveHide()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.tabBarVisibility, tabBarVisibility)
        // VIS-13: the Profile tab is gone; Settings shows the current profile and offers "Switch
        // Profile" through these two values (see `SwitchProfileButton`).
        .environment(\.switchProfile, SwitchProfileAction(perform: onSwitchProfile))
        .environment(\.activeProfile, activeProfile)
        // BUG-66 evidence probe (2026-09-10): arms `TabBarStateProbe`'s on-device tab-bar geometry
        // sampler once this view lands in a window. Hosted on the `TabView` (mounted exactly once
        // for the whole shell) and mounted in every build; zero-sized and a no-op when the probe's
        // toggle is off.
        .background(TabBarProbeArmer())
        // FEAT-25: keep the "is Home frontmost" signal current from OUTSIDE the kept-alive tab
        // subtrees. This closure runs on the always-visible shell, so the hero trailer's teardown
        // can't be deferred along with a hidden tab's rendering.
        .onAppear {
            tabBarVisibility.setHomeTabSelected(selectedTab == MainTab.home)
            tabBarVisibility.setRootCoverActive(rootCoverActive)
        }
        .onChange(of: rootCoverActive) { _, active in
            tabBarVisibility.setRootCoverActive(active)
        }
        .onChange(of: selectedTab) { _, tab in
            tabBarVisibility.setHomeTabSelected(tab == MainTab.home)
        }
    }
}

// MARK: - Switch Profile contract (Settings)

/// VIS-13: the action that returns to "Who's watching?" from inside the app. Provided by
/// `MainTabView`; `nil` anywhere outside the tab shell (a Top Shelf deep link's standalone stack),
/// where a Switch Profile control must not be offered.
struct SwitchProfileAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

extension EnvironmentValues {
    @Entry var switchProfile: SwitchProfileAction? = nil
    /// The profile the shell is running, for Settings' account header. `nil` outside the shell.
    @Entry var activeProfile: NuvioProfile? = nil
}

/// The Profile tab's replacement, ready to drop into a Settings list (Account & Services): the
/// current profile's avatar and name, and a Switch Profile button that opens "Who's watching?" on
/// that profile (F17). Renders nothing outside the tab shell.
struct SwitchProfileButton: View {
    @Environment(\.switchProfile) private var switchProfile
    @Environment(\.activeProfile) private var activeProfile

    var body: some View {
        if let switchProfile {
            Button {
                switchProfile()
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    if let profile = activeProfile {
                        ProfileAvatar(profile: profile, size: 56)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "person.crop.circle")
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "profile.switch.title", defaultValue: "Switch Profile",
                                    comment: "Settings button that returns to the Who's watching? profile picker"))
                        if let profile = activeProfile {
                            Text(profile.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
