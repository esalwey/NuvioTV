import ObjectiveC
import UIKit

/// Reads the live app for the terms of `AmbientConditions` that are not plain settings.
enum AmbientEnvironmentProbe {
    static func current() -> AmbientConditions {
        var conditions = AmbientConditions()
        conditions.idleTimerHeldByOthers = UIApplication.shared.isIdleTimerDisabled
        conditions.coverPresented = isCoverPresented()
        conditions.trailerPlaying = InlineTrailerCoordinator.shared.playingKey != nil
        conditions.voiceOverRunning = UIAccessibility.isVoiceOverRunning
        return conditions
    }

    /// SwiftUI presents sheets, alerts and full-screen covers through UIKit from the root hosting
    /// controller, so a presented controller on any window's root means something sits above Home.
    private static func isCoverPresented() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.rootViewController?.presentedViewController != nil {
                return true
            }
        }
        return false
    }
}

/// The app-wide view of the Siri Remote that Ambient Mode needs and SwiftUI does not offer: every
/// press and touch, before the focus engine sees it, so activity can restart the idle clock and the
/// press that wakes the slideshow can be kept from also activating the focused item.
///
/// Installed once, as an exchange of `UIApplication.sendEvent(_:)`. The replacement forwards to the
/// original for everything it does not swallow, so with Ambient Mode off it only notes the time.
enum AmbientInputMonitor {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.nuvioAmbientSendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// The reduced form of an event, or nil for events that are not remote input.
    static func input(for event: UIEvent) -> AmbientInputGate.Input? {
        if let pressEvent = event as? UIPressesEvent {
            let presses = pressEvent.allPresses
            guard !presses.isEmpty else { return nil }
            let ended = presses.allSatisfy { $0.phase == .ended || $0.phase == .cancelled }
            return AmbientInputGate.Input(endsInteraction: ended)
        }
        if event.type == .touches, let touches = event.allTouches, !touches.isEmpty {
            let ended = touches.allSatisfy { $0.phase == .ended || $0.phase == .cancelled }
            return AmbientInputGate.Input(endsInteraction: ended)
        }
        return nil
    }
}

extension UIApplication {
    /// After `AmbientInputMonitor.installIfNeeded()` this is what `sendEvent(_:)` runs, and calling
    /// `nuvioAmbientSendEvent` from here reaches the ORIGINAL implementation (the two were exchanged).
    @objc func nuvioAmbientSendEvent(_ event: UIEvent) {
        if let input = AmbientInputMonitor.input(for: event),
           AmbientIdleController.shared.intercept(input) {
            return
        }
        nuvioAmbientSendEvent(event)
    }
}
