import Foundation
import SwiftUI
import SharedCore

/// "Account & Services" category content: Sign In/Out, Trakt scrobbling, and Debrid resolver
/// connections. Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and
/// wiring preserved verbatim, only regrouped into a per-category pane.
struct AccountServicesSettingsPane: View {
    @ObservedObject var trakt: TraktViewModel
    @ObservedObject var simkl: SimklViewModel
    @ObservedObject var debrid: DebridViewModel
    @EnvironmentObject private var auth: AuthViewModel
    /// Active backend (official vs self-hosted) for the Server section.
    @StateObject private var server = ActiveServerObserver()

    /// Drives the shared sign-in/sign-out confirmation alert owned by SettingsView.
    @Binding var confirmingSignOut: Bool
    /// Drives the shared Trakt-disconnect confirmation alert owned by SettingsView.
    @Binding var confirmingTraktDisconnect: Bool
    /// Drives the shared Simkl-disconnect confirmation alert owned by SettingsView.
    @Binding var confirmingSimklDisconnect: Bool
    /// Provider id pending a debrid disconnect confirmation (drives the alert owned by SettingsView).
    @Binding var debridDisconnectId: String?
    /// Drives the shared "Use the official server?" confirmation alert owned by SettingsView.
    @Binding var confirmingUseOfficial: Bool

    var body: some View {
        Group {
            SettingsSection(String(localized: "Account")) {
                // VIS-13: the Profile tab is gone. The current profile and the way back to
                // "Who's watching?" live here (renders nothing outside the tab shell).
                SwitchProfileButton()
                    .font(Theme.Font.body)
                if auth.isAnonymous {
                    SettingsActionRow(
                        title: String(localized: "Sign In to Nuvio"),
                        subtitle: String(localized: "Sync your library, watch progress, and profiles across devices. Local guest data on this Apple TV will be cleared."),
                        systemImage: "person.crop.circle.badge.plus"
                    ) {
                        confirmingSignOut = true
                    }
                } else {
                    SettingsDestructiveRow(
                        title: String(localized: "Sign Out"),
                        subtitle: String(localized: "Signed in as \(auth.accountEmail ?? "your Nuvio account"). Local data on this Apple TV will be cleared."),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    ) {
                        confirmingSignOut = true
                    }
                }
            }

            SettingsSection(String(localized: "Server")) {
                serverSection
            }

            SettingsSection(String(localized: "Trakt")) {
                traktSection
            }

            SettingsSection(String(localized: "Simkl")) {
                simklSection
            }

            SettingsSection(String(localized: "Debrid")) {
                debridSection
            }
        }
        // BUG-21 follow-up: verify each connected provider's stored credential the moment the
        // pane opens, so an expired token reads "Session expired" instead of "Connected".
        .onAppear { debrid.revalidateConnected() }
    }

    /// The Server section: which backend this Apple TV talks to, plus the self-hosted discovery
    /// entry point and (when on a custom server) the way back to api.nuvio.tv. Both switches are
    /// destructive (sign-out + local wipe) — the "Use Official Server" confirm is a `.alert` on
    /// SettingsView; the connect flow confirms inside `ServerConnectionView`.
    @ViewBuilder
    private var serverSection: some View {
        SettingsValueRow(
            title: String(localized: "Server"),
            value: server.isCustom
                ? server.displayHost
                : String(localized: "Official Nuvio (\(server.displayHost))"),
            systemImage: "server.rack"
        )
        SettingsLinkRow(
            title: server.isCustom
                ? String(localized: "Connect to Another Server")
                : String(localized: "Connect to a Self-Hosted Server"),
            subtitle: String(localized: "Point this Apple TV at a self-hosted Nuvio backend. Switching servers signs you out and clears local data on this Apple TV."),
            systemImage: "network"
        ) {
            ServerConnectionView()
        }
        if server.isCustom {
            SettingsDestructiveRow(
                title: String(localized: "Use Official Server"),
                subtitle: String(localized: "Switch back to api.nuvio.tv. You\u{2019}ll be signed out and local data on this Apple TV will be cleared."),
                systemImage: "arrow.uturn.backward"
            ) {
                confirmingUseOfficial = true
            }
        }
    }

    /// The Trakt section body — four states: keys missing / connected / awaiting code approval /
    /// disconnected. The device flow runs in the shared repo; this just renders its uiState.
    @ViewBuilder
    private var traktSection: some View {
        if !trakt.credentialsConfigured {
            Text("Trakt isn't configured in this build. Add TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET to local.properties, then rebuild the shared framework.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else if trakt.isConnected {
            SettingsDestructiveRow(
                title: String(localized: "Disconnect Trakt"),
                subtitle: String(localized: "Connected as \(trakt.username ?? "your Trakt account") \u{00B7} watched history is scrobbled automatically as you play."),
                systemImage: "checkmark.circle.fill"
            ) {
                confirmingTraktDisconnect = true
            }
        } else if let code = trakt.deviceUserCode {
            TraktActivationCard(
                code: code,
                verificationUrl: trakt.deviceVerificationUrl ?? "https://trakt.tv/activate"
            ) {
                trakt.cancelActivation()
            }
        } else {
            Text("Scrobble what you watch on this Apple TV to your Trakt profile (movies and episodes are marked watched automatically).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: trakt.isLoading ? String(localized: "Requesting code\u{2026}") : String(localized: "Connect Trakt"),
                subtitle: String(localized: "Shows a short code to enter at trakt.tv/activate on your phone or computer."),
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                trakt.connect()
            }
            if let error = trakt.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The Simkl section body — same four states as `traktSection`. Simkl uses a PIN code (not
    /// Trakt's device code) but the shared repo publishes the same uiState shape, so the pane logic
    /// mirrors Trakt's exactly.
    ///
    /// Once connected the section also carries the deferred-parity set ported from upstream's
    /// Compose tracking settings: Sync Now, "How syncing works", and the anime ID preference —
    /// the last two gated on CONNECTED exactly as upstream gates its "Simkl features" section.
    /// The attribution footnote below is unconditional (upstream keeps it on the licenses page,
    /// which tvOS doesn't have).
    @ViewBuilder
    private var simklSection: some View {
        if !simkl.credentialsConfigured {
            Text("Simkl isn't configured in this build. Add SIMKL_CLIENT_ID to local.properties, then rebuild the shared framework.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else if simkl.isConnected {
            SettingsDestructiveRow(
                title: String(localized: "Disconnect Simkl"),
                subtitle: String(localized: "Connected as \(simkl.username ?? "your Simkl account") \u{00B7} watched history is scrobbled automatically as you play."),
                systemImage: "checkmark.circle.fill"
            ) {
                confirmingSimklDisconnect = true
            }

            SimklSyncNowRow(
                isSyncing: simkl.isSyncing,
                lastSyncedAt: simkl.lastSyncedAt
            ) {
                simkl.syncNow()
            }

            // Non-destructive failure surface: the row above stays pressable, this is just a
            // caption. A sync that fails fast (no client id in this build, no network) leaves the
            // section fully usable.
            if let syncError = simkl.syncErrorMessage {
                Text(syncError)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            SimklSyncInfoRow()

            SettingsPickerRow(
                title: String(localized: "Anime ID Preference"),
                subtitle: String(localized: "Which external ID identifies anime entries. MyAnimeList or Kitsu give each season its own entry; IMDB groups the seasons of a franchise under one ID."),
                selection: Binding(
                    get: { simkl.animeIdPreference },
                    set: { simkl.setAnimeIdPreference($0) }
                ),
                options: SimklAnimeIdOptions.keys,
                label: SimklAnimeIdOptions.name(forKey:)
            )
        } else if let code = simkl.deviceUserCode {
            SimklActivationCard(
                code: code,
                verificationUrl: simkl.deviceVerificationUrl ?? "https://simkl.com/pin/"
            ) {
                simkl.cancelActivation()
            }
        } else {
            Text("Track what you watch on this Apple TV to your Simkl profile (movies and episodes are marked watched automatically).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: simkl.isLoading ? String(localized: "Requesting code\u{2026}") : String(localized: "Connect Simkl"),
                subtitle: String(localized: "Shows a short code to enter at simkl.com/pin on your phone or computer."),
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                simkl.connect()
            }
            if let error = simkl.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }

        // Data-source attribution (upstream's `settings_licenses_attributions_simkl_body`, kept
        // verbatim). Upstream shows it on its Licenses & Attributions page; tvOS has no such page,
        // so the credit lives with the integration it describes and shows in every state — the
        // claim is about the integration, not about being signed in.
        Text("Nuvio connects to Simkl for account authentication, watchlists, watched history, playback progress, and scrobbling. Movie, TV, and anime tracking data is provided by Simkl. Nuvio is not affiliated with or endorsed by Simkl.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)
    }

    // MARK: - Debrid (native TorBox/Premiumize resolution via the shared debrid stack)

    @ViewBuilder
    private var debridSection: some View {
        Text("Connect a debrid service to resolve cached torrent results into direct streaming links on this Apple TV \u{2014} no pre-configured addon URL needed. Keys are per profile and sync between Apple TVs.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        ForEach(debrid.providers, id: \.id) { provider in
            debridProviderRows(provider)
        }

        if debrid.hasAnyKey {
            SettingsToggleRow(
                title: String(localized: "Resolve Streams with Debrid"),
                subtitle: String(localized: "Turn cached torrent results into direct links automatically"),
                isOn: Binding(
                    get: { debrid.resolverEnabled },
                    set: { debrid.setResolverEnabled($0) }
                )
            )
        }

        if debrid.resolverProviders.count > 1 {
            SettingsPickerRow(
                title: String(localized: "Preferred resolver"),
                selection: Binding(
                    get: { debrid.activeResolverId ?? debrid.resolverProviders[0].id },
                    set: { debrid.setPreferredResolver($0) }
                ),
                options: debrid.resolverProviders.map(\.id),
                label: { id in
                    debrid.resolverProviders.first { $0.id == id }?.displayName ?? id
                }
            )
        }
    }

    @ViewBuilder
    private func debridProviderRows(_ provider: DebridProvider) -> some View {
        if debrid.isConnected(provider.id) {
            // Session-expired beats Connected (BUG-21 follow-up): the stored token failed auth
            // on a real provider call or the pane-open revalidation. Same disconnect action —
            // reconnecting mints a fresh token, which is the entire fix.
            if debrid.authFailedIds.contains(provider.id) {
                SettingsDestructiveRow(
                    title: String(localized: "\(provider.displayName) \u{00B7} Session expired"),
                    subtitle: String(localized: "\(provider.displayName) rejected the saved sign-in. Press to disconnect, then connect again."),
                    systemImage: "exclamationmark.triangle.fill"
                ) {
                    debridDisconnectId = provider.id
                }
            } else {
                SettingsDestructiveRow(
                    title: String(localized: "\(provider.displayName) \u{00B7} Connected"),
                    subtitle: debrid.activeResolverId == provider.id
                        ? String(localized: "Active resolver \u{00B7} press to disconnect")
                        : String(localized: "Press to disconnect"),
                    systemImage: "checkmark.circle.fill"
                ) {
                    debridDisconnectId = provider.id
                }
            }
        } else if debrid.authProviderId == provider.id {
            switch debrid.authPhase {
            case .starting:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Requesting a sign-in code from \(provider.displayName)\u{2026}")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            case .waiting:
                if let session = debrid.activeSession {
                    DebridActivationCard(
                        providerName: provider.displayName,
                        code: session.userCode,
                        verificationUrl: session.friendlyVerificationUrl
                    ) {
                        debrid.cancelActivation()
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
                SettingsActionRow(
                    title: String(localized: "Dismiss"),
                    subtitle: String(localized: "Back to the connect options for \(provider.displayName)."),
                    systemImage: "xmark.circle"
                ) {
                    debrid.cancelActivation()
                }
            case .idle:
                EmptyView()
            }
        } else {
            if debrid.supportsDeviceSignIn(provider) {
                SettingsActionRow(
                    title: String(localized: "Connect \(provider.displayName)"),
                    subtitle: String(localized: "Shows a short code to enter on your phone (device sign-in)."),
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    debrid.connect(provider)
                }
            } else {
                // DEB-1: Real-Debrid has no device sign-in — API key only.
                Text("\(provider.displayName) has no device sign-in here: paste the API key from your \(provider.displayName) account. It resolves the links of add-ons that hand them to \(provider.displayName).")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
            // DEB-2: checked with the provider before it is saved; a rejected key stays in the
            // field with the reason below it.
            DebridKeyEntryRow(
                providerName: provider.displayName,
                placeholder: debrid.supportsDeviceSignIn(provider) ? nil : String(localized: "\(provider.displayName) API key"),
                clearsOnSave: false,
                isValidating: debrid.validatingKeyProviderId == provider.id,
                errorMessage: debrid.keyErrors[provider.id]
            ) { key in
                debrid.saveManualKey(provider.id, key: key)
            }
        }
    }
}

/// Manual "Sync now" for Simkl (upstream's primary button on the connected provider card).
///
/// Deliberately NOT `.disabled(isSyncing)`: disabling a focused tvOS row throws focus somewhere
/// else mid-sync and then takes it back when the sync ends. The double-press guard lives in
/// `SimklViewModel.syncNow()` instead, so a press during a sync is a harmless no-op.
private struct SimklSyncNowRow: View {
    let isSyncing: Bool
    let lastSyncedAt: Date?
    let action: () -> Void

    /// 15 minutes is `SIMKL_AUTOMATIC_REFRESH_INTERVAL_MINUTES` in the shared refresh policy. That
    /// constant is `internal` in Kotlin, so it isn't in the SharedCore framework header and can't
    /// be read here — if the shared interval ever changes, this copy has to change with it.
    private static let automaticIntervalMinutes = 15

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var subtitle: String {
        if isSyncing {
            return String(localized: "Checking Simkl for changes made in another app or on the website\u{2026}")
        }
        guard let lastSyncedAt else {
            return String(localized: "Check Simkl now instead of waiting for the next automatic check (every \(Self.automaticIntervalMinutes) minutes).")
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

/// "How Syncing Works" — upstream's `SimklSyncInfoDialog` adapted to tvOS.
///
/// Rendered as an expanding row rather than an alert: it is four paragraphs of explanation with no
/// decision attached, and a tvOS alert with that much body text is unreadable at 10 feet. The
/// collapsed/expanded header is a kit `SettingsActionRow` that toggles `isExpanded`, with the
/// paragraphs below it as plain body text when expanded — a "few rows" inline sub-flow per the
/// beta.15 §C3 conversion rules, not a pushed page.
///
/// Upstream's "Read the Simkl sync guide" button is dropped: it calls `UriHandler.openUri`, and
/// tvOS has no browser to hand the URL to. The URL is printed instead so it can be opened on a
/// phone — the same escape hatch the activation cards above use for simkl.com/pin.
private struct SimklSyncInfoRow: View {
    @State private var isExpanded = false

    /// Same 15 as `SimklSyncNowRow.automaticIntervalMinutes` (upstream substitutes it into the
    /// dialog's first paragraph).
    private static let automaticIntervalMinutes = 15

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SettingsActionRow(
                title: String(localized: "How Syncing Works"),
                subtitle: String(localized: "What Nuvio sends to Simkl, when it checks back, and why some shows leave Continue Watching."),
                systemImage: "info.circle"
            ) {
                isExpanded.toggle()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Nuvio automatically checks Simkl at most once every \(Self.automaticIntervalMinutes) minutes. Changes made through another app or the Simkl website may take that long to appear.")
                    Text("Each refresh first checks whether Simkl reports any changes and downloads only the updates. This follows Simkl\u{2019}s API rules, reduces unnecessary data use, and helps keep the service stable.")
                    Text("Changes made in Nuvio are sent to Simkl immediately. Use Sync Now whenever you want Nuvio to check for remote changes sooner.")
                    Text("Shows placed in Simkl\u{2019}s On Hold or Dropped lists are hidden from Continue Watching. They remain hidden for as long as they stay in either list.")
                    Text("Full sync guide: api.simkl.org/guides/sync")
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.leading, Theme.Spacing.md)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

/// Anime ID preference options for the `SettingsPickerRow` in `simklSection` — which external ID
/// is the canonical content ID for anime resolved through Simkl (`SimklAnimeIdPreference`).
/// MyAnimeList or Kitsu give each season its own entry; IMDB groups a franchise's seasons under
/// one ID (the trade-off folded into the picker row's subtitle since a tvOS `Menu` item can't
/// carry upstream's per-option descriptions).
private enum SimklAnimeIdOptions {
    static let keys = ["imdb", "mal", "kitsu", "tvdb"]

    private static let names: [String: String] = [
        "imdb": String(localized: "Prefer IMDB"),
        "mal": String(localized: "Prefer MyAnimeList"),
        "kitsu": String(localized: "Prefer Kitsu"),
        // Upstream 8aad52d83: groups a franchise's seasons like IMDB, without its per-season splits.
        "tvdb": String(localized: "Prefer TVDB")
    ]

    static func name(forKey key: String) -> String {
        names[key] ?? key
    }
}

/// Shown while a Trakt device-code flow awaits approval: the big user code, where to enter it,
/// a waiting spinner (the shared repo polls in the background), and a Cancel row.
private struct TraktActivationCard: View {
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("On your phone or computer, go to")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(verificationUrl)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("and enter this code:")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(code)
                .font(Theme.Font.hero.monospaced())
                .kerning(12)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Waiting for approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
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

/// Shown while a Simkl PIN flow awaits approval: same layout as `TraktActivationCard` (the shared
/// repo publishes the same code/verificationUrl shape), kept as its own sibling struct rather than
/// a shared/generic component — `DebridActivationCard` below establishes that as the precedent for
/// this file, so a provider-specific card doesn't need parameterizing into a generic one.
private struct SimklActivationCard: View {
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("On your phone or computer, go to")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(verificationUrl)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("and enter this code:")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(code)
                .font(Theme.Font.hero.monospaced())
                .kerning(12)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Waiting for approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
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

/// Shown while a debrid device-code flow awaits approval (mirrors `TraktActivationCard`).
private struct DebridActivationCard: View {
    let providerName: String
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("On your phone or computer, go to")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(verificationUrl)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("and enter this code:")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(code)
                .font(Theme.Font.hero.monospaced())
                .kerning(12)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Waiting for \(providerName) approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
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
