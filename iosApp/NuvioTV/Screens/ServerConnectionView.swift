import SwiftUI
import SharedCore

/// Self-hosted server flow (presented as a `.fullScreenCover` from Welcome and pushed via NavigationLink from Settings →
/// Account & Services). Two steps driven entirely by the shared `ServerConnectionController`:
///
/// 1. ENTER — type the backend URL; "Check Server" runs `/.well-known/nuvio` discovery.
/// 2. REVIEW — the discovered configuration (backend, sign-in capabilities) plus the trust
///    warning (Android TV's copy); "Connect to This Server" confirms via a system `.alert`
///    (switching signs the user out and clears local data on this Apple TV), then the Kotlin
///    controller swaps the backend and re-initialises auth.
///
/// The cover is torn down either by the root gate cycling (welcome → loading → welcome on
/// re-init, or Settings unmounting on sign-out) or — belt and braces — by `onChange` of the
/// active backend URL below. Every state keeps a focusable control (BUG-47 eject class).
struct ServerConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ServerConnectionViewModel()
    @State private var url: String
    @State private var confirmingConnect = false
    /// Programmatic focus across the step swap: when the entry controls are replaced by the
    /// review panel (and back), tvOS can be left with NO focused element — the review's buttons
    /// sit below the fold of the ScrollView, so D-pad presses would go nowhere and Menu would be
    /// the only way out. Steering focus to the step's primary control keeps the flow driveable
    /// (and scrolls the buttons into view).
    private enum FocusTarget: Hashable { case url, check, connect, back }
    @FocusState private var focusTarget: FocusTarget?
    /// Active backend when the cover appeared — a change means the switch landed → dismiss.
    @State private var backendUrlAtAppear: String?

    init() {
        // Like Android TV: pre-fill with the current custom server's discovery base so "change
        // server" starts from something editable rather than an empty field.
        _url = State(initialValue: ServerConnectionViewModel.activeCustomDiscoveryBase() ?? "")
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(spacing: Theme.Spacing.xl) {
                    if vm.discovered == nil {
                        enterStep
                    } else {
                        reviewStep
                    }
                }
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.screen)
            }
        }
        .onAppear {
            if backendUrlAtAppear == nil { backendUrlAtAppear = vm.activeBackendUrl }
        }
        .onChange(of: vm.discovered == nil) { _, isEntryStep in
            // Let the new step's controls mount before asking for focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusTarget = isEntryStep ? .url : .connect
            }
        }
        .onChange(of: vm.activeBackendUrl) { _, newValue in
            // The controller publishes the new active server only after a successful switch
            // (isSwitching already false in the same emission) — close the cover.
            if let start = backendUrlAtAppear, newValue != start, !vm.isSwitching {
                dismiss()
            }
        }
        .onDisappear {
            // Don't clobber an in-flight switch; otherwise leave the controller clean for the
            // next presentation (Welcome or Settings).
            if !vm.isSwitching { vm.resetDiscovery() }
        }
        .alert("Switch to \(vm.discoveredHost)?", isPresented: $confirmingConnect) {
            Button("Connect", role: .destructive) { vm.connectDiscovered() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You\u{2019}ll be signed out of the current server and local data on this Apple TV will be cleared. Your synced data stays on its own server.")
        }
    }

    // MARK: - Step 1: enter URL

    @ViewBuilder
    private var enterStep: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "server.rack")
                .font(Theme.Font.hero)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            Text("Connect to a Self-Hosted Server")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Enter the backend URL from your server administrator. Nuvio reads /.well-known/nuvio on that server to discover its settings.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }

        // Spec gap 14: no glass on a form. The system text field draws its own platter and
        // focus treatment.
        TextField("https://backend.example.com", text: $url)
            .keyboardType(.URL)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(Theme.Font.body)
            .accessibilityIdentifier("server.url")
            .focused($focusTarget, equals: .url)
            .frame(maxWidth: 900)

        if let message = vm.failureMessage {
            Text(message)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.warning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }

        HStack(spacing: Theme.Spacing.lg) {
            // Never `.disabled()` while checking — that throws focus off the button on tvOS;
            // the VM/controller simply ignore a second press mid-discovery.
            Button {
                vm.discover(url)
            } label: {
                if vm.isDiscovering {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                        Text("Checking\u{2026}")
                            .font(Theme.Font.body)
                    }
                    .frame(minWidth: 240)
                } else {
                    Text("Check Server")
                        .font(Theme.Font.body)
                        .frame(minWidth: 240)
                }
            }
            // System bordered buttons: white platter on focus, no brand fill (spec §5.5).
            .buttonStyle(.bordered)
            .accessibilityIdentifier("server.check")
            .focused($focusTarget, equals: .check)

            Button {
                vm.resetDiscovery()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(Theme.Font.body)
                    .frame(minWidth: 240)
            }
            .buttonStyle(.bordered)
        }

        if vm.activeIsCustom {
            Text("Currently connected to \(vm.activeDisplayHost).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            Text("Currently using the official Nuvio server.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: - Step 2: review + confirm

    @ViewBuilder
    private var reviewStep: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "checkmark.shield")
                .font(Theme.Font.hero)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            Text("Review Server")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityIdentifier("server.review")
            Text("The discovery document is valid. Connecting signs you out of the current server and clears local data on this Apple TV. Only continue if you own or trust this server.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            detailRow(
                label: Text("Backend"),
                value: Text(verbatim: vm.discoveredBackendUrl),
                monospaced: true,
                valueIdentifier: "server.backend"
            )
            detailRow(
                label: Text("Client configuration"),
                value: Text("Publishable key discovered automatically")
            )
            detailRow(
                label: Text("Email & password sign-in"),
                value: vm.discoveredEmailPassword ? Text("Available") : Text("Not available")
            )
            detailRow(
                label: Text("QR sign-in from your phone"),
                value: vm.discoveredTvLogin ? Text("Available") : Text("Not available")
            )
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Content, not chrome: an opaque grouped surface instead of glass (spec gap 14).
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Only connect to a server you trust")
                .font(Theme.Font.meta)
                .foregroundStyle(.orange)
            warningBody
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("The server operator can receive your account credentials and access data you sync through this server.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )

        if let message = vm.switchFailureMessage {
            Text(message)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.warning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }

        HStack(spacing: Theme.Spacing.lg) {
            // Not `.disabled()` while switching (focus would jump); the press is a no-op instead.
            Button {
                if !vm.isSwitching { confirmingConnect = true }
            } label: {
                if vm.isSwitching {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                        Text("Switching\u{2026}")
                            .font(Theme.Font.body)
                    }
                    .frame(minWidth: 240)
                } else {
                    Text("Connect to This Server")
                        .font(Theme.Font.body)
                        .frame(minWidth: 240)
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("server.connect")
            .focused($focusTarget, equals: .connect)

            Button {
                if !vm.isSwitching { vm.resetDiscovery() }
            } label: {
                Text("Back")
                    .font(Theme.Font.body)
                    .frame(minWidth: 240)
            }
            .buttonStyle(.bordered)
            .focused($focusTarget, equals: .back)
        }
    }

    /// Android TV's four-way trust warning (public/private host × HTTP/HTTPS).
    private var warningBody: Text {
        if !vm.discoveredIsSecure && vm.discoveredIsPublicHost {
            return Text("This server uses a public hostname and unencrypted HTTP. Credentials and synced data may be exposed in transit.")
        } else if !vm.discoveredIsSecure {
            return Text("This server is on a private network, but HTTP traffic is not encrypted. Other devices on the network may be able to read it.")
        } else if vm.discoveredIsPublicHost {
            return Text("This server uses a public hostname. Nuvio cannot verify who owns or operates it.")
        } else {
            return Text("This appears to be a private-network server, but Nuvio still cannot verify who controls it.")
        }
    }

    private func detailRow(label: Text, value: Text, monospaced: Bool = false, valueIdentifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            label
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            value
                .font(monospaced ? Theme.Font.body.monospaced() : Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                // Identifier on the VALUE text only — on the row container it would propagate to
                // both texts and break `staticTexts["…"]` single-match queries in the harness.
                .accessibilityIdentifier(valueIdentifier ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
