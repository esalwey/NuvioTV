import Combine
import SwiftUI
import SharedCore

/// Account-less linking ("sync code") for a signed-in account: pick a PIN (4 to 8 characters),
/// generate a code, and enter code + PIN on the other device to link it (the Android TV app's
/// flow). Also lists the devices already linked and lets the owner unlink them.
///
/// Reached from Account & Services only for a real account on the official server. Claiming a
/// code on this Apple TV is deliberately not offered, see `SyncCodeRepository`.
struct SyncCodeSettingsPage: View {
    @StateObject private var model = SyncCodeViewModel()
    @State private var pin = ""
    @State private var deviceToUnlink: LinkedDevice?

    var body: some View {
        List {
            SettingsSection(
                String(localized: "Sync Code"),
                footer: String(localized: "On the other device, choose Sync Code, then enter this code and your PIN. The PIN protects the code, so choose one only you know.")
            ) {
                if let code = model.code {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Your Sync Code")
                            .font(SettingsRowFont.subtitle)
                            .foregroundStyle(.secondary)
                        Text(code)
                            .font(Theme.Font.screenTitle.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .focusable()

                    SettingsActionRow(
                        title: String(localized: "Done"),
                        subtitle: String(localized: "Hides the code."),
                        systemImage: "checkmark"
                    ) {
                        pin = ""
                        model.dismissCode()
                    }
                } else {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "key")
                            .font(SettingsRowFont.title)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        SecureField(String(localized: "Choose a PIN (4 to 8 characters)"), text: $pin)
                            .textFieldStyle(.plain)
                            .font(SettingsRowFont.title)
                    }

                    SettingsActionRow(
                        title: model.isWorking ? String(localized: "Generating\u{2026}") : String(localized: "Generate Code"),
                        subtitle: String(localized: "Creates a code for your account that links another device."),
                        systemImage: "link"
                    ) {
                        model.generate(pin: pin)
                    }

                    if let failure = model.failure {
                        Text(Self.message(for: failure))
                            .font(SettingsRowFont.subtitle)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsSection(
                String(localized: "Linked Devices"),
                footer: String(localized: "Unlinking a device stops it from using this account.")
            ) {
                if model.devices.isEmpty {
                    SettingsValueRow(
                        title: model.devicesFailed
                            ? String(localized: "Couldn\u{2019}t Load Linked Devices")
                            : String(localized: "No Linked Devices"),
                        value: ""
                    )
                    if model.devicesFailed {
                        SettingsActionRow(title: String(localized: "Try Again"), systemImage: "arrow.clockwise") {
                            model.loadDevices()
                        }
                    }
                } else {
                    ForEach(model.devices, id: \.deviceUserId) { device in
                        SettingsDestructiveRow(
                            title: device.deviceName ?? String(localized: "Linked Device"),
                            subtitle: String(localized: "Select to unlink this device."),
                            systemImage: "iphone.slash"
                        ) {
                            deviceToUnlink = device
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Sync Code"))
        .onAppear { model.loadDevices() }
        .alert(
            unlinkTitle,
            isPresented: Binding(
                get: { deviceToUnlink != nil },
                set: { if !$0 { deviceToUnlink = nil } }
            )
        ) {
            Button(String(localized: "Unlink"), role: .destructive) {
                if let device = deviceToUnlink { model.unlink(device) }
                deviceToUnlink = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("It will no longer sync with this account.")
        }
    }

    private var unlinkTitle: String {
        if let name = deviceToUnlink?.deviceName {
            return String(localized: "Unlink \(name)?")
        }
        return String(localized: "Unlink This Device?")
    }

    private static func message(for failure: SyncCodeViewModel.Failure) -> String {
        switch failure {
        case .notSignedIn:
            return String(localized: "Sign in with a Nuvio account to use sync codes.")
        case .invalidPin:
            return String(localized: "The PIN must be 4 to 8 characters.")
        case .failed:
            return String(localized: "Couldn\u{2019}t create a code. Check your connection and try again.")
        }
    }
}

/// Drives `SyncCodeSettingsPage` through the shared `SyncCodeRepository` (plain response objects,
/// never thrown errors).
@MainActor
final class SyncCodeViewModel: ObservableObject {
    enum Failure {
        case notSignedIn
        case invalidPin
        case failed
    }

    @Published private(set) var code: String?
    @Published private(set) var isWorking = false
    @Published private(set) var failure: Failure?
    @Published private(set) var devices: [LinkedDevice] = []
    @Published private(set) var devicesFailed = false

    func generate(pin: String) {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        SyncCodeRepository.shared.generateCode(pin: pin) { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWorking = false
                if let code = response?.code {
                    self.code = code
                } else {
                    self.failure = Self.failure(for: response?.error)
                }
            }
        }
    }

    func dismissCode() {
        code = nil
        failure = nil
    }

    func loadDevices() {
        SyncCodeRepository.shared.linkedDevices { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let response, response.error == nil {
                    self.devices = response.devices
                    self.devicesFailed = false
                } else {
                    self.devicesFailed = true
                }
            }
        }
    }

    func unlink(_ device: LinkedDevice) {
        SyncCodeRepository.shared.unlinkDevice(deviceUserId: device.deviceUserId) { [weak self] _, _ in
            DispatchQueue.main.async { self?.loadDevices() }
        }
    }

    private static func failure(for error: SyncCodeError?) -> Failure {
        if error == SyncCodeError.notSignedIn { return .notSignedIn }
        if error == SyncCodeError.invalidPin { return .invalidPin }
        return .failed
    }
}
