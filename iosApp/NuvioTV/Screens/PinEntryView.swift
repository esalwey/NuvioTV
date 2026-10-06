import SwiftUI
import TVUIKit

/// Full-screen 4-digit PIN entry.
///
/// The parent owns what "submit" means: `onSubmit` receives the 4-digit PIN and a completion
/// callback — pass an error message to show it (and reset the entry), or `nil` on success (the
/// parent is expected to dismiss this view).
///
/// Wave 2 (spec §6.7, gap 16): the default is the system digit-entry screen
/// (`TVDigitEntryViewController`, HIG Digit entry views), the same one tvOS uses for its own
/// passcodes: four secure boxes, the system linear digit row, dictation-free, no app chrome. The
/// app-drawn pad stays as a fallback for one release, selectable from Developer › Fallbacks or with
/// the launch argument `-debug.pinLegacyPad YES`, in case the system controller misbehaves inside
/// a SwiftUI full-screen cover on hardware.
///
/// Menu: every caller presents this in a `.fullScreenCover(item:)`, so Menu dismisses the cover and
/// clears its item, which is the cancel path. `.onExitCommand` also routes Menu to `onCancel` for
/// the case where the digit controller lets the press bubble up to SwiftUI.
struct PinEntryView: View {
    let title: String
    var subtitle: String? = nil
    let onCancel: () -> Void
    let onSubmit: (String, @escaping (String?) -> Void) -> Void

    @AppStorage(PinEntryView.legacyPadKey) private var usesLegacyPad = false

    /// UserDefaults key of the fallback switch (Developer › Fallbacks, or a launch argument).
    nonisolated static let legacyPadKey = "debug.pinLegacyPad"

    var body: some View {
        if usesLegacyPad {
            LegacyPinPad(title: title, subtitle: subtitle, onCancel: onCancel, onSubmit: onSubmit)
        } else {
            SystemDigitEntry(title: title, prompt: subtitle, onSubmit: onSubmit)
                .ignoresSafeArea()
                .onExitCommand(perform: onCancel)
        }
    }
}

// MARK: - System digit entry

/// `TVDigitEntryViewController` hosted in SwiftUI. Four secure digits; a wrong PIN shows the
/// caller's message as the prompt and clears the boxes so the next attempt starts at the first
/// digit (the system keeps focus on its own digit row throughout, which is what F12 was after).
private struct SystemDigitEntry: UIViewControllerRepresentable {
    let title: String
    let prompt: String?
    let onSubmit: (String, @escaping (String?) -> Void) -> Void

    final class Coordinator {
        /// True while the parent verifies a PIN; a second completion in that window is ignored.
        var isVerifying = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> TVDigitEntryViewController {
        let controller = TVDigitEntryViewController()
        controller.numberOfDigits = 4
        controller.isSecureDigitEntry = true
        controller.titleText = title
        controller.promptText = prompt
        let coordinator = context.coordinator
        let submit = onSubmit
        controller.entryCompletionHandler = { [weak controller] entered in
            // Written so it compiles whether the SDK hands the string over optional or not.
            let value: String? = entered
            guard let pin = value, pin.count == 4, !coordinator.isVerifying else { return }
            coordinator.isVerifying = true
            submit(pin) { error in
                coordinator.isVerifying = false
                guard let error, let controller else { return }
                controller.promptText = error
                controller.clearEntry(animated: true)
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: TVDigitEntryViewController, context: Context) {
        if controller.titleText != title { controller.titleText = title }
    }
}

// MARK: - Fallback pad

/// The pre-Wave-2 pad (dots plus a 3×4 key grid), restyled to system controls: no glass panel
/// (spec gap 14), `.bordered` keys with the white focus platter, white dots instead of the accent.
private struct LegacyPinPad: View {
    let title: String
    let subtitle: String?
    let onCancel: () -> Void
    let onSubmit: (String, @escaping (String?) -> Void) -> Void

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isBusy = false
    /// F12: the focused pad key. Keys stay enabled while a PIN is being verified (a disabled key
    /// gives its focus up, and with every key disabled tvOS had nothing left to focus), so the
    /// key you pressed keeps focus through the check and after a wrong PIN.
    @FocusState private var focusedKey: String?
    @State private var lastPressedKey: String?

    private let padRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["delete", "0", "cancel"],
    ]

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Text(title)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                }

                // PIN dots: filled = entered. Shape and fill, never colour alone.
                HStack(spacing: Theme.Spacing.lg) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < pin.count ? Theme.Palette.textPrimary : Color.clear)
                            .overlay(
                                Circle().strokeBorder(Theme.Palette.textSecondary, lineWidth: 3)
                            )
                            .frame(width: 28, height: 28)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(
                    localized: "pin.progress.accessibility",
                    defaultValue: "\(pin.count) of 4 digits entered",
                    comment: "VoiceOver label of the PIN dots; the argument is how many digits have been typed")))

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.warning)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                } else if isBusy {
                    ProgressView()
                }

                VStack(spacing: Theme.Spacing.md) {
                    ForEach(padRows, id: \.self) { row in
                        HStack(spacing: Theme.Spacing.md) {
                            ForEach(row, id: \.self) { key in
                                padButton(key)
                            }
                        }
                    }
                }
                .opacity(isBusy ? 0.6 : 1)
                .focusSection()
            }
            .padding(Theme.Spacing.screen)
        }
    }

    @ViewBuilder
    private func padButton(_ key: String) -> some View {
        switch key {
        case "delete":
            Button {
                guard !isBusy else { return }
                lastPressedKey = key
                errorMessage = nil
                if !pin.isEmpty { pin.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .frame(width: 90, height: 60)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(String(
                localized: "pin.delete.accessibility", defaultValue: "Delete",
                comment: "VoiceOver label of the PIN pad key that deletes the last digit")))
            .focused($focusedKey, equals: key)
        case "cancel":
            Button {
                guard !isBusy else { return }
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 90, height: 60)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Cancel"))
            .focused($focusedKey, equals: key)
        default:
            Button {
                appendDigit(key)
            } label: {
                Text(key)
                    .font(Theme.Font.sectionTitle)
                    .monospacedDigit()
                    .frame(width: 90, height: 60)
            }
            .buttonStyle(.bordered)
            .focused($focusedKey, equals: key)
        }
    }

    private func appendDigit(_ digit: String) {
        guard !isBusy, pin.count < 4 else { return }
        lastPressedKey = digit
        errorMessage = nil
        pin += digit
        guard pin.count == 4 else { return }

        // Auto-submit at 4 digits (mirrors mobile).
        isBusy = true
        let entered = pin
        onSubmit(entered) { error in
            isBusy = false
            if let error {
                errorMessage = error
                pin = ""
                // F12: keep the remote on the pad. If focus drifted anyway, put it back on the
                // key that submitted the PIN.
                if focusedKey == nil {
                    focusedKey = lastPressedKey ?? "1"
                }
            }
            // nil = success; the parent dismisses this view.
        }
    }
}
