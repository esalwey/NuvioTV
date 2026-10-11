import SwiftUI
import SharedCore

// Settings -> Account & Services -> Media Servers: sign in to Jellyfin or Emby, choose which of a
// server's libraries show up in Nuvio, and decide how its titles and watched state are used.
//
// Built from the stock Settings kit (SettingsRowViews.swift): a native `List`, `Toggle`,
// `NavigationLink`, system text fields and a `confirmationDialog` — no custom focus treatment, no
// glass (this is content, not chrome). Menu pops exactly one level everywhere:
//
//   Account & Services -> Media Servers -> server page -> Sign In Again
//                                       -> Add a Server (Jellyfin / Emby) sign-in page
//
// Every page keeps at least one focusable row in every state (BUG-47 class): the list always offers
// the provider rows, the server page always offers Refresh / Sign In Again / Remove, and the sign-in
// page always offers its fields.

// MARK: - Entry point in Account & Services

/// The "Media Servers" block of the Account & Services pane. Owns the view model so the summary
/// subtitle stays live and the pushed pages share it.
struct MediaServersSettingsSection: View {
    @StateObject private var model = MediaServersViewModel()

    var body: some View {
        SettingsSection(String(localized: "Media Servers")) {
            SettingsLinkRow(
                title: String(localized: "Jellyfin & Emby"),
                subtitle: summary,
                systemImage: "externaldrive.connected.to.line.below"
            ) {
                MediaServersView(model: model)
            }
            .onAppear { model.start() }
        }
    }

    private var summary: String {
        model.servers.isEmpty
            ? String(localized: "Connect a server to browse and play your own library.")
            : String(localized: "\(model.servers.count) connected")
    }
}

// MARK: - Server list

struct MediaServersView: View {
    @ObservedObject var model: MediaServersViewModel

    var body: some View {
        List {
            SettingsSection(String(localized: "Servers")) {
                if model.servers.isEmpty {
                    // Static text, not a row: it must not take focus. The provider rows below keep
                    // the page enterable.
                    Text("No servers connected yet.")
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.servers) { server in
                        SettingsLinkRow(
                            title: server.name,
                            subtitle: server.summary,
                            systemImage: "externaldrive.connected.to.line.below"
                        ) {
                            MediaServerDetailView(model: model, serverId: server.id)
                        }
                    }
                }
            }

            SettingsSection(
                String(localized: "Add a Server"),
                footer: String(localized: "Servers on your home network work over plain HTTP. Your password is only used to sign in and is never stored.")
            ) {
                ForEach(model.providers) { provider in
                    NavigationLink {
                        MediaServerSignInView(model: model, provider: provider)
                    } label: {
                        MediaServerProviderLabel(
                            providerId: provider.id,
                            title: provider.displayName,
                            subtitle: String(localized: "Sign in with your server address and \(provider.displayName) user.")
                        )
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Media Servers"))
        .onAppear { model.start() }
    }
}

// MARK: - Provider label + logo

/// A provider logo at a size that follows Dynamic Type, with a neutral glyph for an unknown brand.
struct MediaServerLogo: View {
    let providerId: String
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        Group {
            switch providerId {
            case "jellyfin":
                Image("JellyfinLogo").resizable().scaledToFit()
            case "emby":
                Image("EmbyLogo").resizable().scaledToFit()
            default:
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(SettingsRowFont.title)
                    .settingsAccentTint()
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Row label for a provider: logo, then the same title/subtitle block every Settings row uses.
private struct MediaServerProviderLabel: View {
    let providerId: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            MediaServerLogo(providerId: providerId)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(SettingsRowFont.title)
                Text(subtitle)
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sign in

/// Address, username and password for one provider. Pushed (not a sheet) so Menu simply goes back;
/// the system keyboard opens when a field is pressed. On success the page pops itself and the new
/// server appears in the list; signing in again to a connected server replaces its token and keeps
/// its library choices.
struct MediaServerSignInView: View {
    @ObservedObject var model: MediaServersViewModel
    let provider: MediaServerProviderItem

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var username: String
    @State private var password = ""
    /// This page started the sign-in that is running, so only it reacts to the success signal.
    @State private var submitted = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case address, username, password }

    init(model: MediaServersViewModel, provider: MediaServerProviderItem, address: String = "", username: String = "") {
        self.model = model
        self.provider = provider
        _address = State(initialValue: address)
        _username = State(initialValue: username)
    }

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                TextField(
                    String(localized: "Server Address"),
                    text: $address,
                    prompt: Text(verbatim: "http://192.168.1.10:8096")
                )
                .font(Theme.Font.body)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .username }
                .onChange(of: address) { _, _ in model.clearConnectFailure() }
                .accessibilityIdentifier("mediaserver.address")

                TextField(String(localized: "Username"), text: $username)
                    .font(Theme.Font.body)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .onChange(of: username) { _, _ in model.clearConnectFailure() }
                    .accessibilityIdentifier("mediaserver.username")

                SecureField(String(localized: "Password"), text: $password)
                    .font(Theme.Font.body)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .onChange(of: password) { _, _ in model.clearConnectFailure() }
                    .accessibilityIdentifier("mediaserver.password")
            } header: {
                Text("Sign in to \(provider.displayName)")
                    .font(SettingsRowFont.sectionHeader)
            } footer: {
                Text("Enter your server address and the \(provider.displayName) user to sign in with. Your password is only used to sign in.")
                    .font(SettingsRowFont.sectionHeader)
            }

            Section {
                // Not `.disabled()` while connecting: that would throw focus off the button on
                // tvOS. The view model ignores a second press instead.
                Button(action: connect) {
                    HStack(spacing: Theme.Spacing.md) {
                        Text(model.isConnecting ? String(localized: "Connecting\u{2026}") : String(localized: "Connect"))
                            .font(SettingsRowFont.title)
                        Spacer(minLength: 0)
                        if model.isConnecting { ProgressView() }
                    }
                }
                .disabled(!canConnect && !model.isConnecting)
                .accessibilityIdentifier("mediaserver.connect")

                if let error = model.connectError {
                    Text(error)
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(Theme.Palette.warning)
                }
            }
        }
        .navigationTitle(String(localized: "Sign In"))
        .onAppear {
            model.start()
            model.clearConnectFailure()
        }
        .onChange(of: model.connectGeneration) { _, _ in
            if submitted { dismiss() }
        }
        .onDisappear {
            // The password never outlives the page, and a failure belongs to this attempt only.
            password = ""
            model.clearConnectFailure()
        }
    }

    private func connect() {
        guard canConnect, !model.isConnecting else { return }
        submitted = true
        model.connect(
            provider: provider,
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }
}

// MARK: - Server page

struct MediaServerDetailView: View {
    @ObservedObject var model: MediaServersViewModel
    let serverId: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    var body: some View {
        Group {
            if let server = model.server(serverId) {
                content(for: server)
            } else {
                // The server was removed (here or on another device): leave instead of showing a
                // page about nothing.
                List {
                    Text("This server is no longer connected.")
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.secondary)
                }
                .onAppear { dismiss() }
            }
        }
        .navigationTitle(model.server(serverId)?.name ?? "")
        .onAppear {
            model.start()
            // A "refresh failed" note is about one visit to one server: it does not carry over.
            model.clearRefreshError()
        }
        .onDisappear { model.clearRefreshError() }
        .onChange(of: model.server(serverId) == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    @ViewBuilder
    private func content(for server: MediaServerItem) -> some View {
        List {
            Section {
                SettingsValueRow(
                    title: String(localized: "Account"),
                    value: "\(server.providerName) \u{00B7} \(server.userName)"
                )
                SettingsValueRow(title: String(localized: "Address"), value: server.address)
                if let note = server.status.note {
                    SettingsValueRow(title: String(localized: "Status"), value: note)
                }
            }

            Section {
                SettingsToggleRow(
                    title: String(localized: "Enabled"),
                    subtitle: String(localized: "Show in Home, search, and stream results."),
                    isOn: Binding(
                        get: { server.enabled },
                        set: { model.setEnabled(server.id, $0) }
                    )
                )
                if server.supportsCatalogMetadata {
                    SettingsToggleRow(
                        title: String(localized: "Use Add-on Metadata"),
                        subtitle: String(localized: "Open titles with your add-ons\u{2019} details."),
                        isOn: Binding(
                            get: { server.useCatalogMetadata },
                            set: { model.setCatalogMetadata(server.id, $0) }
                        )
                    )
                    .disabled(!server.enabled)
                }
                if server.supportsWatchStateImport {
                    SettingsToggleRow(
                        title: String(localized: "Import Watch Progress"),
                        subtitle: String(localized: "Add what you\u{2019}re watching to Continue Watching."),
                        isOn: Binding(
                            get: { server.importWatchState },
                            set: { model.setImportWatchState(server.id, $0) }
                        )
                    )
                    .disabled(!server.enabled)
                }
            } footer: {
                // Long explanations belong in the footer, not in the rows (design spec 6.6).
                Text(behaviourFooter(for: server))
                    .font(SettingsRowFont.sectionHeader)
            }

            Section {
                ForEach(server.libraries) { library in
                    SettingsToggleRow(
                        title: library.name,
                        subtitle: library.kindLabel,
                        isOn: Binding(
                            get: { library.selected },
                            set: { model.setLibrarySelected(server.id, libraryId: library.id, $0) }
                        )
                    )
                    .disabled(!server.enabled)
                }
            } header: {
                Text("Libraries")
                    .font(SettingsRowFont.sectionHeader)
            } footer: {
                Text(
                    server.libraries.isEmpty
                        ? String(localized: "No movie or series libraries are available to this user.")
                        : String(localized: "Selected libraries appear in Home rows, Library, search, and stream results.")
                )
                .font(SettingsRowFont.sectionHeader)
            }

            Section {
                refreshRow(for: server)
                if let error = model.refreshError, model.refreshErrorServerId == server.id {
                    Text(error)
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(Theme.Palette.warning)
                }
                SettingsLinkRow(title: String(localized: "Sign In Again"), systemImage: "lock") {
                    MediaServerSignInView(
                        model: model,
                        provider: model.provider(server.providerId)
                            ?? MediaServerProviderItem(id: server.providerId, displayName: server.providerName, minimumVersion: ""),
                        address: server.address,
                        username: server.userName
                    )
                }
            }

            Section {
                SettingsDestructiveRow(title: String(localized: "Remove Server"), systemImage: "trash") {
                    confirmingRemoval = true
                }
            }
        }
        .confirmationDialog(
            String(localized: "Remove this server?"),
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Server", role: .destructive) { model.remove(server.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs you out of \(server.name) on this Apple TV. You can add it back anytime.")
        }
    }

    /// What the two optional toggles do, for the footer under them. Only the sentences for toggles
    /// the provider actually offers are included.
    private func behaviourFooter(for server: MediaServerItem) -> String {
        var sentences: [String] = []
        if server.supportsCatalogMetadata {
            sentences.append(String(localized: "Add-on metadata makes server titles open and sync like any other catalog title, with playback and watched marks still sent to \(server.providerName). Some titles may not match or play if your add-ons number or identify them differently."))
        }
        if server.supportsWatchStateImport {
            sentences.append(String(localized: "Imported watch progress and watched marks come from \(server.providerName). Playback resumes from \(server.providerName) either way."))
        }
        return sentences.joined(separator: " ")
    }

    /// Refresh Libraries with its own progress indicator. Never `.disabled()` while running (that
    /// would eject focus); the view model ignores a second press.
    private func refreshRow(for server: MediaServerItem) -> some View {
        Button {
            model.refreshLibraries(server.id)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                SettingsRowLabel(title: String(localized: "Refresh Libraries"), systemImage: "arrow.clockwise")
                Spacer(minLength: 0)
                if model.refreshingServerId == server.id { ProgressView() }
            }
        }
        .disabled(!server.enabled && model.refreshingServerId != server.id)
    }
}
