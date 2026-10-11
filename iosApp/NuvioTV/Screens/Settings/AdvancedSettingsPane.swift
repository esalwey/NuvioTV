import SwiftUI
import SharedCore

/// "Advanced" category content: startup behaviour, cache housekeeping and the Remote Setup LAN
/// config server. Remote Setup was extracted from SettingsView.swift (Phase 2 HIG revamp file
/// split) — logic and wiring preserved verbatim, only regrouped into a per-category pane.
struct AdvancedSettingsPane: View {
    @ObservedObject var remote: RemoteSetupViewModel
    @StateObject private var advanced = AdvancedSettingsViewModel()
    @State private var confirmingClearCache = false

    var body: some View {
        Group {
            SettingsSection(String(localized: "Startup")) {
                SettingsToggleRow(
                    title: String(localized: "Remember Last Profile"),
                    subtitle: String(localized: "Open straight into the profile you used last instead of asking who is watching. Profiles locked with a PIN always ask."),
                    isOn: Binding(
                        get: { advanced.rememberLastProfile },
                        set: { advanced.setRememberLastProfile($0) }
                    )
                )
            }

            SettingsSection(String(localized: "Cache")) {
                SettingsDestructiveRow(
                    title: String(localized: "Clear Continue Watching Cache"),
                    subtitle: advanced.cacheCleared
                        ? String(localized: "Cache cleared")
                        : String(localized: "Removes cached Continue Watching data and refreshes your watch progress. Your history is kept."),
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    confirmingClearCache = true
                }
                .alert(String(localized: "Clear Continue Watching Cache?"), isPresented: $confirmingClearCache) {
                    Button(String(localized: "Clear Cache"), role: .destructive) {
                        advanced.clearContinueWatchingCache()
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text("Continue Watching reloads its artwork and next episodes. Watch progress and history are not affected.")
                }
            }

            SettingsSection(String(localized: "Remote Setup")) {
                remoteSetupSection
            }
        }
        .onAppear { advanced.start() }
        .onDisappear { advanced.stop() }
    }

    /// The Remote Setup section body: start/stop the LAN config server and, while it runs, show
    /// the URL + QR a phone/laptop browser uses to manage add-ons, Home rows, API keys, and
    /// badge packs. Changes proposed from the browser surface as a confirm alert on SettingsView.
    @ViewBuilder
    private var remoteSetupSection: some View {
        Text("Manage add-ons, Home rows, API keys, and stream badge packs from a phone or laptop browser on the same network \u{2014} no on-screen keyboard. Changes only apply after you confirm them here.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        if let url = remote.serverURL {
            HStack(alignment: .top, spacing: 40) {
                if let qr = remote.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan the code, or open in any browser:")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(url)
                        .font(Theme.Font.screenTitle.monospaced())
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Keep this Settings screen open while you make changes.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            SettingsActionRow(
                title: String(localized: "Stop Remote Setup"),
                subtitle: String(localized: "Closes the local config page."),
                systemImage: "stop.circle"
            ) {
                remote.stop()
            }
        } else {
            SettingsActionRow(
                title: String(localized: "Start Remote Setup"),
                subtitle: remote.startFailed
                    ? String(localized: "Couldn't start the local server. Check the network connection and try again.")
                    : String(localized: "Starts a local config page on your network."),
                systemImage: "network"
            ) {
                remote.start()
            }
        }
    }
}
