import SwiftUI
import SharedCore

/// First end-to-end proof that SwiftUI can drive the shared Kotlin layer:
/// observes `NetworkStatusRepository.uiState` (a `StateFlow<NetworkStatusUiState>`) and renders the
/// live `NetworkCondition`, kicking off a probe via `ensureStarted()`.
struct NetworkStatusView: View {
    @StateObject private var observer = StateFlowObserver<NetworkStatusUiState>(
        NetworkStatusRepository.shared.uiState,
        initial: NetworkStatusUiState(condition: NetworkCondition.unknown)
    )

    var body: some View {
        VStack(spacing: 24) {
            Text("SharedCore is live")
                .font(.largeTitle).bold()

            HStack(spacing: 16) {
                Circle()
                    .fill(color(for: observer.value.condition))
                    .frame(width: 28, height: 28)
                Text(label(for: observer.value.condition))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Button("Re-check") {
                NetworkStatusRepository.shared.requestRefresh(force: true, confirmFailures: false)
            }
            .buttonStyle(.chip)
        }
        .onAppear {
            NetworkStatusRepository.shared.ensureStarted()
        }
    }

    private func label(for condition: NetworkCondition) -> String {
        // Match on the Kotlin enum's `.name` string — version-proof against ObjC-export case naming.
        switch condition.name {
        case "ONLINE": return String(localized: "Online")
        case "CHECKING": return String(localized: "Checking\u{2026}")
        case "NO_INTERNET": return String(localized: "No internet connection")
        case "SERVERS_UNREACHABLE": return String(localized: "Servers unreachable")
        default: return String(localized: "Unknown")
        }
    }

    private func color(for condition: NetworkCondition) -> Color {
        switch condition.name {
        case "ONLINE": return .green
        case "CHECKING": return .yellow
        case "NO_INTERNET", "SERVERS_UNREACHABLE": return .red
        default: return .gray
        }
    }
}
