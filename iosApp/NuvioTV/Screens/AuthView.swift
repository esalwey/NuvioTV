import SwiftUI

/// Email/password form for signing in to (or creating) a Nuvio account. tvOS text entry uses the
/// system full-screen keyboard. Success is observed via `AuthRepository.state` (the cover is torn
/// down when the root gate flips to `.main`), so this view only handles input, busy, and errors.
struct AuthView: View {
    @ObservedObject var model: AuthViewModel
    let isSignUp: Bool
    /// Active server — a self-hosted host is named under the title so it's clear where the
    /// credentials go.
    @StateObject private var server = ActiveServerObserver()

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    private var canSubmit: Bool {
        !model.isBusy &&
            email.contains("@") &&
            password.count >= 6
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Text(isSignUp ? String(localized: "Create your Nuvio account") : String(localized: "Sign in to Nuvio"))
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if server.isCustom {
                    Text("on \(server.displayHost)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                // Spec gap 14: no glass on a form. The system text field draws its own platter
                // and focus treatment, the way the tvOS Settings sign-in screens look.
                VStack(spacing: Theme.Spacing.lg) {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(Theme.Font.body)

                    SecureField("Password", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                        .font(Theme.Font.body)
                }
                .frame(maxWidth: 800)

                if let error = model.errorMessage {
                    Text(error)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.warning)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                }

                if isSignUp && password.count > 0 && password.count < 6 {
                    Text("Password must be at least 6 characters.")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                HStack(spacing: Theme.Spacing.lg) {
                    // System bordered buttons (white platter on focus), no brand fill: the accent
                    // is reserved for progress and selection marks (spec §2.6, §5.5).
                    Button {
                        submit()
                    } label: {
                        if model.isBusy {
                            ProgressView()
                                .frame(minWidth: 240)
                        } else {
                            Text(isSignUp ? String(localized: "Create Account") : String(localized: "Sign In"))
                                .font(Theme.Font.body)
                                .frame(minWidth: 240)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canSubmit)

                    Button {
                        model.clearError()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(Theme.Font.body)
                            .frame(minWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            }
            .padding(Theme.Spacing.screen)
        }
    }

    private func submit() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        if isSignUp {
            model.signUp(email: trimmedEmail, password: password)
        } else {
            model.signIn(email: trimmedEmail, password: password)
        }
    }
}
