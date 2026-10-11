import SwiftUI
import UIKit
import SharedCore

// MARK: - Collapsible tracker card

/// Header row of a collapsible tracker card (Trakt, Simkl, MDBList): the status in one line, with
/// a chevron that says whether the card's rows are showing. The cards start collapsed, so Account &
/// Services opens on Account and Server instead of three screens of tracker controls.
///
/// A plain `Button` in its own list row, shaped like `SettingsActionRow`: the system inverts its
/// label on the focus platter, and the chevron is `.secondary` like every trailing value.
struct TrackerDisclosureRow: View {
    let title: String
    let summary: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                SettingsRowLabel(title: title, subtitle: summary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }
}

// MARK: - Device-code activation

/// Shown while an MDBList device code waits for approval: a QR code of the approval page (the code
/// is already filled in, so a phone camera is enough), the address and the code as the manual
/// fallback, a waiting indicator (the shared tracker keeps polling in the background) and Cancel.
struct MdbListActivationCard: View {
    let code: String
    let verificationUrl: String
    let qrImage: UIImage?
    let onCancel: () -> Void

    /// "https://mdblist.com/oauth/device/" → "mdblist.com/oauth/device"
    private var readableUrl: String {
        var text = verificationUrl
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 280, height: 280)
                        .padding(Theme.Spacing.md)
                        // A QR code needs a light quiet zone around it to scan, in any theme.
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .accessibilityLabel(Text("QR code for the MDBList approval page"))
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Scan the QR code with your phone, or go to")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                    Text(readableUrl)
                        .font(Theme.Font.sectionTitle)
                    Text("and enter this code:")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(Theme.Font.hero.monospaced())
                        .kerning(12)
                        .padding(.vertical, Theme.Spacing.sm)
                        .accessibilityLabel(Text(code.map(String.init).joined(separator: " ")))
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Waiting for approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsActionRow(
                title: String(localized: "Cancel"),
                subtitle: String(localized: "Stop waiting and dismiss the code."),
                systemImage: "xmark.circle"
            ) {
                onCancel()
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

// MARK: - Sync now

/// Manual "Sync Now" for MDBList. Deliberately NOT `.disabled(isSyncing)`: disabling a focused tvOS
/// row throws focus elsewhere mid-sync and takes it back afterwards. The double-press guard lives in
/// the shared bridge instead, so a press during a sync is a harmless no-op.
struct MdbListSyncNowRow: View {
    let isSyncing: Bool
    let lastSyncedAt: Date?
    let action: () -> Void

    /// 15 minutes is `MdbListSyncRepository.AUTOMATIC_INTERVAL_MS`; keep this copy in step with it.
    private static let automaticIntervalMinutes = 15

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var subtitle: String {
        if isSyncing {
            return String(localized: "Checking MDBList for changes made in another app or on the website\u{2026}")
        }
        guard let lastSyncedAt else {
            return String(localized: "Check MDBList now instead of waiting for the next automatic check (every \(Self.automaticIntervalMinutes) minutes).")
        }
        let relative = Self.relativeFormatter.localizedString(for: lastSyncedAt, relativeTo: Date())
        return String(localized: "Last synced \(relative) \u{00B7} Nuvio checks on its own at most every \(Self.automaticIntervalMinutes) minutes.")
    }

    var body: some View {
        SettingsActionRow(
            title: isSyncing ? String(localized: "Syncing\u{2026}") : String(localized: "Sync Now"),
            subtitle: subtitle,
            systemImage: "arrow.triangle.2.circlepath",
            action: action
        )
    }
}

// MARK: - Library lists

/// Pushed page: which MDBList lists appear in the library. The Watchlist is always shown; every
/// other list is a switch. Hidden lists are not downloaded from MDBList. Keeps a focusable row in
/// every state (a reload action), so an empty page is never a focus dead end.
///
/// It owns its view model rather than borrowing Settings': the Settings root stops its own
/// observers when this page is pushed over it, and this page still has to follow the lists.
/// Every instance reads the same shared state, so the two never disagree.
struct MdbListLibraryListsPage: View {
    @StateObject private var mdblist = MdbListViewModel()

    var body: some View {
        List {
            SettingsSection(
                title: String(localized: "Lists in Your Library"),
                footer: String(localized: "The Watchlist is always shown. Hidden lists are not downloaded from MDBList.")
            ) {
                if mdblist.lists.isEmpty {
                    Text(mdblist.isSyncing
                        ? String(localized: "Loading your lists\u{2026}")
                        : String(localized: "No lists yet. Create a static list on mdblist.com and it will appear here."))
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mdblist.lists, id: \.key) { option in
                        SettingsToggleRow(
                            title: option.name,
                            isOn: Binding(
                                get: { mdblist.isListVisible(option) },
                                set: { mdblist.setListVisible(option.key, visible: $0) }
                            )
                        )
                    }
                }
                if let error = mdblist.listErrorMessage {
                    Text(error)
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.red)
                }
            }

            SettingsSection(nil) {
                MdbListSyncNowRow(isSyncing: mdblist.isSyncing, lastSyncedAt: mdblist.lastSyncedAt) {
                    mdblist.syncNow()
                }
            }
        }
        .navigationTitle(Text("MDBList Lists"))
        .onAppear { mdblist.start() }
        .onDisappear { mdblist.stop() }
    }
}
