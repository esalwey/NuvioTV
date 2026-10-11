import Combine
import CoreImage
import Foundation
import SharedCore
import UIKit

/// Backs the Settings "MDBList" account card. Wraps the shared `MdbListAccountBridge`: `connect()`
/// asks MDBList for a device code — the bridge publishes it (plus the approval page address) and
/// polls in the background until the code is approved on another device or expires. The card shows
/// the code and a QR code of the approval page, so a phone can approve it without typing.
///
/// Once connected, MDBList is usable as a Library Source and Watch Progress Source (Content Sources
/// pane), supplies ratings without an API key, and is scrobbled to by both players through
/// `TrackingScrobbleCoordinator.scrobbleOtherTrackers` like every tracker but Trakt.
///
/// Same published shape as `TraktViewModel` / `SimklViewModel`, so the Settings pane renders the
/// three cards alike.
@MainActor
final class MdbListViewModel: ObservableObject {
    @Published private(set) var credentialsConfigured = true
    @Published private(set) var isConnected = false
    /// A code is being requested, or the account is being disconnected.
    @Published private(set) var isWorking = false
    @Published private(set) var username: String?
    @Published private(set) var isSupporter = false
    /// Non-nil while a device code waits for approval: drives the activation card.
    @Published private(set) var userCode: String?
    @Published private(set) var verificationUrl: String?
    /// QR code of the approval page with the code filled in.
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var errorMessage: String?
    /// Disconnected here, but MDBList did not confirm that the app's access was revoked.
    @Published private(set) var revokeFailed = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var syncErrorMessage: String?
    /// Every MDBList list that can be hidden from the library, with whether it shows.
    @Published private(set) var lists: [MdbListLibraryListOption] = []
    @Published private(set) var listErrorMessage: String?
    /// Visibility the user just asked for, until the shared lists catch up. Showing a hidden list
    /// downloads it first, so without this the switch would snap back and then flip.
    @Published private(set) var pendingListVisibility: [String: Bool] = [:]

    private var watcher: FlowWatcher?
    private var listsWatcher: FlowWatcher?
    private var renderedQrUrl: String?

    var isWaitingForApproval: Bool { userCode != nil }

    func start() {
        guard watcher == nil else { return }
        MdbListAccountBridge.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(MdbListAccountBridge.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? MdbListAccountUiState else { return }
            self.apply(state)
        }
        listsWatcher = FlowWatcherKt.watch(MdbListAccountBridge.shared.listOptions) { [weak self] emitted in
            guard let self, let options = emitted as? [MdbListLibraryListOption] else { return }
            self.lists = options
            // Drop the requests the lists now agree with.
            self.pendingListVisibility = self.pendingListVisibility.filter { key, visible in
                options.first(where: { $0.key == key })?.visible != visible
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        listsWatcher?.cancel()
        listsWatcher = nil
        // Note: a code that is waiting for approval keeps being polled inside the shared tracker
        // while Settings is closed, so leaving the screen does not abort the sign-in.
    }

    func connect() {
        MdbListAccountBridge.shared.connect()
    }

    func cancelActivation() {
        MdbListAccountBridge.shared.cancel()
    }

    func disconnect() {
        MdbListAccountBridge.shared.disconnect()
    }

    /// Pulls watched history, progress and lists now instead of waiting for the next automatic
    /// check. A press while a sync runs is ignored by the bridge.
    func syncNow() {
        MdbListAccountBridge.shared.syncNow()
    }

    func isListVisible(_ option: MdbListLibraryListOption) -> Bool {
        pendingListVisibility[option.key] ?? option.visible
    }

    func setListVisible(_ key: String, visible: Bool) {
        pendingListVisibility[key] = visible
        MdbListAccountBridge.shared.setListVisible(key: key, visible: visible)
    }

    // MARK: - State

    private func apply(_ state: MdbListAccountUiState) {
        credentialsConfigured = state.credentialsConfigured
        isConnected = state.isConnected
        isWorking = state.isWorking
        username = state.username
        isSupporter = state.isSupporter
        userCode = state.userCode
        verificationUrl = state.verificationUrl
        errorMessage = state.errorCode.map(Self.message(forErrorCode:))
        revokeFailed = state.revokeFailed
        isSyncing = state.isSyncing
        syncErrorMessage = state.syncErrorCode.map(Self.message(forErrorCode:))
        listErrorMessage = state.listErrorCode.map(Self.message(forErrorCode:))
        // A change that failed did not apply: show the real state again.
        if state.listErrorCode != nil { pendingListVisibility = [:] }
        if let epochMs = state.lastSyncedAtEpochMs {
            lastSyncedAt = Date(timeIntervalSince1970: epochMs.doubleValue / 1000)
        } else {
            lastSyncedAt = nil
        }
        renderQrIfNeeded(state.verificationUrlWithCode)
    }

    private func renderQrIfNeeded(_ url: String?) {
        guard let url, !url.isEmpty else {
            qrImage = nil
            renderedQrUrl = nil
            return
        }
        guard url != renderedQrUrl else { return }
        renderedQrUrl = url
        qrImage = Self.makeQrImage(from: url)
    }

    /// Codes are the ones in the shared `MdbListAccountErrorCodes`.
    private static func message(forErrorCode code: String) -> String {
        switch code {
        case "missing_client_id":
            return String(localized: "MDBList connection is unavailable in this build.")
        case "invalid_response":
            return String(localized: "MDBList returned an incomplete response. Please try again.")
        case "write_required":
            return String(localized: "MDBList did not grant permission to update watch history. Reconnect and allow write access.")
        case "code_expired":
            return String(localized: "This code has expired. Try again to get a new code.")
        case "access_denied":
            return String(localized: "Connection was declined. Try again to connect your account.")
        case "authorization_revoked":
            return String(localized: "Your MDBList connection has expired or been revoked. Connect again to resume syncing.")
        case "rate_limited":
            return String(localized: "MDBList\u{2019}s request limit has been reached. Syncing will resume after the limit resets.")
        default:
            return String(localized: "Could not sync with MDBList. Please try again.")
        }
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

    deinit {
        watcher?.cancel()
        listsWatcher?.cancel()
    }
}
