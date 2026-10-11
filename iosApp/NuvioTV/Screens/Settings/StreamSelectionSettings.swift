import Combine
import SharedCore
import SwiftUI

// Settings > Playback rows for how a stream is chosen without the picker: the Up Next timeout, the
// add-ons and plugins it may pick from, the source group (binge group) it prefers and remembers,
// the Continue Watching link reuse window, and the external-player subtitle forwarding switch. All
// of them are the shared `PlayerSettingsRepository` settings (profile scoped, synced with the
// phone), built from the same kit as their neighbours (SettingsRowViews.swift).

/// The stream-selection settings, watched straight off `PlayerSettingsRepository`, plus the names
/// of the add-ons and plugins the allow lists can pick from.
///
/// Never stopped by the pane's `onDisappear`: the allow-list pages pushed from the pane read this
/// same model while the pane is off screen. The watchers end with the model.
@MainActor
final class StreamSelectionSettingsModel: ObservableObject {
    @Published private(set) var timeoutSeconds = 3
    @Published private(set) var selectedAddons: Set<String> = []
    @Published private(set) var selectedPlugins: Set<String> = []
    @Published private(set) var reuseLastLink = false
    @Published private(set) var reuseLastLinkHours = 24
    @Published private(set) var preferBingeGroup = true
    @Published private(set) var reuseBingeGroup = false
    @Published private(set) var bingeGroupFallback = true
    @Published private(set) var forwardSubtitles = false
    /// Installed, enabled add-ons that answer stream requests, by name.
    @Published private(set) var addonNames: [String] = []
    /// Enabled plugin scrapers, by name; empty while plugins are switched off.
    @Published private(set) var pluginNames: [String] = []

    private var settingsWatcher: FlowWatcher?
    private var addonWatcher: FlowWatcher?
    private var pluginWatcher: FlowWatcher?

    func start() {
        guard settingsWatcher == nil else { return }
        PlayerSettingsRepository.shared.ensureLoaded()
        settingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            let timeout = Int(state.streamAutoPlayTimeoutSeconds)
            if self.timeoutSeconds != timeout { self.timeoutSeconds = timeout }
            let addons = state.streamAutoPlaySelectedAddons
            if self.selectedAddons != addons { self.selectedAddons = addons }
            let plugins = state.streamAutoPlaySelectedPlugins
            if self.selectedPlugins != plugins { self.selectedPlugins = plugins }
            if self.reuseLastLink != state.streamReuseLastLinkEnabled { self.reuseLastLink = state.streamReuseLastLinkEnabled }
            let hours = Int(state.streamReuseLastLinkCacheHours)
            if self.reuseLastLinkHours != hours { self.reuseLastLinkHours = hours }
            if self.preferBingeGroup != state.streamAutoPlayPreferBingeGroup {
                self.preferBingeGroup = state.streamAutoPlayPreferBingeGroup
            }
            if self.reuseBingeGroup != state.streamAutoPlayReuseBingeGroup {
                self.reuseBingeGroup = state.streamAutoPlayReuseBingeGroup
            }
            if self.bingeGroupFallback != state.streamAutoPlayNextEpisodeFallbackEnabled {
                self.bingeGroupFallback = state.streamAutoPlayNextEpisodeFallbackEnabled
            }
            if self.forwardSubtitles != state.externalPlayerForwardSubtitles {
                self.forwardSubtitles = state.externalPlayerForwardSubtitles
            }
        }
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            // The add-ons the stream fan-out asks: enabled, manifest loaded, offering `stream`.
            var seen = Set<String>()
            let names = state.addons
                .filter { $0.enabled }
                .compactMap { addon -> String? in
                    guard let manifest = addon.manifest,
                          manifest.resources.contains(where: { $0.name == "stream" }) else { return nil }
                    return manifest.name
                }
                .filter { seen.insert($0).inserted }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if self.addonNames != names { self.addonNames = names }
        }
        pluginWatcher = FlowWatcherKt.watch(PluginRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PluginsUiState else { return }
            var seen = Set<String>()
            let names = state.pluginsEnabled
                ? state.scrapers
                    .filter { $0.enabled }
                    .map { $0.name }
                    .filter { seen.insert($0).inserted }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                : []
            if self.pluginNames != names { self.pluginNames = names }
        }
        AddonRepository.shared.initialize()
        PluginRepository.shared.initialize()
    }

    deinit {
        settingsWatcher?.cancel()
        addonWatcher?.cancel()
        pluginWatcher?.cancel()
    }

    // MARK: - Setters (the shared repository publishes the change back through the watcher)

    func setTimeoutSeconds(_ seconds: Int) {
        PlayerSettingsRepository.shared.setStreamAutoPlayTimeoutSeconds(seconds: Int32(clamping: seconds))
    }

    func setSelectedAddons(_ names: Set<String>) {
        PlayerSettingsRepository.shared.setStreamAutoPlaySelectedAddons(addons: names)
    }

    func setSelectedPlugins(_ names: Set<String>) {
        PlayerSettingsRepository.shared.setStreamAutoPlaySelectedPlugins(plugins: names)
    }

    func setReuseLastLink(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setStreamReuseLastLinkEnabled(enabled: enabled)
    }

    func setReuseLastLinkHours(_ hours: Int) {
        PlayerSettingsRepository.shared.setStreamReuseLastLinkCacheHours(hours: Int32(clamping: hours))
    }

    func setPreferBingeGroup(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setStreamAutoPlayPreferBingeGroup(enabled: enabled)
    }

    func setReuseBingeGroup(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setStreamAutoPlayReuseBingeGroup(enabled: enabled)
    }

    func setBingeGroupFallback(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setStreamAutoPlayNextEpisodeFallbackEnabled(enabled: enabled)
    }

    func setForwardSubtitles(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setExternalPlayerForwardSubtitles(enabled: enabled)
    }
}

// MARK: - Option lists

/// Values and wording of the stream-selection pickers.
enum StreamSelectionOptions {
    /// Seconds Up Next waits for add-ons before it chooses: the shared list the phone offers. 0 is
    /// "Instant" (choose as soon as a suitable stream arrives); `Int32.max` is "Unlimited" (the
    /// shared `Int.MAX_VALUE`: wait for the add-ons, with a hard stop).
    static let timeoutValues: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25, 30, unlimitedTimeout]
    static let unlimitedTimeout = Int(Int32.max)

    /// The offered values, plus the current one when it is off the list.
    static func timeoutChoices(including current: Int) -> [Int] {
        timeoutValues.contains(current) ? timeoutValues : (timeoutValues + [current]).sorted()
    }

    static func timeoutLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0:
            return String(localized: "settings.timeout.instant", defaultValue: "Instant",
                          comment: "Stream selection timeout option: choose as soon as a suitable stream arrives.")
        case unlimitedTimeout:
            return String(localized: "settings.timeout.unlimited", defaultValue: "Unlimited",
                          comment: "Stream selection timeout option: wait for every add-on.")
        default:
            return String(localized: "\(seconds) s")
        }
    }

    /// How long a replayed link stays good, in hours (the phone's list).
    static let reuseHourValues: [Int] = [1, 2, 3, 6, 12, 24, 48, 72, 168]

    static func reuseHourChoices(including current: Int) -> [Int] {
        reuseHourValues.contains(current) ? reuseHourValues : (reuseHourValues + [current]).sorted()
    }

    static func reuseHoursLabel(_ hours: Int) -> String {
        if hours >= 24, hours % 24 == 0 {
            let days = hours / 24
            return days == 1
                ? String(localized: "settings.reuse.day", defaultValue: "1 day", comment: "Link reuse window: one day.")
                : String(localized: "settings.reuse.days", defaultValue: "\(days) days",
                         comment: "Link reuse window: a whole number of days. %lld is the number.")
        }
        return hours == 1
            ? String(localized: "settings.reuse.hour", defaultValue: "1 hour", comment: "Link reuse window: one hour.")
            : String(localized: "settings.reuse.hours", defaultValue: "\(hours) hours",
                     comment: "Link reuse window: a number of hours. %lld is the number.")
    }
}

// MARK: - Allow lists

/// Which list a page edits.
enum AllowedSourceKind {
    case addons, plugins

    var title: String {
        switch self {
        case .addons:
            return String(localized: "settings.allowed.addons", defaultValue: "Allowed Add-ons",
                          comment: "Playback settings row: the add-ons Up Next may pick a stream from.")
        case .plugins:
            return String(localized: "settings.allowed.plugins", defaultValue: "Allowed Plugins",
                          comment: "Playback settings row: the plugins Up Next may pick a stream from.")
        }
    }

    var allLabel: String {
        switch self {
        case .addons:
            return String(localized: "settings.allowed.allAddons", defaultValue: "All Add-ons",
                          comment: "Allowed Add-ons value: every installed add-on is allowed.")
        case .plugins:
            return String(localized: "settings.allowed.allPlugins", defaultValue: "All Plugins",
                          comment: "Allowed Plugins value: every enabled plugin is allowed.")
        }
    }

    var footer: String {
        switch self {
        case .addons:
            return String(localized: "settings.allowed.addons.footer",
                          defaultValue: "Up Next only picks a stream from the add-ons that are on. At least one stays on.",
                          comment: "Footer of the Allowed Add-ons page.")
        case .plugins:
            return String(localized: "settings.allowed.plugins.footer",
                          defaultValue: "Up Next only picks a stream from the plugins that are on. At least one stays on.",
                          comment: "Footer of the Allowed Plugins page.")
        }
    }
}

/// The names behind an allow list and the rule that turns toggles into the stored set. An empty
/// stored set means "all" in the shared settings, so the page shows every name on in that case; a
/// stored name that is no longer installed counts for nothing.
struct AllowedSourceSelection: Equatable {
    let available: [String]
    let stored: Set<String>

    /// The names that are on, in list order.
    var allowed: Set<String> {
        let kept = stored.intersection(available)
        return kept.isEmpty ? Set(available) : kept
    }

    var allowsEverything: Bool { allowed.count == available.count }

    func isAllowed(_ name: String) -> Bool { allowed.contains(name) }

    /// The set to store after `name` was switched, or nil when nothing changes (the last name that
    /// is on cannot be switched off). Everything on is stored as the empty set.
    func storing(_ name: String, allowed isOn: Bool) -> Set<String>? {
        var next = allowed
        if isOn { next.insert(name) } else { next.remove(name) }
        guard !next.isEmpty else { return nil }
        return next.count == available.count ? [] : next
    }

    /// The row's trailing value.
    func summary(allLabel: String) -> String {
        allowsEverything ? allLabel : String(localized: "\(allowed.count) selected")
    }
}

/// "Allowed Add-ons" / "Allowed Plugins": a pushed page (`NavigationLink`, the tvOS Settings way to a
/// multi-select) whose row shows the current selection as its trailing value.
struct AllowedSourcesLinkRow: View {
    let kind: AllowedSourceKind
    @ObservedObject var model: StreamSelectionSettingsModel

    var body: some View {
        NavigationLink {
            AllowedSourcesPage(kind: kind, model: model)
        } label: {
            LabeledContent {
                Text(selection.summary(allLabel: kind.allLabel))
                    .font(SettingsRowFont.title)
                    .settingsAccentTint()
            } label: {
                SettingsRowLabel(title: kind.title)
            }
        }
    }

    private var selection: AllowedSourceSelection {
        AllowedSourceSelection(
            available: kind == .addons ? model.addonNames : model.pluginNames,
            stored: kind == .addons ? model.selectedAddons : model.selectedPlugins)
    }
}

/// The page behind the row: one stock toggle per add-on or plugin. Menu pops back to Playback.
struct AllowedSourcesPage: View {
    let kind: AllowedSourceKind
    @ObservedObject var model: StreamSelectionSettingsModel

    var body: some View {
        List {
            SettingsSection(title: nil, footer: kind.footer) {
                ForEach(selection.available, id: \.self) { name in
                    SettingsToggleRow(
                        title: name,
                        isOn: Binding(
                            get: { selection.isAllowed(name) },
                            set: { isOn in
                                guard let next = selection.storing(name, allowed: isOn) else { return }
                                if kind == .addons {
                                    model.setSelectedAddons(next)
                                } else {
                                    model.setSelectedPlugins(next)
                                }
                            }
                        )
                    )
                }
            }
        }
        .navigationTitle(kind.title)
    }

    private var selection: AllowedSourceSelection {
        AllowedSourceSelection(
            available: kind == .addons ? model.addonNames : model.pluginNames,
            stored: kind == .addons ? model.selectedAddons : model.selectedPlugins)
    }
}

// MARK: - Sections

/// The rows Up Next adds below the stream-selection mode: how long it waits for add-ons, which
/// add-ons and plugins it may use, and the source group it prefers.
struct NextEpisodeSourceRows: View {
    @ObservedObject var model: StreamSelectionSettingsModel
    /// "MANUAL", "FIRST_STREAM" or "REGEX_MATCH" (the shared mode names).
    let mode: String
    /// "ALL_SOURCES", "INSTALLED_ADDONS_ONLY" or "ENABLED_PLUGINS_ONLY".
    let source: String

    var body: some View {
        SettingsPickerRow(
            title: String(localized: "settings.timeout.title", defaultValue: "Selection Timeout",
                          comment: "Playback settings picker: how long Up Next waits for add-ons before choosing a stream."),
            subtitle: String(localized: "settings.timeout.subtitle",
                             defaultValue: "How long Up Next waits for add-ons before it chooses a stream. Instant chooses as soon as a suitable one arrives.",
                             comment: "Explanation under the Selection Timeout picker."),
            selection: Binding(get: { model.timeoutSeconds }, set: { model.setTimeoutSeconds($0) }),
            options: StreamSelectionOptions.timeoutChoices(including: model.timeoutSeconds),
            label: { StreamSelectionOptions.timeoutLabel($0) }
        )
        // The allow lists only narrow an automatic mode; the default mode picks from every source.
        if mode != "MANUAL" {
            if source != "ENABLED_PLUGINS_ONLY", !model.addonNames.isEmpty {
                AllowedSourcesLinkRow(kind: .addons, model: model)
            }
            if source != "INSTALLED_ADDONS_ONLY", !model.pluginNames.isEmpty {
                AllowedSourcesLinkRow(kind: .plugins, model: model)
            }
        }
        SettingsToggleRow(
            title: String(localized: "settings.binge.prefer", defaultValue: "Prefer the Same Source Group",
                          comment: "Playback settings toggle: Up Next looks for the same release group as the episode just watched."),
            subtitle: String(localized: "settings.binge.prefer.subtitle",
                             defaultValue: "Up Next first looks for the group of streams the episode you watched came from (same add-on, same quality), before the rules above.",
                             comment: "Explanation under the Prefer the Same Source Group toggle."),
            isOn: Binding(get: { model.preferBingeGroup }, set: { model.setPreferBingeGroup($0) })
        )
        if model.preferBingeGroup {
            SettingsToggleRow(
                title: String(localized: "settings.binge.fallback", defaultValue: "Fall Back to Any Source",
                              comment: "Playback settings toggle: when the same source group has no stream, pick another one."),
                subtitle: String(localized: "settings.binge.fallback.subtitle",
                                 defaultValue: "When that group has nothing for the next episode, pick another stream. Off: Up Next stops and offers the source list.",
                                 comment: "Explanation under the Fall Back to Any Source toggle."),
                isOn: Binding(get: { model.bingeGroupFallback }, set: { model.setBingeGroupFallback($0) })
            )
            SettingsToggleRow(
                title: String(localized: "settings.binge.remember", defaultValue: "Remember the Source Group",
                              comment: "Playback settings toggle: keep each series' source group between viewings."),
                subtitle: String(localized: "settings.binge.remember.subtitle",
                                 defaultValue: "Keep each series' source group between viewings, so Up Next still follows it after you resume from Continue Watching.",
                                 comment: "Explanation under the Remember the Source Group toggle."),
                isOn: Binding(get: { model.reuseBingeGroup }, set: { model.setReuseBingeGroup($0) })
            )
        }
    }
}

/// "Reuse Last Link": Continue Watching replays the source last used instead of opening the source
/// list, for as long as the window lasts.
struct LastLinkSettingsSection: View {
    @ObservedObject var model: StreamSelectionSettingsModel

    var body: some View {
        SettingsSection(
            String(localized: "settings.lastLink.section", defaultValue: "Last Source",
                   comment: "Playback settings section: replaying the last used source."),
            footer: String(localized: "settings.lastLink.footer",
                           defaultValue: "Links from debrid services expire sooner and are only replayed within 15 minutes.",
                           comment: "Footer of the Last Source section.")
        ) {
            SettingsToggleRow(
                title: String(localized: "settings.lastLink.reuse", defaultValue: "Reuse Last Link",
                              comment: "Playback settings toggle: Continue Watching replays the last source."),
                subtitle: String(localized: "settings.lastLink.reuse.subtitle",
                                 defaultValue: "Continue Watching plays the source you last used for a title instead of asking again, while its link is still good.",
                                 comment: "Explanation under the Reuse Last Link toggle."),
                isOn: Binding(get: { model.reuseLastLink }, set: { model.setReuseLastLink($0) })
            )
            if model.reuseLastLink {
                SettingsPickerRow(
                    title: String(localized: "settings.lastLink.duration", defaultValue: "Keep the Link For",
                                  comment: "Playback settings picker: how long the last link stays reusable."),
                    selection: Binding(get: { model.reuseLastLinkHours }, set: { model.setReuseLastLinkHours($0) }),
                    options: StreamSelectionOptions.reuseHourChoices(including: model.reuseLastLinkHours),
                    label: { StreamSelectionOptions.reuseHoursLabel($0) }
                )
            }
        }
    }
}
