import SwiftUI
import SharedCore

/// Full-screen TMDB Discover filter editor for one tmdb source of a collection folder (presented
/// from `FolderDetailView` via `.fullScreenCover(item:)`). Mirrors mobile's TMDB source picker
/// filter panel — incl. the `without*` exclusion fields — as 10-foot sections: quick chips (ids
/// from the shared `TmdbFilterPresets`, live TMDB genres when a key is set) plus free-text id
/// fields (tvOS full-screen keyboard). Every edit is forwarded to the shared
/// `TmdbSourceFilterEditor`; Save validates + persists + triggers a sync push.
struct TmdbFilterEditorView: View {
    @StateObject private var vm: TmdbFilterEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(target: FolderDetailViewModel.EditableSource) {
        _vm = StateObject(wrappedValue: TmdbFilterEditorViewModel(target: target))
    }

    private var presets: TmdbFilterPresets { TmdbFilterPresets.shared }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                    header

                    if vm.loadFailed {
                        loadFailedSection
                    } else {
                        sortSection
                        genresSection
                        keywordsSection
                        studiosSection
                        if vm.mediaTypeIsTv {
                            networksSection
                        }
                        watchProvidersSection
                        datesAndRatingsSection
                        languageAndCountrySection
                        footer
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: 1500, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        // Covers Menu-button dismissal too: drop the shared editor state so the next `begin()`
        // starts clean (idempotent after the explicit Save/Cancel paths).
        .onDisappear { vm.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("TMDB Filters")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            if !vm.sourceTitle.isEmpty {
                Text(vm.sourceTitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text("Enter TMDB IDs. Separate multiple IDs with commas for AND, or pipes for OR. Quick chips toggle common IDs.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            if vm.tmdbSourceTypeName == "COMPANY" || vm.tmdbSourceTypeName == "NETWORK" {
                Text("This source is pinned to its TMDB company or network; these filters narrow it further.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    /// `begin()` failed: the folder/source is gone or isn't a tmdb source. The Cancel button is
    /// the focus anchor (BUG-47 class — a cover with no focusable control strands focus).
    private var loadFailedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("This source can\u{2019}t be edited.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button("Cancel") {
                vm.cancel()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .focusSection()
    }

    // MARK: - Sort

    private struct SortOption: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    private var sortOptions: [SortOption] {
        var options: [SortOption] = [
            SortOption(value: TmdbCollectionSort.original.value, label: String(localized: "Original")),
            SortOption(value: TmdbCollectionSort.popularDesc.value, label: String(localized: "Popularity")),
            SortOption(value: TmdbCollectionSort.voteAverageDesc.value, label: String(localized: "Rating")),
            SortOption(value: TmdbCollectionSort.voteCountDesc.value, label: String(localized: "Vote count")),
        ]
        if vm.mediaTypeIsTv {
            options.append(SortOption(value: TmdbCollectionSort.firstAirDateDesc.value, label: String(localized: "First air date")))
        } else {
            options.append(SortOption(value: TmdbCollectionSort.releaseDateDesc.value, label: String(localized: "Release date")))
        }
        // A stored sort outside this media type's list (e.g. a movie source saved with
        // first_air_date.desc on mobile) stays selectable so the Picker has a matching tag.
        if !vm.sortBy.isEmpty, !options.contains(where: { $0.value == vm.sortBy }) {
            options.append(SortOption(value: vm.sortBy, label: vm.sortBy))
        }
        return options
    }

    private var selectedSortLabel: String {
        sortOptions.first { $0.value == vm.sortBy }?.label ?? vm.sortBy
    }

    private var sortSection: some View {
        settingsSection(String(localized: "Sort")) {
            // Dropdown rather than inline chips (same shape as the Playback pane's Default Player
            // row): a normal settings row showing the current choice; Select pops the native menu.
            Menu {
                Picker("Sort", selection: Binding(
                    get: { vm.sortBy },
                    set: { vm.setSortBy($0) }
                )) {
                    ForEach(sortOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(Theme.Font.body)
                        .rowAccentTint()
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Sort by")
                            .font(Theme.Font.body)
                            .rowTextColor()
                        Text("Order of the titles in this source.")
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                    Spacer()
                    Text(selectedSortLabel)
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.settingsRow)
        }
    }

    // MARK: - Genres

    /// Live TMDB genres (already localized by TMDB) when the key is set; else the shared
    /// English preset chips.
    private var genreChips: [(label: String, value: String)] {
        if !vm.availableGenres.isEmpty {
            return vm.availableGenres.map { (label: $0.name, value: String($0.id)) }
        }
        let mediaType: TmdbCollectionMediaType = vm.mediaTypeIsTv ? .tv : .movie
        return chips(presets.genreIds(mediaType: mediaType))
    }

    private func chips(_ list: [TmdbFilterChip]) -> [(label: String, value: String)] {
        list.map { (label: $0.label, value: $0.value) }
    }

    private var genresSection: some View {
        settingsSection(String(localized: "Genres")) {
            if vm.isLoadingGenres {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Loading genres\u{2026}")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            FilterChipRow(
                title: String(localized: "Include"),
                chips: genreChips,
                isOn: { vm.contains(.withGenres, $0) },
                onToggle: { vm.toggleId(.withGenres, $0) }
            )
            FilterChipRow(
                title: String(localized: "Exclude"),
                chips: genreChips,
                isOn: { vm.contains(.withoutGenres, $0) },
                onToggle: { vm.toggleId(.withoutGenres, $0) }
            )
            FilterTextRow(
                label: String(localized: "Genre IDs"),
                helper: String(localized: "Use TMDB genre numbers."),
                placeholder: vm.mediaTypeIsTv ? String(localized: "18,35") : String(localized: "28,12"),
                value: vm.value(.withGenres),
                invalid: vm.isInvalid(.withGenres),
                onCommit: { vm.setField(.withGenres, $0) }
            )
            FilterTextRow(
                label: String(localized: "Excluded genre IDs"),
                helper: String(localized: "Exclude titles matching these TMDB genre numbers."),
                placeholder: String(localized: "16 for Animation"),
                value: vm.value(.withoutGenres),
                invalid: vm.isInvalid(.withoutGenres),
                accessibilityIdentifier: "filters.withoutGenres",
                onCommit: { vm.setField(.withoutGenres, $0) }
            )
        }
    }

    // MARK: - Keywords

    private var keywordsSection: some View {
        settingsSection(String(localized: "Keywords")) {
            FilterChipRow(
                title: String(localized: "Include"),
                chips: chips(presets.keywords),
                isOn: { vm.contains(.withKeywords, $0) },
                onToggle: { vm.toggleId(.withKeywords, $0) }
            )
            FilterChipRow(
                title: String(localized: "Exclude"),
                chips: chips(presets.keywords),
                isOn: { vm.contains(.withoutKeywords, $0) },
                onToggle: { vm.toggleId(.withoutKeywords, $0) }
            )
            FilterTextRow(
                label: String(localized: "Keyword IDs"),
                helper: String(localized: "Use TMDB keyword numbers."),
                placeholder: String(localized: "9715 for superhero"),
                value: vm.value(.withKeywords),
                invalid: vm.isInvalid(.withKeywords),
                onCommit: { vm.setField(.withKeywords, $0) }
            )
            FilterTextRow(
                label: String(localized: "Excluded keyword IDs"),
                helper: String(localized: "Exclude titles tagged with these TMDB keyword numbers."),
                placeholder: String(localized: "9715"),
                value: vm.value(.withoutKeywords),
                invalid: vm.isInvalid(.withoutKeywords),
                onCommit: { vm.setField(.withoutKeywords, $0) }
            )
        }
    }

    // MARK: - Studios

    private var studiosSection: some View {
        settingsSection(String(localized: "Studios")) {
            FilterChipRow(
                title: String(localized: "Include"),
                chips: chips(presets.companies),
                isOn: { vm.contains(.withCompanies, $0) },
                onToggle: { vm.toggleId(.withCompanies, $0) }
            )
            FilterChipRow(
                title: String(localized: "Exclude"),
                chips: chips(presets.companies),
                isOn: { vm.contains(.withoutCompanies, $0) },
                onToggle: { vm.toggleId(.withoutCompanies, $0) }
            )
            FilterTextRow(
                label: String(localized: "Company IDs"),
                helper: String(localized: "Use TMDB company numbers."),
                placeholder: String(localized: "420 for Marvel Studios"),
                value: vm.value(.withCompanies),
                invalid: vm.isInvalid(.withCompanies),
                onCommit: { vm.setField(.withCompanies, $0) }
            )
            FilterTextRow(
                label: String(localized: "Excluded company IDs"),
                helper: String(localized: "Exclude titles from these TMDB company numbers."),
                placeholder: String(localized: "420"),
                value: vm.value(.withoutCompanies),
                invalid: vm.isInvalid(.withoutCompanies),
                onCommit: { vm.setField(.withoutCompanies, $0) }
            )
        }
    }

    // MARK: - Networks (TV only)

    private var networksSection: some View {
        settingsSection(String(localized: "Networks")) {
            FilterChipRow(
                title: String(localized: "Include"),
                chips: chips(presets.networks),
                isOn: { vm.contains(.withNetworks, $0) },
                onToggle: { vm.toggleId(.withNetworks, $0) }
            )
            FilterTextRow(
                label: String(localized: "Network IDs"),
                helper: String(localized: "Use TMDB network numbers."),
                placeholder: String(localized: "213 for Netflix"),
                value: vm.value(.withNetworks),
                invalid: vm.isInvalid(.withNetworks),
                onCommit: { vm.setField(.withNetworks, $0) }
            )
        }
    }

    // MARK: - Watch providers

    private var watchProvidersSection: some View {
        settingsSection(String(localized: "Watch Providers")) {
            FilterChipRow(
                title: String(localized: "Include"),
                chips: chips(presets.watchProviders),
                isOn: { vm.contains(.withWatchProviders, $0) },
                onToggle: { vm.toggleId(.withWatchProviders, $0) }
            )
            FilterChipRow(
                title: String(localized: "Exclude"),
                chips: chips(presets.watchProviders),
                isOn: { vm.contains(.withoutWatchProviders, $0) },
                onToggle: { vm.toggleId(.withoutWatchProviders, $0) }
            )
            FilterTextRow(
                label: String(localized: "Watch provider IDs"),
                helper: String(localized: "Use TMDB watch provider numbers; pipes mean any of them."),
                placeholder: String(localized: "8|337|350"),
                value: vm.value(.withWatchProviders),
                invalid: vm.isInvalid(.withWatchProviders),
                onCommit: { vm.setField(.withWatchProviders, $0) }
            )
            FilterTextRow(
                label: String(localized: "Excluded watch provider IDs"),
                helper: String(localized: "Exclude titles available from these TMDB watch provider numbers in the selected region."),
                placeholder: String(localized: "8|337|350"),
                value: vm.value(.withoutWatchProviders),
                invalid: vm.isInvalid(.withoutWatchProviders),
                onCommit: { vm.setField(.withoutWatchProviders, $0) }
            )
            FilterChipRow(
                title: String(localized: "Region"),
                chips: chips(presets.watchRegions),
                isOn: { vm.contains(.watchRegion, $0) },
                onToggle: { vm.toggleId(.watchRegion, $0) }
            )
            FilterTextRow(
                label: String(localized: "Watch region"),
                helper: String(localized: "Two-letter country code the provider filters apply to."),
                placeholder: String(localized: "US"),
                value: vm.value(.watchRegion),
                invalid: vm.isInvalid(.watchRegion),
                onCommit: { vm.setField(.watchRegion, $0) }
            )
        }
    }

    // MARK: - Dates & ratings

    private var datesAndRatingsSection: some View {
        settingsSection(String(localized: "Dates & Ratings")) {
            FilterTextRow(
                label: String(localized: "Release or air date from"),
                helper: String(localized: "Use YYYY-MM-DD, for example 2024-01-01."),
                placeholder: String(localized: "2024-01-01"),
                value: vm.value(.releaseDateGte),
                invalid: vm.isInvalid(.releaseDateGte),
                onCommit: { vm.setField(.releaseDateGte, $0) }
            )
            FilterTextRow(
                label: String(localized: "Release or air date to"),
                helper: String(localized: "Use YYYY-MM-DD, for example 2024-01-01."),
                placeholder: String(localized: "2024-12-31"),
                value: vm.value(.releaseDateLte),
                invalid: vm.isInvalid(.releaseDateLte),
                onCommit: { vm.setField(.releaseDateLte, $0) }
            )
            FilterTextRow(
                label: String(localized: "Minimum rating"),
                helper: String(localized: "0\u{2013}10"),
                placeholder: String(localized: "7"),
                value: vm.value(.voteAverageGte),
                invalid: vm.isInvalid(.voteAverageGte),
                onCommit: { vm.setField(.voteAverageGte, $0) }
            )
            FilterTextRow(
                label: String(localized: "Maximum rating"),
                helper: String(localized: "0\u{2013}10"),
                placeholder: String(localized: "10"),
                value: vm.value(.voteAverageLte),
                invalid: vm.isInvalid(.voteAverageLte),
                onCommit: { vm.setField(.voteAverageLte, $0) }
            )
            FilterTextRow(
                label: String(localized: "Minimum votes"),
                helper: String(localized: "Whole number, for example 100."),
                placeholder: String(localized: "100"),
                value: vm.value(.voteCountGte),
                invalid: vm.isInvalid(.voteCountGte),
                onCommit: { vm.setField(.voteCountGte, $0) }
            )
            FilterTextRow(
                label: String(localized: "Year"),
                helper: String(localized: "Four-digit year, for example 2024."),
                placeholder: String(localized: "2024"),
                value: vm.value(.year),
                invalid: vm.isInvalid(.year),
                onCommit: { vm.setField(.year, $0) }
            )
        }
    }

    // MARK: - Language & country

    private var languageAndCountrySection: some View {
        settingsSection(String(localized: "Language & Country")) {
            FilterChipRow(
                title: String(localized: "Original language"),
                chips: chips(presets.languages),
                isOn: { vm.contains(.withOriginalLanguage, $0) },
                onToggle: { vm.toggleId(.withOriginalLanguage, $0) }
            )
            FilterTextRow(
                label: String(localized: "Original language"),
                helper: String(localized: "Two-letter ISO 639-1 language code."),
                placeholder: String(localized: "en"),
                value: vm.value(.withOriginalLanguage),
                invalid: vm.isInvalid(.withOriginalLanguage),
                onCommit: { vm.setField(.withOriginalLanguage, $0) }
            )
            FilterChipRow(
                title: String(localized: "Origin country"),
                chips: chips(presets.countries),
                isOn: { vm.contains(.withOriginCountry, $0) },
                onToggle: { vm.toggleId(.withOriginCountry, $0) }
            )
            FilterTextRow(
                label: String(localized: "Origin country"),
                helper: String(localized: "Two-letter ISO 3166-1 country code."),
                placeholder: String(localized: "US"),
                value: vm.value(.withOriginCountry),
                invalid: vm.isInvalid(.withOriginCountry),
                onCommit: { vm.setField(.withOriginCountry, $0) }
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.lg) {
                Button {
                    // Save keeps the shared state alive (saved = true); drop it before dismissing
                    // so `onDismiss` → FolderDetailViewModel.reload() finds a clean editor.
                    if vm.save() {
                        vm.cancel()
                        dismiss()
                    }
                } label: {
                    Group {
                        if vm.isSaving {
                            Text("Saving\u{2026}")
                        } else {
                            Text("Save Filters")
                        }
                    }
                    .font(Theme.Font.meta.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
                }
                // Wave 2 (spec §6.6): settings content uses system buttons, no accent fill.
                .buttonStyle(.bordered)
                .accessibilityIdentifier("filters.save")

                Button("Cancel") {
                    vm.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Clear All Filters") {
                    vm.clearFilters()
                }
                .buttonStyle(.bordered)
            }

            if !vm.invalidFieldNames.isEmpty {
                Text("Check the highlighted fields.")
                    .font(Theme.Font.meta)
                    .foregroundStyle(.red)
            }
            if vm.saveFailed {
                Text("Couldn\u{2019}t save the filters. Try again.")
                    .font(Theme.Font.meta)
                    .foregroundStyle(.red)
            }
            if vm.isDirty, vm.invalidFieldNames.isEmpty, !vm.saveFailed {
                Text("Unsaved changes.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .focusSection()
    }
}

// MARK: - Reusable rows

/// Caption label + material text field + helper caption. The tvOS `TextField` opens the system's
/// full-screen keyboard and writes back on dismiss; the local `text` mirrors the editor's value
/// so a quick-chip toggle (which rewrites the field in the shared state) is reflected here too.
private struct FilterTextRow: View {
    let label: String
    let helper: String
    let placeholder: String
    let value: String
    let invalid: Bool
    /// Harness hook (e.g. "filters.withoutGenres") applied to the text field itself.
    let identifier: String?
    let onCommit: (String) -> Void

    @State private var text: String

    init(
        label: String,
        helper: String,
        placeholder: String,
        value: String,
        invalid: Bool,
        accessibilityIdentifier: String? = nil,
        onCommit: @escaping (String) -> Void
    ) {
        self.label = label
        self.helper = helper
        self.placeholder = placeholder
        self.value = value
        self.invalid = invalid
        self.identifier = accessibilityIdentifier
        self.onCommit = onCommit
        _text = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: invalid ? "exclamationmark.circle" : "number")
                    .foregroundStyle(invalid ? Color.red : Theme.Palette.textSecondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityIdentifier(identifier ?? "")
                    .onSubmit { commit() }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 1100)
            // Spec §6.6: no glass on settings content — a plain material card.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            Text(helper)
                .font(Theme.Font.caption)
                .foregroundStyle(invalid ? Color.red : Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        }
        .onChange(of: text) { _, _ in commit() }
        // External change (quick chip toggle / Clear All Filters) → re-seed the local text.
        .onChange(of: value) { _, newValue in
            if text != newValue { text = newValue }
        }
    }

    private func commit() {
        if text != value { onCommit(text) }
    }
}

/// Horizontal row of quick chips; `isOn` drives the accent selected fill, `onToggle` forwards
/// the chip's value to the shared editor (`toggleId`: membership toggle for id lists, replace for
/// single-valued codes). Same chip layout as `LanguageSelectRow`.
private struct FilterChipRow: View {
    let title: String
    let chips: [(label: String, value: String)]
    let isOn: (String) -> Bool
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(chips, id: \.value) { chip in
                        Button { onToggle(chip.value) } label: {
                            Text(chip.label)
                                .font(Theme.Font.meta)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xxs + 2)
                        }
                        .buttonStyle(.chip(selected: isOn(chip.value)))
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }
}
