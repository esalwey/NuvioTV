import Combine
import SwiftUI
import SharedCore
import UIKit

/// Watches the shared `ThemeSettingsRepository.selectedTheme` (persisted by the tvOS
/// `ThemeSettingsStore` adapter, profile-scoped, default CRIMSON) and applies it to the static
/// palette. ContentView puts `.id(themeName)` on the root so a theme change rebuilds the tree,
/// re-reading `Theme.Palette.accent`/`accentFocus` everywhere.
@MainActor
final class AppThemeModel: ObservableObject {
    @Published private(set) var themeName: String

    private var watcher: FlowWatcher?
    /// STAB-10: a theme that arrived while a full-screen cover was up (the player, a Top Shelf
    /// deep link, a file picker). Applying it then would re-identify the whole tree through
    /// `ContentView`'s `.id(themeName)` and tear the cover down mid-play, so it waits here and
    /// lands once the cover has closed.
    private var pendingThemeName: String?
    private var deferredApply: Task<Void, Never>?

    /// H-1B follow-up (beta.15, probe-verified): seed from the repository's CURRENT value
    /// synchronously instead of hard-coding "CRIMSON". With the hard-coded seed, every profile
    /// whose stored theme differed got a GUARANTEED whole-tree remount ~3s after cold launch when
    /// the first repository emission landed (`theme CRIMSON→OCEAN` in the probe capture) — tearing
    /// Home down and restarting its pipeline on every single launch. `ensureLoaded()` is a cheap
    /// disk read the `start()` path performed moments later anyway.
    init() {
        ThemeSettingsRepository.shared.ensureLoaded()
        let name = ThemeSettingsRepository.shared.currentThemeName()
        themeName = name
        Theme.Palette.applyTheme(named: name)
    }

    func start() {
        guard watcher == nil else { return }
        ThemeSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(ThemeSettingsRepository.shared.selectedTheme) { [weak self] emitted in
            guard let self, let theme = emitted as? AppTheme else { return }
            // H-1A (beta.15): guarded assignment, same pattern as `HomeHeroSettingsObserver`'s
            // `heroEnabled` watcher (HomeView.swift, `start()` ~L1401) — a profile-scoped cloud
            // sync pull can republish this SAME theme minutes after cold launch even though
            // nothing visibly changed, and `@Published` fires `objectWillChange` on every
            // assignment regardless of value equality. `ContentView` pins `.id(appTheme.themeName)`
            // on its root, so an unconditional write here remounts the whole tree — and on Home
            // that remount spins up a SECOND `HomeHeroFocusModel`/`HeroCrossfadeImage` instance,
            // which is the "hero painted twice" report's actual root cause. Only assign — and only
            // remount — when the incoming name genuinely differs.
            //
            // STAB-10: the palette is applied together with the remount (see `apply`), never
            // ahead of it, so a deferred theme cannot half-repaint the screen under a cover.
            guard self.themeName != theme.name else {
                // A change and its revert both landed while a cover was up: nothing to apply.
                self.pendingThemeName = nil
                return
            }
            // STAB-10: never remount under a presented cover; apply once it closes.
            if Self.isCoverPresented() {
                self.pendingThemeName = theme.name
                self.scheduleDeferredApply()
                return
            }
            // Permanent recurrence tripwire: any future regression that reintroduces an
            // unconditional theme republish shows up here as a `theme A→B` line minutes into a
            // probe capture, well after the cold-launch head — exactly the signal H-1A's
            // head-preserving ring buffer (`HomeHeroProbe`) was built to keep from being evicted.
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "theme %@\u{2192}%@ sinceLaunch=%dms", self.themeName, theme.name, HomeHeroProbe.sinceLaunchMs))
            }
            self.apply(theme.name)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        deferredApply?.cancel()
        deferredApply = nil
        pendingThemeName = nil
    }

    /// Synchronous re-seed at PROFILE ENTRY (probe-verified fix): theme keys are profile-scoped,
    /// so `init`'s seed reads the boot-time (pre-profile) key. `selectProfile`'s Kotlin fan-out
    /// reloads the repository for the chosen profile synchronously, but the Swift watcher
    /// delivery is async — without this, `MainTabView` mounted under the OLD name and the
    /// watcher's delivery ~70ms later re-identified the whole tree (probe: `theme CRIMSON→OCEAN`
    /// at 3.1s, a full Home pipeline teardown+restart on EVERY cold launch of a non-default-theme
    /// profile). ContentView calls this in `onSelected` BEFORE flipping `entered`, while only
    /// ProfileSelectionView is mounted — the `.id` change is then nearly free. Logged as
    /// `themeSeed` (not `theme …`) so test31's boot-window remount tripwire doesn't fire on the
    /// legitimate pre-mount seed.
    func reseedNow() {
        // The profile's own theme wins over anything a previous profile left pending.
        deferredApply?.cancel()
        deferredApply = nil
        pendingThemeName = nil
        let name = ThemeSettingsRepository.shared.currentThemeName()
        guard themeName != name else { return }
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "themeSeed %@\u{2192}%@ sinceLaunch=%dms", themeName, name, HomeHeroProbe.sinceLaunchMs))
        }
        apply(name)
    }

    private func apply(_ name: String) {
        pendingThemeName = nil
        Theme.Palette.applyTheme(named: name)
        themeName = name
    }

    /// Checks once a second while a theme is pending. A poll rather than a dismissal hook because
    /// covers are presented from many screens (Detail, the source picker, Library, the deep-link
    /// root): this needs no cooperation from any of them and costs nothing when idle.
    private func scheduleDeferredApply() {
        guard deferredApply == nil else { return }
        deferredApply = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let pending = self.pendingThemeName else {
                    self.deferredApply = nil
                    return
                }
                if Self.isCoverPresented() { continue }
                self.deferredApply = nil
                if pending != self.themeName {
                    if HomeHeroProbe.enabled {
                        HomeHeroProbe.log(String(format: "themeDeferred %@\u{2192}%@ sinceLaunch=%dms", self.themeName, pending, HomeHeroProbe.sinceLaunchMs))
                    }
                    self.apply(pending)
                } else {
                    self.pendingThemeName = nil
                }
                return
            }
        }
    }

    /// True while the key window's root controller presents anything: a SwiftUI
    /// `.fullScreenCover` or `.sheet` is a UIKit presentation on tvOS, and so is an alert.
    private static func isCoverPresented() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                if window.rootViewController?.presentedViewController != nil { return true }
            }
        }
        return false
    }
}
