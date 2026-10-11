import Combine
import SwiftUI
import SharedCore

// MARK: - Model

/// Backs the "Debrid Streams" settings pages (filters, sorting, limits, rules, link preparation and
/// result formatting). Everything lives in the shared `DebridSettingsRepository` (per-profile,
/// synced in the "tv" settings blob); the stream list applies it through `DebridStreamPresentation`,
/// so a change here is visible the next time a title's streams load.
///
/// Rule lists and one-tap filters are edited through `DebridStreamSettingsEditor`, a Kotlin facade
/// that only deals in strings, ints and lists — this file never builds a `DebridStreamPreferences`
/// or names a Kotlin enum case.
///
/// Each pushed page owns its own instance (own watcher), so a page stays live even while the
/// Settings root underneath it has stopped its watchers.
@MainActor
final class DebridStreamsSettingsModel: ObservableObject {
    @Published private(set) var settings: DebridSettings?

    private var watcher: FlowWatcher?
    private let editor = DebridStreamSettingsEditor.shared

    init() {
        // The watcher delivers its first value a tick after the page appears; start from the
        // stored settings so switches and pickers never flash their "off" state.
        settings = DebridSettingsRepository.shared.snapshot()
    }

    func start() {
        guard watcher == nil else { return }
        DebridSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(DebridSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? DebridSettings else { return }
            self.settings = value
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }

    // MARK: Link preparation

    /// 0 = off, otherwise how many of the top results get a direct link before the user picks.
    var prepareLimit: Int { Int(settings?.instantPlaybackPreparationLimit ?? 0) }

    func setPrepareLimit(_ value: Int) {
        DebridSettingsRepository.shared.setInstantPlaybackPreparationLimit(value: Int32(value))
    }

    // MARK: Filters

    var minimumQuality: String {
        guard let preferences = settings?.streamPreferences else { return "ANY" }
        return editor.minimumQualityId(preferences: preferences)
    }

    var dolbyVisionFilter: String {
        guard let preferences = settings?.streamPreferences else { return "ANY" }
        return editor.dolbyVisionFilterId(preferences: preferences)
    }

    var hdrFilter: String {
        guard let preferences = settings?.streamPreferences else { return "ANY" }
        return editor.hdrFilterId(preferences: preferences)
    }

    var codecFilter: String {
        guard let preferences = settings?.streamPreferences else { return "ANY" }
        return editor.codecFilterId(preferences: preferences)
    }

    func setMinimumQuality(_ id: String) { editor.setMinimumQuality(id: id) }
    func setDolbyVisionFilter(_ id: String) { editor.setDolbyVisionFilter(id: id) }
    func setHdrFilter(_ id: String) { editor.setHdrFilter(id: id) }
    func setCodecFilter(_ id: String) { editor.setCodecFilter(id: id) }

    // MARK: Sorting and limits

    var sortProfile: String {
        guard let preferences = settings?.streamPreferences else { return "ORIGINAL" }
        return editor.sortProfileId(preferences: preferences)
    }

    var sortProfileIds: [String] { editor.sortProfileIds() }

    var maxResults: Int { Int(settings?.streamPreferences.maxResults ?? 0) }
    var maxPerResolution: Int { Int(settings?.streamPreferences.maxPerResolution ?? 0) }
    var maxPerQuality: Int { Int(settings?.streamPreferences.maxPerQuality ?? 0) }

    /// "min-max" in GB, 0 meaning no bound — the picker's selection value.
    var sizeRangeKey: String {
        let minGb = Int(settings?.streamPreferences.sizeMinGb ?? 0)
        let maxGb = Int(settings?.streamPreferences.sizeMaxGb ?? 0)
        return Self.sizeKey(minGb, maxGb)
    }

    static func sizeKey(_ minGb: Int, _ maxGb: Int) -> String { "\(minGb)-\(maxGb)" }

    static func sizeBounds(_ key: String) -> (min: Int, max: Int) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    func setSortProfile(_ id: String) { editor.setSortProfile(profileId: id) }
    func setMaxResults(_ value: Int) { editor.setMaxResults(value: Int32(value)) }
    func setMaxPerResolution(_ value: Int) { editor.setMaxPerResolution(value: Int32(value)) }
    func setMaxPerQuality(_ value: Int) { editor.setMaxPerQuality(value: Int32(value)) }

    func setSizeRange(key: String) {
        let bounds = Self.sizeBounds(key)
        editor.setSizeRange(minGb: Int32(bounds.min), maxGb: Int32(bounds.max))
    }

    // MARK: Rule lists

    var ruleCategoryIds: [String] { editor.ruleCategoryIds() }

    func options(_ categoryId: String) -> [DebridChoice] { editor.ruleOptions(categoryId: categoryId) }

    /// Ids currently stored for one list ("preferred", "required" or "excluded").
    func selection(_ categoryId: String, mode: String) -> [String] {
        guard let preferences = settings?.streamPreferences else { return [] }
        return editor.ruleSelection(preferences: preferences, categoryId: categoryId, modeId: mode)
    }

    func setSelection(_ categoryId: String, mode: String, ids: [String]) {
        editor.setRuleSelection(categoryId: categoryId, modeId: mode, ids: ids)
    }

    func releaseGroups(mode: String) -> [String] {
        guard let preferences = settings?.streamPreferences else { return [] }
        return editor.releaseGroups(preferences: preferences, modeId: mode)
    }

    func setReleaseGroups(mode: String, groups: [String]) {
        editor.setReleaseGroups(modeId: mode, groups: groups)
    }

    // MARK: Formatting

    var nameTemplate: String { settings?.streamNameTemplate ?? editor.defaultNameTemplate() }
    var descriptionTemplate: String { settings?.streamDescriptionTemplate ?? editor.defaultDescriptionTemplate() }

    func setNameTemplate(_ value: String) {
        DebridSettingsRepository.shared.setStreamNameTemplate(value: value)
    }

    func setDescriptionTemplate(_ value: String) {
        DebridSettingsRepository.shared.setStreamDescriptionTemplate(value: value)
    }

    func resetTemplates() {
        DebridSettingsRepository.shared.resetStreamTemplates()
    }

    /// "original" (blank, results keep the add-on's own text), "default" or "custom".
    func templateKind(name: Bool) -> String {
        name
            ? editor.templateKind(value: nameTemplate, defaultValue: editor.defaultNameTemplate())
            : editor.templateKind(value: descriptionTemplate, defaultValue: editor.defaultDescriptionTemplate())
    }

    func templateSummary(name: Bool) -> String {
        switch templateKind(name: name) {
        case "original":
            return String(localized: "Original format")
        case "default":
            return String(localized: "Default format")
        default:
            let value = name ? nameTemplate : descriptionTemplate
            let firstLine = value
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            if firstLine.isEmpty { return String(localized: "Default format") }
            return firstLine.count <= 28 ? firstLine : String(firstLine.prefix(28)) + "\u{2026}"
        }
    }
}

// MARK: - Labels

/// Display strings for the ids the Kotlin editor hands back. Ids are Kotlin enum names; the
/// strings live here so they localise with the rest of the app.
private enum DebridStreamLabels {
    static func resultsCount(_ value: Int) -> String {
        value <= 0 ? String(localized: "All results") : String(localized: "\(value) results")
    }

    static func limitEach(_ value: Int) -> String {
        value <= 0 ? String(localized: "No limit") : String(localized: "\(value) each")
    }

    static func linkCount(_ value: Int) -> String {
        value == 1 ? String(localized: "1 link") : String(localized: "\(value) links")
    }

    static func sortProfile(_ id: String) -> String {
        switch id {
        case "ORIGINAL": return String(localized: "Original order")
        case "BEST_QUALITY": return String(localized: "Best quality first")
        case "LARGEST": return String(localized: "Largest first")
        case "SMALLEST": return String(localized: "Smallest first")
        case "AUDIO": return String(localized: "Best audio first")
        case "LANGUAGE": return String(localized: "Language first")
        default: return id
        }
    }

    static func minimumQuality(_ id: String) -> String {
        switch id {
        case "ANY": return String(localized: "Any")
        case "P720": return String(localized: "720p or higher")
        case "P1080": return String(localized: "1080p or higher")
        case "P2160": return String(localized: "4K only")
        default: return String(localized: "Custom")
        }
    }

    static func featureFilter(_ id: String) -> String {
        switch id {
        case "EXCLUDE": return String(localized: "Hide")
        case "ONLY": return String(localized: "Only")
        default: return String(localized: "Any")
        }
    }

    static func codec(_ id: String) -> String {
        switch id {
        case "ANY": return String(localized: "Any")
        case "H264": return String(localized: "H.264 (AVC)")
        case "HEVC": return String(localized: "HEVC (H.265)")
        case "AV1": return String(localized: "AV1")
        default: return String(localized: "Custom")
        }
    }

    static func sizeRange(_ key: String) -> String {
        let bounds = DebridStreamsSettingsModel.sizeBounds(key)
        switch (bounds.min, bounds.max) {
        case (let low, let high) where low <= 0 && high <= 0:
            return String(localized: "Any size")
        case (let low, let high) where low <= 0:
            return String(localized: "Up to \(high) GB")
        case (let low, let high) where high <= 0:
            return String(localized: "\(low) GB and up")
        case (let low, let high):
            return String(localized: "\(low)\u{2013}\(high) GB")
        }
    }

    static func categoryTitle(_ id: String) -> String {
        switch id {
        case "resolution": return String(localized: "Resolutions")
        case "quality": return String(localized: "Qualities")
        case "visual_tag": return String(localized: "Visual Tags")
        case "audio_tag": return String(localized: "Audio Tags")
        case "audio_channel": return String(localized: "Audio Channels")
        case "encode": return String(localized: "Encodes")
        case "language": return String(localized: "Languages")
        default: return id
        }
    }

    static func categoryIcon(_ id: String) -> String {
        switch id {
        case "resolution": return "tv"
        case "quality": return "opticaldisc"
        case "visual_tag": return "sparkles.tv"
        case "audio_tag": return "waveform"
        case "audio_channel": return "hifispeaker.2"
        case "encode": return "cpu"
        case "language": return "globe"
        default: return "line.3.horizontal.decrease"
        }
    }

    static func choice(_ choice: DebridChoice, category: String) -> String {
        if category == "language" { return language(choice.id) }
        if choice.id == "UNKNOWN" { return String(localized: "Unknown") }
        return choice.label
    }

    private static func language(_ id: String) -> String {
        switch id {
        case "UNKNOWN": return String(localized: "Unknown")
        case "MULTI": return String(localized: "Multi-language")
        case "LA": return String(localized: "Latino (Latin American Spanish)")
        default:
            let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            let name = locale.localizedString(forLanguageCode: id.lowercased()) ?? id
            return name.prefix(1).uppercased(with: locale) + name.dropFirst()
        }
    }

    /// A picker needs its selection among its options: a value synced from another device that is
    /// not one of the presets is appended so it still shows and stays put.
    static func withCurrent(_ options: [Int], _ current: Int) -> [Int] {
        options.contains(current) ? options : (options + [current]).sorted()
    }

    static func withCurrent(_ options: [String], _ current: String) -> [String] {
        options.contains(current) ? options : options + [current]
    }

    static let sizePresets: [String] = ["0-0", "0-5", "0-10", "5-20", "10-50", "20-100"]
}

// MARK: - Main page

/// Settings › Account & Services › Debrid › Debrid Streams. A pushed page of stock settings rows:
/// pickers for the one-tap filters, links to the multi-select rule pages, and two template rows.
struct DebridStreamsSettingsView: View {
    @StateObject private var model = DebridStreamsSettingsModel()
    @State private var confirmingReset = false

    var body: some View {
        List {
            linkPreparationSection
            filtersSection
            sortingSection
            rulesSection
            formattingSection
        }
        .navigationTitle(String(localized: "Debrid Streams"))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("Reset Formatting?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.resetTemplates() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the default name and description templates.")
        }
    }

    // MARK: Link preparation

    private var linkPreparationSection: some View {
        SettingsSection(
            title: String(localized: "Link Preparation"),
            footer: String(localized: "Use a lower count when possible. Connected services may rate-limit how many links can be resolved in a time period. Opening a movie or episode can count toward those limits even if you do not press Play, because the links are prepared ahead of time.")
        ) {
            SettingsToggleRow(
                title: String(localized: "Prepare Links"),
                subtitle: String(localized: "Resolve playable links before playback starts."),
                isOn: Binding(
                    get: { model.prepareLimit > 0 },
                    // 2 is the shared default (DEBRID_PREPARE_INSTANT_PLAYBACK_DEFAULT_LIMIT).
                    set: { model.setPrepareLimit($0 ? 2 : 0) }
                )
            )
            if model.prepareLimit > 0 {
                SettingsPickerRow(
                    title: String(localized: "Links to Prepare"),
                    selection: Binding(
                        get: { model.prepareLimit },
                        set: { model.setPrepareLimit($0) }
                    ),
                    options: [1, 2, 3, 4, 5],
                    label: DebridStreamLabels.linkCount
                )
            }
        }
    }

    // MARK: Filters

    private var filtersSection: some View {
        SettingsSection(title: String(localized: "Filters")) {
            SettingsPickerRow(
                title: String(localized: "Minimum Quality"),
                subtitle: String(localized: "Hide results below this resolution."),
                selection: Binding(
                    get: { model.minimumQuality },
                    set: { model.setMinimumQuality($0) }
                ),
                options: DebridStreamLabels.withCurrent(["ANY", "P720", "P1080", "P2160"], model.minimumQuality),
                label: DebridStreamLabels.minimumQuality
            )
            SettingsPickerRow(
                title: String(localized: "Dolby Vision"),
                subtitle: String(localized: "Show all results, hide Dolby Vision ones, or show only those."),
                selection: Binding(
                    get: { model.dolbyVisionFilter },
                    set: { model.setDolbyVisionFilter($0) }
                ),
                options: ["ANY", "EXCLUDE", "ONLY"],
                label: DebridStreamLabels.featureFilter
            )
            SettingsPickerRow(
                title: String(localized: "HDR"),
                subtitle: String(localized: "Show all results, hide HDR ones, or show only those."),
                selection: Binding(
                    get: { model.hdrFilter },
                    set: { model.setHdrFilter($0) }
                ),
                options: ["ANY", "EXCLUDE", "ONLY"],
                label: DebridStreamLabels.featureFilter
            )
            SettingsPickerRow(
                title: String(localized: "Video Codec"),
                subtitle: String(localized: "Only show results encoded with one codec."),
                selection: Binding(
                    get: { model.codecFilter },
                    set: { model.setCodecFilter($0) }
                ),
                options: DebridStreamLabels.withCurrent(["ANY", "H264", "HEVC", "AV1"], model.codecFilter),
                label: DebridStreamLabels.codec
            )
        }
    }

    // MARK: Sorting and limits

    private var sortingSection: some View {
        SettingsSection(title: String(localized: "Sorting and Limits")) {
            SettingsPickerRow(
                title: String(localized: "Sort Results"),
                subtitle: String(localized: "Choose how results are ordered."),
                selection: Binding(
                    get: { model.sortProfile },
                    set: { model.setSortProfile($0) }
                ),
                options: model.sortProfileIds,
                label: DebridStreamLabels.sortProfile
            )
            SettingsPickerRow(
                title: String(localized: "Maximum Results"),
                subtitle: String(localized: "Limit how many results appear."),
                selection: Binding(
                    get: { model.maxResults },
                    set: { model.setMaxResults($0) }
                ),
                options: DebridStreamLabels.withCurrent([0, 5, 10, 20, 50], model.maxResults),
                label: DebridStreamLabels.resultsCount
            )
            SettingsPickerRow(
                title: String(localized: "Per-Resolution Limit"),
                subtitle: String(localized: "Cap repeated 2160p, 1080p and 720p results after sorting."),
                selection: Binding(
                    get: { model.maxPerResolution },
                    set: { model.setMaxPerResolution($0) }
                ),
                options: DebridStreamLabels.withCurrent([0, 1, 2, 3, 5], model.maxPerResolution),
                label: DebridStreamLabels.limitEach
            )
            SettingsPickerRow(
                title: String(localized: "Per-Quality Limit"),
                subtitle: String(localized: "Cap repeated BluRay, WEB-DL and REMUX results after sorting."),
                selection: Binding(
                    get: { model.maxPerQuality },
                    set: { model.setMaxPerQuality($0) }
                ),
                options: DebridStreamLabels.withCurrent([0, 1, 2, 3, 5], model.maxPerQuality),
                label: DebridStreamLabels.limitEach
            )
            SettingsPickerRow(
                title: String(localized: "File Size"),
                subtitle: String(localized: "Filter results by file size."),
                selection: Binding(
                    get: { model.sizeRangeKey },
                    set: { model.setSizeRange(key: $0) }
                ),
                options: DebridStreamLabels.withCurrent(DebridStreamLabels.sizePresets, model.sizeRangeKey),
                label: DebridStreamLabels.sizeRange
            )
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        SettingsSection(
            title: String(localized: "Rules"),
            footer: String(localized: "Prefer, require or hide specific resolutions, qualities, tags, languages and release groups.")
        ) {
            ForEach(model.ruleCategoryIds, id: \.self) { categoryId in
                SettingsLinkRow(
                    title: DebridStreamLabels.categoryTitle(categoryId),
                    subtitle: ruleSummary(categoryId),
                    systemImage: DebridStreamLabels.categoryIcon(categoryId)
                ) {
                    DebridRuleCategoryView(categoryId: categoryId)
                }
            }
            SettingsLinkRow(
                title: String(localized: "Release Groups"),
                subtitle: groupsSummary,
                systemImage: "person.2"
            ) {
                DebridReleaseGroupsView()
            }
        }
    }

    private func ruleSummary(_ categoryId: String) -> String {
        summary(
            required: model.selection(categoryId, mode: "required").count,
            excluded: model.selection(categoryId, mode: "excluded").count
        )
    }

    private var groupsSummary: String {
        summary(
            required: model.releaseGroups(mode: "required").count,
            excluded: model.releaseGroups(mode: "excluded").count
        )
    }

    private func summary(required: Int, excluded: Int) -> String {
        switch (required, excluded) {
        case (0, 0): return String(localized: "No filters")
        case (let required, 0): return String(localized: "\(required) required")
        case (0, let excluded): return String(localized: "\(excluded) hidden")
        case (let required, let excluded): return String(localized: "\(required) required \u{00B7} \(excluded) hidden")
        }
    }

    // MARK: Formatting

    private var formattingSection: some View {
        SettingsSection(
            title: String(localized: "Formatting"),
            footer: String(localized: "Templates control how each debrid result is named and described. To type multi-line templates, use Remote Setup (Settings \u{203A} Advanced) from a phone or computer.")
        ) {
            SettingsLinkRow(
                title: String(localized: "Name Template"),
                subtitle: model.templateSummary(name: true),
                systemImage: "textformat"
            ) {
                DebridTemplateEditorView(isName: true)
            }
            SettingsLinkRow(
                title: String(localized: "Description Template"),
                subtitle: model.templateSummary(name: false),
                systemImage: "text.alignleft"
            ) {
                DebridTemplateEditorView(isName: false)
            }
            SettingsDestructiveRow(
                title: String(localized: "Reset Formatting"),
                subtitle: String(localized: "Restore default result formatting."),
                systemImage: "arrow.counterclockwise"
            ) {
                confirmingReset = true
            }
        }
    }
}

// MARK: - Rule lists

/// One rule category (resolutions, qualities, tags, ...) as three sections of switches: Preferred
/// (sorted first, in the default order), Required (only show these) and Excluded (hide these).
struct DebridRuleCategoryView: View {
    let categoryId: String
    @StateObject private var model = DebridStreamsSettingsModel()

    var body: some View {
        List {
            ruleSection(
                mode: "preferred",
                title: String(localized: "Preferred"),
                footer: categoryId == "language"
                    ? String(localized: "Selected languages sort first when results are sorted by language.")
                    : String(localized: "Selected values sort first, in the default order, when results are sorted by quality, audio or language. At least one stays on.")
            )
            ruleSection(
                mode: "required",
                title: String(localized: "Required"),
                footer: String(localized: "Only show results that match at least one selected value. Leave all off to allow everything.")
            )
            ruleSection(
                mode: "excluded",
                title: String(localized: "Excluded"),
                footer: String(localized: "Hide results that match any selected value.")
            )
        }
        .navigationTitle(DebridStreamLabels.categoryTitle(categoryId))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func ruleSection(mode: String, title: String, footer: String) -> some View {
        let selected = Set(model.selection(categoryId, mode: mode))
        return SettingsSection(title: title, footer: footer) {
            ForEach(model.options(categoryId), id: \.id) { choice in
                SettingsToggleRow(
                    title: DebridStreamLabels.choice(choice, category: categoryId),
                    isOn: Binding(
                        get: { selected.contains(choice.id) },
                        set: { isOn in
                            var next = selected
                            if isOn { next.insert(choice.id) } else { next.remove(choice.id) }
                            // A preferred list can't be empty (it would just restore the default
                            // order) except for languages, so the last switch simply stays on.
                            if mode == "preferred", next.isEmpty, categoryId != "language" { return }
                            model.setSelection(categoryId, mode: mode, ids: Array(next))
                        }
                    )
                )
            }
        }
    }
}

// MARK: - Release groups

/// Required / excluded release groups (YIFY, RARBG, ...). Free text, so each section has a field
/// (the system keyboard, or the iPhone keyboard handoff) and the existing entries as rows that
/// remove themselves when pressed.
struct DebridReleaseGroupsView: View {
    @StateObject private var model = DebridStreamsSettingsModel()
    @State private var requiredDraft = ""
    @State private var excludedDraft = ""

    var body: some View {
        List {
            groupSection(
                mode: "required",
                title: String(localized: "Required Release Groups"),
                footer: String(localized: "Only show results from these release groups."),
                draft: $requiredDraft
            )
            groupSection(
                mode: "excluded",
                title: String(localized: "Excluded Release Groups"),
                footer: String(localized: "Hide results from these release groups."),
                draft: $excludedDraft
            )
        }
        .navigationTitle(String(localized: "Release Groups"))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func groupSection(mode: String, title: String, footer: String, draft: Binding<String>) -> some View {
        let groups = model.releaseGroups(mode: mode)
        return SettingsSection(title: title, footer: footer) {
            TextField(String(localized: "Add a release group"), text: draft)
                .font(SettingsRowFont.title)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { add(draft: draft, mode: mode, existing: groups) }

            ForEach(groups, id: \.self) { group in
                SettingsActionRow(
                    title: group,
                    subtitle: String(localized: "Press to remove"),
                    systemImage: "minus.circle"
                ) {
                    model.setReleaseGroups(mode: mode, groups: groups.filter { $0 != group })
                }
            }
        }
    }

    private func add(draft: Binding<String>, mode: String, existing: [String]) {
        let entries = draft.wrappedValue
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return }
        model.setReleaseGroups(mode: mode, groups: existing + entries)
        draft.wrappedValue = ""
    }
}

// MARK: - Template editor

/// Edits the stream name or description template. A live preview renders the draft against sample
/// data with the shared engine, and the placeholder list comes from the same sample map, so the
/// cheat sheet can't drift from what the formatter accepts. The draft is saved when the page is
/// left (or on Return); Reset puts the shipped template back immediately.
struct DebridTemplateEditorView: View {
    let isName: Bool
    @StateObject private var model = DebridStreamsSettingsModel()
    @State private var draft = ""
    @State private var didLoad = false

    private let editor = DebridStreamSettingsEditor.shared

    /// Read straight from the repository: the model's watcher only delivers its first value a tick
    /// after `onAppear`, and the draft has to start from what is stored.
    private var stored: String {
        let settings = DebridSettingsRepository.shared.snapshot()
        return isName ? settings.streamNameTemplate : settings.streamDescriptionTemplate
    }
    private var defaultTemplate: String {
        isName ? editor.defaultNameTemplate() : editor.defaultDescriptionTemplate()
    }
    private var preview: String {
        isName ? editor.previewName(template: draft) : editor.previewDescription(template: draft)
    }

    var body: some View {
        List {
            SettingsSection(
                title: String(localized: "Template"),
                footer: isName
                    ? String(localized: "Controls how result names appear. Leave blank to use the original result name. Saved when you leave this screen.")
                    : String(localized: "Controls the metadata shown under each result. Leave blank to use the original result details. Saved when you leave this screen.")
            ) {
                TextField(
                    isName ? String(localized: "Name template") : String(localized: "Description template"),
                    text: $draft,
                    axis: .vertical
                )
                .font(SettingsRowFont.title)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { save() }

                SettingsDestructiveRow(
                    title: String(localized: "Reset to Default"),
                    subtitle: isName
                        ? String(localized: "Restore the default name format.")
                        : String(localized: "Restore the original result details."),
                    systemImage: "arrow.counterclockwise"
                ) {
                    draft = defaultTemplate
                    save()
                }
            }

            SettingsSection(title: String(localized: "Preview")) {
                Text(preview.isEmpty ? String(localized: "Original format") : preview)
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: String(localized: "Placeholders"),
                footer: String(localized: "Wrap a placeholder in braces, for example {stream.resolution}. Add a condition for fallbacks: {stream.resolution::exists[\"{stream.resolution} \"||\"\"]}.")
            ) {
                Text(editor.templateVariables().map { "{\($0)}" }.joined(separator: "  "))
                    .font(SettingsRowFont.sectionHeader.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(isName ? String(localized: "Name Template") : String(localized: "Description Template"))
        .onAppear {
            model.start()
            if !didLoad {
                draft = stored
                didLoad = true
            }
        }
        .onDisappear {
            save()
            model.stop()
        }
    }

    private func save() {
        guard didLoad, draft != stored else { return }
        if isName {
            model.setNameTemplate(draft)
        } else {
            model.setDescriptionTemplate(draft)
        }
    }
}
