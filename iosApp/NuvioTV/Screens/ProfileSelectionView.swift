import SwiftUI
import SharedCore

/// Profile avatar: renders the cloud avatar image (custom `avatarUrl` or catalog `avatarId`,
/// resolved via the shared `profileAvatarImageUrl`) when available, otherwise the colored circle
/// with the profile's initial (guest-mode / pre-cloud behavior).
struct ProfileAvatar: View {
    let profile: NuvioProfile
    var size: CGFloat = 170
    /// The avatar catalog (for `avatarId` lookups). Empty is fine — falls back to color+initial.
    var avatars: [AvatarCatalogItem] = []

    var body: some View {
        ZStack {
            if let url = imageUrl {
                CachedAsyncImage(string: url)
                    .clipShape(Circle())
            } else {
                Circle().fill(Color(hexString: profile.avatarColorHex) ?? Theme.Palette.accent)
                // A glyph drawn to the circle's size, not running text: like the Settings
                // illustration in spec §6.6, the one place a fixed size is right (it must track
                // the avatar's diameter, not the Text Size setting). The name under the avatar
                // carries the text and scales with Larger Text.
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .accessibilityHidden(true)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var imageUrl: String? {
        let catalogItem = avatars.first { $0.id == profile.avatarId }
        return ProfileModelsKt.profileAvatarImageUrl(profile: profile, avatar: catalogItem)
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }
}

/// The "Who's watching?" launch gate. Shows the profiles as a focusable row; selecting one enters
/// the app — PIN-locked profiles prompt for their 4-digit PIN first (as do edit/delete on them).
/// Long-press a profile to edit/delete; the trailing tile adds a new profile.
///
/// Wave 2 (spec §6.7, gap 16, VIS-13): modelled on the tvOS 26 system switcher. Large avatar
/// circles with the system highlight (lift, specular, gimbal), names under them, a lock glyph after
/// the name of a PIN profile, and no panels: no accent wash, no glass badges or hint capsule. Edit
/// and Delete stay in the long-press context menu; there is no separate edit mode.
struct ProfileSelectionView: View {
    @ObservedObject var model: ProfilesViewModel
    var onSelected: () -> Void
    /// Upstream 519510591 + 6761ebabb: set when the picker was opened from inside the app
    /// ("Switch Profile") rather than as the launch gate. Picking the profile the app is already
    /// running then goes straight back — no PIN, no fan-out, no cloud pull — and so does Menu.
    var onReturnToApp: (() -> Void)? = nil

    @State private var editing: ProfileEditTarget?
    @State private var pinPrompt: PinPrompt?
    /// PRF-1: profile awaiting the delete confirmation alert.
    @State private var profilePendingDeletion: NuvioProfile?

    /// Anchors `.prefersDefaultFocus` so initial D-pad focus lands on a profile tile (the first
    /// one at launch, the running one in Switch mode) instead of the Add-profile tile.
    @Namespace private var defaultFocusNamespace
    /// Profiles arrive asynchronously (`model.start()`), so at first render the row may contain
    /// only the Add tile and `.prefersDefaultFocus` settles on it. This nudges focus onto the
    /// first real profile once profiles land, one time only.
    @FocusState private var focusedProfile: Int32?
    @State private var didSeedDefaultFocus = false

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.sectionGap) {
                Text(String(localized: "Who\u{2019}s watching?", defaultValue: "Who\u{2019}s Watching?",
                            comment: "Title of the profile picker"))
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                // Max 6 profiles + Add tile fit on screen, so no ScrollView — a plain HStack
                // centers the row in the middle of the screen (a ScrollView would pin it left).
                // Spec §6.7: 260pt circles 60pt apart; a row of more than five steps down to
                // 200pt / 40pt so seven tiles still fit inside the 1760pt safe width.
                HStack(alignment: .top, spacing: tileSpacing) {
                        ForEach(model.profiles, id: \.profileIndex) { profile in
                            Button {
                                if let back = returnToApp, profile.profileIndex == model.sessionProfileIndex {
                                    back()
                                } else {
                                    requirePin(for: profile, action: .select)
                                }
                            } label: {
                                profileTile(
                                    name: profile.name,
                                    isPrimary: profile.profileIndex == 1,
                                    isLocked: profile.pinEnabled,
                                    width: avatarSize
                                ) {
                                    ProfileAvatar(profile: profile, size: avatarSize, avatars: model.avatars)
                                }
                            }
                            .buttonStyle(AvatarTileButtonStyle())
                            .buttonBorderShape(.circle)
                            .focused($focusedProfile, equals: profile.profileIndex)
                            .prefersDefaultFocus(
                                profile.profileIndex == preferredFocusIndex,
                                in: defaultFocusNamespace
                            )
                            .contextMenu {
                                Button {
                                    requirePin(for: profile, action: .edit)
                                } label: { Label("Edit Profile", systemImage: "pencil") }
                                // PRF-1: never the primary profile (upstream shows Delete only
                                // above index 1), and always behind a confirmation.
                                if Self.canDelete(profile, among: model.profiles) {
                                    Button(role: .destructive) {
                                        requirePin(for: profile, action: .delete)
                                    } label: { Label("Delete Profile", systemImage: "trash") }
                                }
                            }
                        }

                        if model.profiles.count < model.maxProfiles {
                            Button {
                                editing = ProfileEditTarget(profile: nil)
                            } label: {
                                profileTile(name: String(localized: "Add Profile"), width: avatarSize) {
                                    // Spec §6.7: a `plus` in a thin-material circle.
                                    ZStack {
                                        Circle().fill(.thinMaterial)
                                        Image(systemName: "plus")
                                            .font(Theme.Font.hero)
                                            .foregroundStyle(Theme.Palette.textPrimary)
                                    }
                                    .frame(width: avatarSize, height: avatarSize)
                                }
                            }
                            .buttonStyle(AvatarTileButtonStyle())
                            .buttonBorderShape(.circle)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.vertical, Theme.Spacing.lg)
                    .focusSection()
                    .focusScope(defaultFocusNamespace)

                Text(returnToApp == nil ? String(localized: "Hold to manage profile") : String(localized: "Hold to manage profile \u{00B7} Menu to go back"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .onAppear {
            model.start()
            seedSwitchModeFocus()
        }
        // Switch mode only: Menu returns to the running profile (6761ebabb's back button). Nil —
        // the launch gate, or the running profile was just deleted — keeps the system default.
        .onExitCommand(perform: returnToApp)
        .alert(
            "Delete \(profilePendingDeletion?.name ?? "")?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let profile = profilePendingDeletion { model.deleteProfile(profile) }
                profilePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its library, watch progress and settings will be removed. This can\u{2019}t be undone.")
        }
        .onChange(of: model.profiles.count) { oldCount, newCount in
            // One-shot: profiles land after initial focus may have already settled on Add, so
            // nudge focus onto the first real profile the moment they arrive (empty → non-empty).
            guard !didSeedDefaultFocus, oldCount == 0, newCount > 0 else { return }
            didSeedDefaultFocus = true
            let target = preferredFocusIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                focusedProfile = target
            }
        }
        .fullScreenCover(item: $editing) { target in
            ProfileEditView(model: model, target: target)
        }
        .fullScreenCover(item: $pinPrompt) { prompt in
            PinEntryView(
                title: String(localized: "Enter PIN for \(prompt.profile.name)"),
                subtitle: prompt.action == .select ? nil : String(localized: "This profile is locked."),
                onCancel: { pinPrompt = nil },
                onSubmit: { pin, done in
                    model.verifyPin(prompt.profile, pin: pin) { result in
                        if result?.unlocked == true {
                            pinPrompt = nil
                            perform(prompt.action, on: prompt.profile, afterPinCover: true)
                        } else {
                            done(pinErrorMessage(result))
                        }
                    }
                }
            )
        }
    }

    // MARK: - PIN gating

    private struct PinPrompt: Identifiable {
        enum Action { case select, edit, delete }
        let profile: NuvioProfile
        let action: Action
        var id: String { "\(profile.profileIndex)-\(action)" }
    }

    private func requirePin(for profile: NuvioProfile, action: PinPrompt.Action) {
        if profile.pinEnabled {
            pinPrompt = PinPrompt(profile: profile, action: action)
        } else {
            perform(action, on: profile)
        }
    }

    private func perform(_ action: PinPrompt.Action, on profile: NuvioProfile, afterPinCover: Bool = false) {
        switch action {
        case .select:
            model.select(profile)
            onSelected()
        case .edit:
            editing = ProfileEditTarget(profile: profile)
        case .delete:
            // PRF-1: confirm before deleting. Straight after the PIN cover, wait for it to finish
            // going away — an alert requested while a full-screen cover is dismissing is dropped.
            if afterPinCover {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { profilePendingDeletion = profile }
            } else {
                profilePendingDeletion = profile
            }
        }
    }

    // MARK: - Initial focus

    /// F17: "Switch Profile" opens on the profile the app is running (the one you would most
    /// likely keep), not on the first tile. The launch gate keeps the first profile.
    private var preferredFocusIndex: Int32? {
        if onReturnToApp != nil,
           let current = model.sessionProfileIndex ?? model.activeProfile?.profileIndex,
           model.profiles.contains(where: { $0.profileIndex == current }) {
            return current
        }
        return model.profiles.first?.profileIndex
    }

    /// In Switch mode the profiles are already loaded when the picker mounts, so the
    /// empty-to-loaded nudge never runs. `.prefersDefaultFocus` alone is not reliable on a freshly
    /// presented screen, so focus the running profile once here as well.
    private func seedSwitchModeFocus() {
        guard onReturnToApp != nil, !didSeedDefaultFocus, !model.profiles.isEmpty,
              let target = preferredFocusIndex else { return }
        didSeedDefaultFocus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            focusedProfile = target
        }
    }

    /// Switch mode's way back, offered only while the app still runs a profile that exists.
    private var returnToApp: (() -> Void)? {
        guard let onReturnToApp, model.canResumeSessionProfile() else { return nil }
        return onReturnToApp
    }

    /// PRF-1: the primary profile (index 1) is never deletable, nor the last remaining profile.
    static func canDelete(_ profile: NuvioProfile, among profiles: [NuvioProfile]) -> Bool {
        profile.profileIndex > 1 && profiles.count > 1
    }

    /// Tiles in the row, the Add tile included.
    private var tileCount: Int {
        model.profiles.count + (model.profiles.count < model.maxProfiles ? 1 : 0)
    }

    /// Spec §6.7: 260pt avatars, or 200pt once the row holds more than five tiles.
    private var avatarSize: CGFloat { tileCount > 5 ? 200 : 260 }
    private var tileSpacing: CGFloat { tileCount > 5 ? Theme.Spacing.xl : 60 }

    private func profileTile<Content: View>(
        name: String,
        isPrimary: Bool = false,
        isLocked: Bool = false,
        width: CGFloat,
        @ViewBuilder avatar: () -> Content
    ) -> some View {
        ProfileTileLabel(name: name, isPrimary: isPrimary, isLocked: isLocked, width: width, avatar: avatar)
    }
}

/// One tile of the picker: the avatar circle with the system highlight, then the name in Callout
/// (`.secondary` until focused) with a lock glyph after it for a PIN profile, and a small
/// "Primary" caption under the main profile. `@Environment(\.isFocused)` reflects the enclosing
/// Button's focus.
private struct ProfileTileLabel<Content: View>: View {
    let name: String
    var isPrimary: Bool = false
    var isLocked: Bool = false
    let width: CGFloat
    let avatar: Content

    @Environment(\.isFocused) private var isFocused

    init(name: String, isPrimary: Bool = false, isLocked: Bool = false, width: CGFloat,
         @ViewBuilder avatar: () -> Content) {
        self.name = name
        self.isPrimary = isPrimary
        self.isLocked = isLocked
        self.width = width
        self.avatar = avatar()
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Spec §3.2: the avatar is a custom view (an image, or a coloured circle with an
            // initial), so the system highlight is attached to exactly that subview and shaped to
            // the circle. No custom scale or glow on top of it.
            avatar
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
            HStack(spacing: Theme.Spacing.xs) {
                Text(name)
                    .font(Theme.Font.sectionTitle)
                    .lineLimit(1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(Theme.Font.caption)
                        .accessibilityLabel(Text(String(
                            localized: "profile.locked.accessibility", defaultValue: "PIN locked",
                            comment: "VoiceOver label of the lock glyph after a PIN-protected profile's name")))
                }
            }
            .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .frame(maxWidth: width)
            if isPrimary {
                Text(String(localized: "profile.primary.caption", defaultValue: "Primary",
                            comment: "Caption under the main profile in the Who's watching? picker"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// Formats a failed `PinVerifyResult` for display (server message, lockout countdown, or default).
func pinErrorMessage(_ result: PinVerifyResult?) -> String {
    if let message = result?.message, !message.isEmpty { return message }
    if let retry = result?.retryAfterSeconds, retry > 0 {
        return String(localized: "Too many attempts. Try again in \(retry)s.")
    }
    return String(localized: "Incorrect PIN. Try again.")
}

/// Identifiable wrapper so add (nil) / edit (existing) can drive `.fullScreenCover(item:)`.
struct ProfileEditTarget: Identifiable {
    let profile: NuvioProfile?
    var id: Int { profile.map { Int($0.profileIndex) } ?? -1 }
}

/// Add / edit form: name, avatar (cloud catalog picker when available, else color palette), and —
/// for cloud accounts editing an existing profile — the PIN lock (set / change / remove).
struct ProfileEditView: View {
    @ObservedObject var model: ProfilesViewModel
    let target: ProfileEditTarget

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var avatarId: String?
    @State private var pinFlow: PinFlow?
    /// PRF-1: drives the delete confirmation.
    @State private var confirmingDelete = false
    /// STAB-09: the save push failed; the editor stays open with an alert.
    @State private var saveFailed = false

    /// A custom avatar URL set elsewhere (e.g. on mobile); preserved unless a catalog avatar or
    /// the color tile is picked here.
    private let originalCustomAvatarUrl: String?

    private let palette = [
        "#E53935", "#1E88E5", "#8E24AA", "#43A047",
        "#FB8C00", "#D81B60", "#00ACC1", "#5E35B1",
    ]

    init(model: ProfilesViewModel, target: ProfileEditTarget) {
        self.model = model
        self.target = target
        _name = State(initialValue: target.profile?.name ?? "")
        _colorHex = State(initialValue: target.profile?.avatarColorHex ?? "#E53935")
        _avatarId = State(initialValue: target.profile?.avatarId)
        originalCustomAvatarUrl = target.profile?.avatarId == nil ? target.profile?.avatarUrl : nil
    }

    /// Live copy of the profile being edited (PIN state refreshes after set/clear → pullProfiles).
    private var liveProfile: NuvioProfile? {
        guard let index = target.profile?.profileIndex else { return nil }
        return model.profiles.first { $0.profileIndex == index }
    }

    private var selectedCatalogItem: AvatarCatalogItem? {
        model.avatars.first { $0.id == avatarId }
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Theme.Spacing.xl) {
                    Text(target.profile == nil ? String(localized: "Add Profile") : String(localized: "Edit Profile"))
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    // Preview
                    ZStack {
                        if let item = selectedCatalogItem {
                            CachedAsyncImage(string: ProfileModelsKt.avatarStorageUrl(storagePath: item.storagePath))
                                .clipShape(Circle())
                        } else if let url = originalCustomAvatarUrl, avatarId == nil {
                            CachedAsyncImage(string: url)
                                .clipShape(Circle())
                        } else {
                            Circle().fill(Color(hexString: colorHex) ?? Theme.Palette.accent)
                            Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                                .font(Theme.Font.hero)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 150, height: 150)

                    // Spec gap 14: the system text field draws its own platter; no glass.
                    TextField("Name", text: $name)
                        .font(Theme.Font.body)
                        .frame(maxWidth: 700)

                    // Cloud avatar catalog (hidden when empty — guest mode / offline).
                    if !model.avatars.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.lg) {
                                // "Color" tile — clears the catalog avatar.
                                Button { avatarId = nil } label: {
                                    ZStack {
                                        Circle().fill(Color(hexString: colorHex) ?? Theme.Palette.accent)
                                        Image(systemName: "paintpalette")
                                            .font(Theme.Font.body)
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 100, height: 100)
                                    .overlay(
                                        Circle().strokeBorder(
                                            Theme.Palette.textPrimary,
                                            lineWidth: avatarId == nil ? 5 : 0
                                        )
                                    )
                                    .modifier(FocusRingCircle())
                                }
                                .buttonStyle(AvatarTileButtonStyle())
                                .accessibilityLabel(String(localized: "Use color avatar"))

                                ForEach(model.avatars, id: \.id) { item in
                                    Button { avatarId = item.id } label: {
                                        CachedAsyncImage(string: ProfileModelsKt.avatarStorageUrl(storagePath: item.storagePath))
                                            .frame(width: 100, height: 100)
                                            .clipShape(Circle())
                                            .overlay(
                                                Circle().strokeBorder(
                                                    Theme.Palette.textPrimary,
                                                    lineWidth: avatarId == item.id ? 5 : 0
                                                )
                                            )
                                            .modifier(FocusRingCircle())
                                    }
                                    .buttonStyle(AvatarTileButtonStyle())
                                    .accessibilityLabel(
                                        item.displayName.isEmpty
                                            ? String(localized: "Avatar")
                                            : item.displayName
                                    )
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                    }

                    // Color palette (used when no catalog avatar is selected).
                    HStack(spacing: Theme.Spacing.lg) {
                        ForEach(palette, id: \.self) { hex in
                            Button {
                                colorHex = hex
                                avatarId = nil
                            } label: {
                                Circle()
                                    .fill(Color(hexString: hex) ?? .gray)
                                    .frame(width: 70, height: 70)
                                    .overlay(
                                        Circle().strokeBorder(
                                            Theme.Palette.textPrimary,
                                            lineWidth: (hex == colorHex && avatarId == nil) ? 5 : 0
                                        )
                                    )
                                    .modifier(FocusRingCircle())
                            }
                            .buttonStyle(AvatarTileButtonStyle())
                        }
                    }

                    // PIN lock — existing profiles on cloud accounts only (RPCs need a session).
                    if let profile = liveProfile, model.isCloudAccount {
                        HStack(spacing: Theme.Spacing.lg) {
                            if profile.pinEnabled {
                                Button {
                                    pinFlow = .enterCurrent(remove: false)
                                } label: {
                                    Label("Change PIN", systemImage: "lock.rotation")
                                        .font(Theme.Font.body)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)

                                Button(role: .destructive) {
                                    pinFlow = .enterCurrent(remove: true)
                                } label: {
                                    Label("Remove PIN", systemImage: "lock.slash")
                                        .font(Theme.Font.body)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                            } else {
                                Button {
                                    pinFlow = .enterNew(current: nil)
                                } label: {
                                    Label("Set PIN Lock", systemImage: "lock")
                                        .font(Theme.Font.body)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                            }
                        }
                    }

                    // System bordered button, no brand fill (spec §5.5: the accent is not a
                    // button colour).
                    Button { save() } label: {
                        Text("Save")
                            .font(Theme.Font.body)
                            .frame(minWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)

                    if let profile = target.profile, ProfileSelectionView.canDelete(profile, among: model.profiles) {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                                .font(Theme.Font.body)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(Theme.Spacing.screen)
            }
        }
        .fullScreenCover(item: $pinFlow) { flow in
            pinFlowView(flow)
        }
        .alert("Delete \(target.profile?.name ?? "")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let profile = target.profile { model.deleteProfile(profile) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its library, watch progress and settings will be removed. This can\u{2019}t be undone.")
        }
        .alert(
            String(localized: "profile.saveFailed.title", defaultValue: "Couldn\u{2019}t Save Profile",
                   comment: "Alert title when a profile edit or a new profile could not be saved to the account"),
            isPresented: $saveFailed
        ) {
            Button(String(localized: "profile.saveFailed.ok", defaultValue: "OK",
                          comment: "Dismisses the alert shown when a profile could not be saved"),
                   role: .cancel) {}
        } message: {
            Text(String(localized: "profile.saveFailed.message",
                        defaultValue: "Your changes weren\u{2019}t saved. Check your connection and try again.",
                        comment: "Alert message when a profile edit or a new profile could not be saved to the account"))
        }
    }

    // MARK: - PIN flows

    private enum PinFlow: Identifiable {
        /// Verify the current PIN, then either remove the lock or continue to a new PIN.
        case enterCurrent(remove: Bool)
        /// Set a new PIN (with the verified current PIN when changing).
        case enterNew(current: String?)

        var id: String {
            switch self {
            case .enterCurrent(let remove): return "current-\(remove)"
            case .enterNew(let current): return "new-\(current ?? "none")"
            }
        }
    }

    @ViewBuilder
    private func pinFlowView(_ flow: PinFlow) -> some View {
        switch flow {
        case .enterCurrent(let remove):
            PinEntryView(
                title: String(localized: "Enter current PIN"),
                subtitle: remove ? String(localized: "Confirm the PIN to remove the lock.") : String(localized: "Confirm the PIN before choosing a new one."),
                onCancel: { pinFlow = nil },
                onSubmit: { pin, done in
                    guard let profile = liveProfile else { pinFlow = nil; return }
                    if remove {
                        model.clearPin(profileIndex: profile.profileIndex, currentPin: pin) { result in
                            if result?.unlocked == true {
                                pinFlow = nil
                            } else {
                                done(pinErrorMessage(result))
                            }
                        }
                    } else {
                        model.verifyPin(profile, pin: pin) { result in
                            if result?.unlocked == true {
                                pinFlow = .enterNew(current: pin)
                            } else {
                                done(pinErrorMessage(result))
                            }
                        }
                    }
                }
            )
        case .enterNew(let current):
            PinEntryView(
                title: String(localized: "Choose a 4-digit PIN"),
                subtitle: String(localized: "This profile will require the PIN to open."),
                onCancel: { pinFlow = nil },
                onSubmit: { pin, done in
                    guard let profile = liveProfile else { pinFlow = nil; return }
                    model.setPin(profileIndex: profile.profileIndex, pin: pin, currentPin: current) { result in
                        if result?.unlocked == true {
                            pinFlow = nil
                        } else {
                            done(pinErrorMessage(result))
                        }
                    }
                }
            )
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? String(localized: "Profile") : trimmed

        // Catalog avatar → store BOTH id and resolved URL (cross-device renderable without a
        // catalog lookup). Color tile → clear both. Untouched custom URL → preserve it.
        let finalAvatarUrl: String?
        if let item = selectedCatalogItem {
            finalAvatarUrl = ProfileModelsKt.avatarStorageUrl(storagePath: item.storagePath)
        } else {
            finalAvatarUrl = originalCustomAvatarUrl
        }

        if let profile = target.profile {
            model.updateProfile(
                profile,
                name: finalName,
                colorHex: colorHex,
                avatarId: avatarId,
                avatarUrl: finalAvatarUrl
            ) { saved in
                if saved { dismiss() } else { saveFailed = true }
            }
        } else {
            model.createProfile(
                name: finalName,
                colorHex: colorHex,
                avatarId: avatarId,
                avatarUrl: finalAvatarUrl
            ) { saved in
                if saved { dismiss() } else { saveFailed = true }
            }
        }
    }
}

/// Focus visuals for the circular avatar/color tiles in the profile editor: exactly one system
/// highlight, shaped to the circle (spec §3.2). Selection keeps its separate white ring.
private struct FocusRingCircle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
    }
}

/// Button style for the avatar tiles (picker and editor). `.borderless` attaches its highlight to
/// the FIRST `Image` in the label, which for these tiles is the wrong subview (the `lock.fill`
/// after a PIN profile's name, the `plus` / `paintpalette` glyph inside a circle) or stacks with
/// the avatar's own highlight. A custom style gets no system focus effect, so the single
/// `.hoverEffect(.highlight)` the label puts on its circle is the only one.
private struct AvatarTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
