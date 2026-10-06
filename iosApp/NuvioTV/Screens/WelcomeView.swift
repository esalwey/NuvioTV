import SwiftUI

/// First-run / signed-out gate. QR sign-in (scan with the phone, approve, done) is the primary,
/// default-focused path — typing an email/password with the Siri Remote is painful, so we lead
/// with the option that needs no on-screen keyboard. Email sign-in, account creation, and guest
/// mode remain one Select-press away as clearly secondary options. Shown whenever
/// `AuthRepository` reports `Unauthenticated` — existing guest installs never see this (their
/// stored anonymous id authenticates immediately).
///
/// Self-hosted servers: a "Connect to a Server" action opens the discovery flow, and when the
/// active server doesn't advertise `tv_login` the email form becomes the primary (default-focused)
/// action instead of QR — the layout is otherwise unchanged for the official backend.
struct WelcomeView: View {
    @ObservedObject var model: AuthViewModel
    @StateObject private var server = ActiveServerObserver()

    private enum AuthSheet: String, Identifiable {
        case signIn, signUp, qr, server
        var id: String { rawValue }
    }

    @State private var sheet: AuthSheet?
    /// Anchors `.prefersDefaultFocus` so initial D-pad focus lands on the QR action below,
    /// regardless of layout order.
    @Namespace private var focusNamespace

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.sectionGap) {
                VStack(spacing: Theme.Spacing.lg) {
                    // Brand mark (the app icon's gradient triangle) instead of a text wordmark —
                    // same asset family as the icon/top-shelf art, so Welcome reads as the brand
                    // regardless of which accent theme the user later picks.
                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 130)
                        .accessibilityLabel("Nuvio")
                    if server.supportsTvLogin {
                        Text("Sign in with your phone — scan a QR code, no typing on the remote.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 900)
                    } else {
                        Text("Sign in with your email and password to get started.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 900)
                    }
                    if server.isCustom {
                        Text("Connected to \(server.displayHost)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }

                VStack(spacing: Theme.Spacing.xl) {
                    // Wave 2 (spec gap 14, §5.5): system buttons, no glass and no accent fill. The
                    // primary path is one large `.bordered` platter (white on focus, with the label
                    // inverted by the system — no hand-managed contrast, so the White-theme
                    // invisible-label class of BUG-14 cannot recur); the secondary paths are
                    // `.bordered` capsules.
                    if server.supportsTvLogin {
                        Button {
                            model.clearError()
                            sheet = .qr
                        } label: {
                            VStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "qrcode")
                                    .font(Theme.Font.hero)
                                Text("Sign In with Your Phone")
                                    .font(Theme.Font.sectionTitle)
                                Text("Scan a QR code to sign in — no typing required")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 640)
                            .padding(.vertical, Theme.Spacing.lg)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.panel))
                        .prefersDefaultFocus(true, in: focusNamespace)
                    } else {
                        // Self-hosted server without `tv_login`: email sign-in is the only
                        // account path, so it takes the primary slot and default focus.
                        Button {
                            model.clearError()
                            sheet = .signIn
                        } label: {
                            VStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "envelope")
                                    .font(Theme.Font.hero)
                                Text("Sign In with Email")
                                    .font(Theme.Font.sectionTitle)
                                Text("This server signs in with email and password")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 640)
                            .padding(.vertical, Theme.Spacing.lg)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.panel))
                        .prefersDefaultFocus(true, in: focusNamespace)
                    }

                    VStack(spacing: Theme.Spacing.md) {
                        Text("Or continue another way")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)

                        HStack(spacing: Theme.Spacing.md) {
                                // Both email routes require `email_password_auth` — discovery
                                // accepts QR-only servers (tv_login=true, email_password_auth=false),
                                // and offering email sign-in/sign-up against one would just fail.
                                if server.supportsTvLogin && server.supportsEmailPassword {
                                    Button {
                                        model.clearError()
                                        sheet = .signIn
                                    } label: {
                                        Text("Sign In with Email")
                                            .font(Theme.Font.meta)
                                            .padding(.horizontal, Theme.Spacing.lg)
                                            .padding(.vertical, Theme.Spacing.xs)
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                }

                                if server.supportsEmailPassword {
                                    Button {
                                        model.clearError()
                                        sheet = .signUp
                                    } label: {
                                        Text("Create Account")
                                            .font(Theme.Font.meta)
                                            .padding(.horizontal, Theme.Spacing.lg)
                                            .padding(.vertical, Theme.Spacing.xs)
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                }

                                Button {
                                    model.continueAsGuest()
                                } label: {
                                    Text("Continue as Guest")
                                        .font(Theme.Font.meta)
                                        .padding(.horizontal, Theme.Spacing.lg)
                                        .padding(.vertical, Theme.Spacing.xs)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)

                                Button {
                                    model.clearError()
                                    sheet = .server
                                } label: {
                                    if server.isCustom {
                                        Text("Server: \(server.displayHost)")
                                            .font(Theme.Font.meta)
                                            .padding(.horizontal, Theme.Spacing.lg)
                                            .padding(.vertical, Theme.Spacing.xs)
                                    } else {
                                        Text("Connect to a Server")
                                            .font(Theme.Font.meta)
                                            .padding(.horizontal, Theme.Spacing.lg)
                                            .padding(.vertical, Theme.Spacing.xs)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                }
                .focusScope(focusNamespace)
            }
            .padding(Theme.Spacing.screen)
        }
        .fullScreenCover(item: $sheet) { mode in
            switch mode {
            case .qr:
                QrSignInView()
            case .server:
                ServerConnectionView()
            case .signIn, .signUp:
                AuthView(model: model, isSignUp: mode == .signUp)
            }
        }
    }
}
