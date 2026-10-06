import SwiftUI
import SharedCore

/// Add-ons manager. Paste a Stremio-compatible manifest URL (e.g. your TorBox or Torrentio addon URL
/// with your debrid key embedded) to install a streaming source, then manage installed addons.
///
/// Wave 2 (X3, decision D1): no longer a tab. It lives in Settings, so it is a system `List` like
/// the other Settings panes: standard rows with the white focus platter, section headers, and a
/// `ContentUnavailableView` when nothing is installed (VIS-14). No custom glass (spec gap 14).
///
/// `embedded: true` drops the screen's own `NavigationStack` for hosts that already provide one
/// (a Settings detail column, a pushed destination); the default keeps it self-contained.
struct AddonsView: View {
    var embedded: Bool = false

    var body: some View {
        if embedded {
            AddonsList()
        } else {
            NavigationStack {
                AddonsList()
            }
        }
    }
}

private struct AddonsList: View {
    @StateObject private var model = AddonsViewModel()
    @State private var newUrl = ""
    /// Addon pending a remove confirmation (drives the alert below).
    @State private var addonPendingRemoval: ManagedAddon?
    /// ADD-2: a locked row was pressed — explain it where the press happened (the notice at the
    /// top of the screen is off-screen once the list is scrolled).
    @State private var showsManagedByPrimaryNotice = false

    var body: some View {
        List {
            installSection
            installedSection
        }
        .navigationTitle("Add-ons")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(String(localized: "Managed by the main profile"), isPresented: $showsManagedByPrimaryNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.managedByPrimaryMessage)
        }
        .alert(
            "Remove \(addonPendingRemoval.map { model.displayName($0) } ?? "")?",
            isPresented: Binding(
                get: { addonPendingRemoval != nil },
                set: { if !$0 { addonPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let addon = addonPendingRemoval { model.remove(addon) }
                addonPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its catalogs and streams will no longer appear.")
        }
    }

    @ViewBuilder
    private var installSection: some View {
        if model.managedByPrimary {
            // ADD-2: the shared repository ignores every change on this profile — say so instead
            // of offering controls that silently do nothing. Rows below stay focusable so a long
            // list can still be scrolled.
            Section {
                Label {
                    Text(model.managedByPrimaryMessage)
                        .font(Theme.Font.body)
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .foregroundStyle(.secondary)
                if let status = model.statusMessage {
                    statusLabel(status)
                }
            }
        } else {
            Section {
                TextField("https://\u{2026}/manifest.json", text: $newUrl)
                    .font(Theme.Font.body)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit(install)

                Button(action: install) {
                    HStack(spacing: Theme.Spacing.md) {
                        Label("Install", systemImage: "plus.circle.fill")
                        Spacer(minLength: 0)
                        if model.isInstalling { ProgressView() }
                    }
                }
                .disabled(model.isInstalling || newUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                #if DEBUG
                if DebugConfig.hasManifestURL {
                    Button {
                        model.install(DebugConfig.manifestURL)
                    } label: {
                        Label("Quick install (from DebugConfig)", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(model.isInstalling)
                }
                #endif

                if let status = model.statusMessage {
                    statusLabel(status)
                }
            } header: {
                Text("Install from manifest URL")
            } footer: {
                Text("Paste the manifest URL from your streaming addon's config page (e.g. your TorBox or Torrentio URL with your API key). It ends in /manifest.json.")
            }
        }
    }

    /// ADD-3: the field is cleared only once the install succeeded, so a typo'd or unreachable URL
    /// can be fixed instead of retyped.
    private func install() {
        let submitted = newUrl
        guard !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isInstalling else { return }
        model.install(submitted) {
            if newUrl == submitted { newUrl = "" }
        }
    }

    private func statusLabel(_ status: String) -> some View {
        Label(status, systemImage: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .font(Theme.Font.caption)
            .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
    }

    private var installedSection: some View {
        Section {
            if model.addons.isEmpty {
                ContentUnavailableView {
                    Label(String(
                        localized: "addons.empty.title",
                        defaultValue: "No Add-ons",
                        comment: "Title shown in Settings › Add-ons when no add-on is installed"
                    ), systemImage: "puzzlepiece.extension")
                } description: {
                    Text(String(localized: "No addons installed yet.", defaultValue: "No add-ons installed yet.",
                                comment: "Description under the No Add-ons empty state"))
                }
                .frame(maxWidth: .infinity)
            }

            // ADD-3: identity by manifest URL (unique in the repository), not by position — a
            // removal or reorder no longer hands one row's state to its neighbour.
            ForEach(model.addons, id: \.manifestUrl) { addon in
                let errorMessage: String? = addon.errorMessage
                AddonRow(
                    title: model.displayName(addon),
                    subtitle: AddonsViewModel.maskedUrl(addon.manifestUrl),
                    enabled: addon.enabled,
                    isRefreshing: addon.isRefreshing,
                    errorMessage: addon.manifest == nil ? errorMessage : nil,
                    locked: model.managedByPrimary,
                    onToggle: {
                        if model.managedByPrimary {
                            showsManagedByPrimaryNotice = true
                        } else {
                            model.setEnabled(addon, !addon.enabled)
                        }
                    },
                    onRetry: { model.retry(addon) },
                    onRemove: { addonPendingRemoval = addon }
                )
            }
        } header: {
            Text("Installed")
        }
    }
}

/// A focusable add-on row. Select toggles enabled/disabled; long-press (context menu) removes.
/// A plain `Button` in a `List`, so the system draws the focus platter and inverts the labels.
/// State is a filled checkmark versus an empty circle plus the "Enabled"/"Disabled" text, never
/// colour alone.
private struct AddonRow: View {
    let title: String
    let subtitle: String
    let enabled: Bool
    /// ADD-3: manifest fetch in flight.
    var isRefreshing: Bool = false
    /// ADD-3: why the manifest failed to load (nil once it has loaded).
    var errorMessage: String? = nil
    /// ADD-2: the profile uses the main profile's add-ons — no toggle, no remove.
    var locked: Bool = false
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: errorMessage != nil ? "exclamationmark.triangle.fill" : (enabled ? "checkmark.circle.fill" : "circle"))
                    .font(Theme.Font.body)
                    .foregroundStyle(errorMessage != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.Font.body).lineLimit(1)
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let errorMessage {
                        Text(String(localized: "Couldn't load the manifest: \(errorMessage)"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if isRefreshing {
                    ProgressView()
                }
                if locked {
                    Image(systemName: "lock.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if errorMessage != nil {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            if !locked {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Add-on", systemImage: "trash")
                }
            }
        }
    }
}
