import Combine
import CoreImage
import SwiftUI
import UIKit
import SharedCore

/// QR sign-in: the shared `TvLoginRepository` runs the whole flow (anonymous scaffolding session →
/// `start_tv_login_session` → poll → `tv-logins-exchange` token import); this screen just renders
/// its `uiState` — a QR of the approval URL plus the short code as a manual fallback. When the
/// exchange completes, `AuthRepository`'s session collector publishes the real account and the
/// observing `AuthViewModel` swaps the app past the Welcome gate; we also dismiss on `completed`.
@MainActor
final class QrSignInViewModel: ObservableObject {
    @Published private(set) var state: TvLoginUiState?
    /// Rendered QR for the current webUrl (regenerated only when the URL changes).
    @Published private(set) var qrImage: UIImage?

    private var watcher: FlowWatcher?
    private var renderedUrl: String?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(TvLoginRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? TvLoginUiState else { return }
            self.state = value
            self.renderQrIfNeeded(value)
        }
        TvLoginRepository.shared.startFlow(deviceName: "Apple TV")
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        TvLoginRepository.shared.cancel()
    }

    func retry() {
        TvLoginRepository.shared.cancel()
        TvLoginRepository.shared.startFlow(deviceName: "Apple TV")
    }

    private func renderQrIfNeeded(_ state: TvLoginUiState) {
        let url: String? = state.webUrl
        guard let url, !url.isEmpty else {
            qrImage = nil
            renderedUrl = nil
            return
        }
        guard url != renderedUrl else { return }
        renderedUrl = url
        qrImage = Self.makeQrImage(from: url)
    }

    private static func makeQrImage(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // The raw QR is ~30pt; scale it up sharply (nearest-neighbor via affine transform).
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    deinit { watcher?.cancel() }
}

struct QrSignInView: View {
    @StateObject private var model = QrSignInViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            HStack(spacing: Theme.Spacing.sectionGap) {
                qrPanel
                instructions
            }
            .padding(Theme.Spacing.screen)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.state?.completed ?? false) { _, completed in
            // Session imported — the auth collector flips the app past Welcome; close this cover.
            if completed { dismiss() }
        }
    }

    @ViewBuilder
    private var qrPanel: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let image = model.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 420, height: 420)
                    .padding(Theme.Spacing.lg)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Surface.panel)
                        .frame(width: 460, height: 460)
                    if unsupportedByServer {
                        Image(systemName: "qrcode")
                            .font(Theme.Font.hero)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var instructions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Sign In with Your Phone")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            if unsupportedByServer {
                // Self-hosted server without the `tv_login` capability: nothing to retry — point
                // the user at the email form instead (the Welcome screen already leads with it).
                Text("QR sign-in isn\u{2019}t available on this server. Use email and password instead.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 700, alignment: .leading)
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            } else if let error = errorMessage {
                Text(error)
                    .font(Theme.Font.body)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 700, alignment: .leading)
                Button {
                    model.retry()
                } label: {
                    // Wave 2 (gap 14): system bordered button with no accent fill, matching
                    // Welcome / Auth. That also retires the BUG-14 White-theme contrast fix.
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.bordered)
            } else {
                Text("Scan the QR code with your phone's camera and approve the sign-in — no typing on the TV.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 700, alignment: .leading)

                if let code = shortCode {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(String(localized: "Or go to \(approvalHostPath) and enter:"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        // The backend's pairing code is a long hex string (not a short human
                        // code); chunk it into groups of 4 so it's readable/typeable on a phone
                        // instead of one unbroken 32-character run.
                        Text(Self.groupedForDisplay(code))
                            .font(Theme.Font.sectionTitle.monospaced())
                            .kerning(4)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: 700, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text(statusLine)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            if !unsupportedByServer {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .frame(maxWidth: 800, alignment: .leading)
    }

    /// True when the active (self-hosted) server doesn't advertise `tv_login` — the repo
    /// publishes this instead of starting a flow, so there is nothing to retry.
    private var unsupportedByServer: Bool {
        guard let state = model.state else { return false }
        let unsupported: Bool = state.unsupportedByServer
        return unsupported
    }

    /// "host/path" of the approval page for the manual-entry hint (e.g. `nuvio.tv/tv-login`, or
    /// `backend.example.com/tv-login` on a self-hosted server). Prefers the live `webUrl` from
    /// the flow (query stripped); before the flow has started, derives it from the active
    /// server's TV-login base URL.
    private var approvalHostPath: String {
        let webUrl: String? = model.state?.webUrl
        if let webUrl, let fromFlow = Self.hostPath(from: webUrl) {
            return fromFlow
        }
        if let active = ServerConfigurationRepository.shared.active.value_ as? ServerConfiguration,
           let fromConfig = Self.hostPath(from: active.tvLoginWebBaseUrl) {
            return fromConfig
        }
        return Self.hostPath(from: ServerConfigurationKt.OFFICIAL_TV_LOGIN_WEB_BASE_URL) ?? "nuvio.tv/tv-login"
    }

    /// `host[:port]` + path (no scheme, no query/fragment, no trailing slash).
    private static func hostPath(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host, !host.isEmpty else { return nil }
        var result = host
        if let port = components.port { result += ":\(port)" }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        return result + path
    }

    private var errorMessage: String? {
        let message: String? = model.state?.errorMessage
        return message
    }

    private var shortCode: String? {
        let code: String? = model.state?.code
        return code
    }

    /// Groups a long pairing code into 4-character chunks (e.g. `AB12 CD34 EF56 ...`) so it's
    /// readable and easier to type on a phone. A no-op for codes already short enough to display
    /// as-is (kept simple rather than guessing at a length threshold).
    private static func groupedForDisplay(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { offset -> String in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[start..<end])
        }.joined(separator: " ")
    }

    private var statusLine: String {
        let status: String? = model.state?.status
        switch status {
        case "approved": return String(localized: "Approved \u{2014} finishing sign-in\u{2026}")
        case "pending": return String(localized: "Waiting for approval\u{2026} this screen updates automatically.")
        default: return String(localized: "Preparing sign-in\u{2026}")
        }
    }
}
