import Combine
import SwiftUI
import SharedCore

/// Debrid cloud library (TorBox / Premiumize cloud files) for the Library tab, backed by the
/// shared `CloudLibraryRepository`. Lists each connected provider's cloud items; selecting a
/// playable file resolves a direct link via `resolvePlayback(item:file:)` and hands a
/// `PlaybackContext` to the standard MPV player.
///
/// Playback keying mirrors mobile (`App.kt` cloud launch): contentType = "cloud",
/// videoId = "\(item.stableKey):\(file.stableKey)" (shared `playbackVideoId` format),
/// parentMetaId = item.stableKey — so watch progress and resume work like any other title.
@MainActor
final class CloudLibraryViewModel: ObservableObject {
    @Published private(set) var state: CloudLibraryUiState?
    /// stableKey of the file currently resolving (spinner on that row; taps ignored meanwhile).
    @Published private(set) var resolvingFileKey: String?
    @Published private(set) var errorMessage: String?
    /// Set when a link resolves — drives the player cover.
    @Published var playback: PlaybackContext?

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(CloudLibraryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? CloudLibraryUiState else { return }
            self.state = value
        }
        CloudLibraryRepository.shared.ensureLoaded()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func refresh() {
        CloudLibraryRepository.shared.refresh()
    }

    deinit { watcher?.cancel() }

    var providers: [CloudLibraryProviderState] { state?.providers ?? [] }
    var hasConnectedProvider: Bool { state?.hasConnectedProvider ?? false }
    var isRefreshing: Bool { state?.isRefreshing ?? false }

    func play(item: CloudLibraryItem, file: CloudLibraryFile) {
        guard resolvingFileKey == nil else { return }
        resolvingFileKey = file.stableKey
        errorMessage = nil

        CloudLibraryRepository.shared.resolvePlayback(item: item, file: file) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvingFileKey = nil

                if let success = result as? CloudLibraryPlaybackResultSuccess {
                    self.startPlayback(item: item, file: file, success: success)
                } else if result is CloudLibraryPlaybackResultMissingCredentials {
                    self.errorMessage = String(localized: "Missing provider credentials \u{2014} reconnect in Settings \u{2192} Debrid.")
                } else if result is CloudLibraryPlaybackResultNotPlayable {
                    self.errorMessage = String(localized: "This file isn't playable.")
                } else if let failed = result as? CloudLibraryPlaybackResultFailed {
                    let message: String? = failed.message
                    self.errorMessage = message ?? String(localized: "Couldn't resolve a playback link.")
                } else {
                    self.errorMessage = error?.localizedDescription ?? String(localized: "Couldn't resolve a playback link.")
                }
            }
        }
    }

    private func startPlayback(item: CloudLibraryItem, file: CloudLibraryFile, success: CloudLibraryPlaybackResultSuccess) {
        guard let url = URL(string: success.url) else {
            errorMessage = String(localized: "The provider returned an unplayable link.")
            return
        }
        let filename: String? = success.filename
        let fallbackName = file.name.isEmpty ? item.name : file.name
        let title = (filename?.isEmpty == false ? filename : nil) ?? fallbackName

        playback = PlaybackContext(
            url: url,
            title: title,
            contentType: CloudLibraryModelsKt.CloudLibraryContentType,
            parentMetaId: item.stableKey,
            videoId: "\(item.stableKey):\(file.stableKey)",
            season: nil,
            episode: nil,
            poster: CloudLibraryModelsKt.cloudLibraryProviderPosterUrl(providerIdOrContentId: item.providerId),
            background: nil,
            providerName: item.providerName,
            providerAddonId: "cloud:\(item.providerId)",
            streamTitle: title,
            streamSubtitle: item.name == title ? nil : item.name,
            externalSubtitles: []
        )
    }
}

/// Identifiable wrapper so a multi-file item can drive a `.fullScreenCover(item:)` file picker.
struct CloudFilePickerRoute: Identifiable {
    let item: CloudLibraryItem
    var id: String { item.stableKey }
}

/// One provider's cloud items as a titled section of focusable rows.
struct CloudProviderSection: View {
    let provider: CloudLibraryProviderState
    let resolvingFileKey: String?
    let onSelect: (CloudLibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Text(provider.providerName)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if provider.isLoading {
                    ProgressView()
                }
            }

            if let error = providerError {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }

            if provider.items.isEmpty && !provider.isLoading {
                Text("No files in your \(provider.providerName) cloud.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                LazyVStack(spacing: Theme.Spacing.lg) {
                    ForEach(provider.items, id: \.stableKey) { item in
                        CloudItemRow(
                            item: item,
                            isResolving: isResolving(item)
                        ) {
                            onSelect(item)
                        }
                    }
                }
            }
        }
    }

    private var providerError: String? {
        let message: String? = provider.errorMessage
        return message
    }

    private func isResolving(_ item: CloudLibraryItem) -> Bool {
        guard let resolvingFileKey else { return false }
        return item.playableFiles.contains { $0.stableKey == resolvingFileKey }
    }
}

/// One cloud item (torrent/usenet/web download) as a focusable row: name, size, status, file count.
///
/// Wave 2 (X3): the system `.card` button style, the information-dense lockup of spec 5.3 (a
/// platter with the system lift and press), instead of the app's settings-row style. Labels use
/// semantic `.primary`/`.secondary`, so focus and Increase Contrast come from tvOS.
struct CloudItemRow: View {
    let item: CloudLibraryItem
    let isResolving: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: iconName)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(item.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(detailLine)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isResolving {
                    ProgressView()
                } else if !item.playableFiles.isEmpty {
                    Image(systemName: "play.circle")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
        .disabled(item.playableFiles.isEmpty)
    }

    private var iconName: String {
        // Kotlin enum instances — compare with ==, don't pattern-match (proven codebase pattern).
        if item.type == CloudLibraryItemType.torrent { return "arrow.down.circle" }
        if item.type == CloudLibraryItemType.usenet { return "shippingbox" }
        if item.type == CloudLibraryItemType.webdownload { return "globe" }
        return "doc"
    }

    private var detailLine: String {
        var parts: [String] = []
        if let size = item.sizeBytes?.int64Value, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        let playableCount = item.playableFiles.count
        if playableCount > 1 {
            parts.append(String(localized: "\(playableCount) playable files"))
        } else if playableCount == 0 {
            parts.append(String(localized: "No playable files"))
        }
        let status: String? = item.status
        if let status, !status.isEmpty {
            parts.append(status)
        }
        if let progress = item.progressFraction?.floatValue, progress < 1.0 {
            parts.append("\(Int(progress * 100))%")
        }
        return parts.isEmpty ? item.providerName : parts.joined(separator: " \u{00B7} ")
    }
}

/// Full-screen chooser for multi-file items: pick which file to play. A system `List`, so rows get
/// the standard white focus platter and Menu dismisses the cover.
struct CloudFilePickerView: View {
    let item: CloudLibraryItem
    let onPick: (CloudLibraryFile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(item.playableFiles.enumerated()), id: \.element.stableKey) { _, file in
                        Button {
                            dismiss()
                            onPick(file)
                        } label: {
                            HStack(spacing: Theme.Spacing.lg) {
                                Image(systemName: "play.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(file.name)
                                    .font(Theme.Font.body)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                if let size = file.sizeBytes?.int64Value, size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(Theme.Font.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Choose a file to play")
                }
            }
            .navigationTitle(item.name)
        }
        .background(Theme.Palette.background.ignoresSafeArea())
    }
}
