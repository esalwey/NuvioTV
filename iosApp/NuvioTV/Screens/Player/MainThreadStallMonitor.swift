import Foundation

/// Main-thread stall watchdog for the players (mpv and native).
///
/// A timer on a background queue pings the main queue every 100 ms. When the main thread answers
/// late the stall is recorded with its length and with whatever libmpv call was in flight while it
/// lasted, so a freeze reported on a device ("the Play/Pause button does not answer on a very large
/// stream") can be read off the screen instead of guessed at.
///
/// The mpv controller wraps every call it makes into libmpv in `run(_:_:)`. That records which
/// calls are in flight, the slowest call seen on any thread, and, as a violation, any call that
/// runs on the main thread: the main thread never calls libmpv synchronously, so that counter is
/// expected to stay at zero.
///
/// It runs in DEBUG builds and, in a release build, once the hidden Developer pane is unlocked
/// (`DeveloperMode`). The longest stall is shown in Developer > Player Responsiveness and in the
/// player's Stream Info.
nonisolated final class MainThreadStallMonitor: @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    /// A main-thread delay at or past this is a stall.
    static let thresholdMs = 250
    /// A libmpv call at or past this is logged as slow whatever thread it ran on.
    static let slowCallMs = 400

    struct Report: Equatable, Sendable {
        /// The stall in progress right now (0 when the main thread is answering).
        var currentStallMs = 0
        var longestStallMs = 0
        /// What was in flight during the longest stall: a libmpv call and the thread it ran on, or
        /// "-" when no libmpv call was running (the stall is then not libmpv's).
        var longestStallDuring = ""
        var lastStallMs = 0
        var stallCount = 0
        /// The slowest libmpv call seen on any thread.
        var slowestCallMs = 0
        var slowestCallName = ""
        /// libmpv calls made on the main thread (expected: 0) and the first one's name.
        var mainThreadCalls = 0
        var firstMainThreadCall = ""

        var isEmpty: Bool { self == Report() }
    }

    private struct Call {
        let name: String
        let since: TimeInterval
        let onMain: Bool
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "nuvio.main-stall-monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var sessions = 0
    private var report = Report()
    private var calls: [UInt64: Call] = [:]
    private var nextCallID: UInt64 = 0
    /// Uptime of the ping the main thread has not answered yet (0 = none outstanding).
    private var pingSentAt: TimeInterval = 0
    private var culprit = ""
    private var culpritMs = 0

    /// Whether the watchdog may run in this build.
    static var isAllowed: Bool {
        #if DEBUG
        return true
        #else
        return DeveloperMode.isUnlocked
        #endif
    }

    private var isRunning: Bool { timer != nil }

    // MARK: Sessions

    /// A player came on screen. The timer runs while at least one player is up.
    func beginSession() {
        guard Self.isAllowed else { return }
        lock.lock()
        sessions += 1
        let start = timer == nil
        lock.unlock()
        if start { startTimer() }
    }

    func endSession() {
        lock.lock()
        sessions = max(0, sessions - 1)
        let stop = sessions == 0
        let active = timer
        if stop { timer = nil; pingSentAt = 0 }
        lock.unlock()
        if stop { active?.cancel() }
    }

    func reset() {
        lock.lock()
        report = Report()
        lock.unlock()
    }

    func snapshot() -> Report {
        lock.lock(); defer { lock.unlock() }
        return report
    }

    // MARK: libmpv calls

    /// Runs `body` (one libmpv call) and tracks it while the watchdog is on; a plain call otherwise.
    func run<T>(_ name: @autoclosure () -> String, _ body: () -> T) -> T {
        lock.lock()
        let tracking = isRunning
        lock.unlock()
        guard tracking else { return body() }

        let label = name()
        let onMain = Thread.isMainThread
        let started = ProcessInfo.processInfo.systemUptime
        lock.lock()
        nextCallID &+= 1
        let id = nextCallID
        calls[id] = Call(name: label, since: started, onMain: onMain)
        if onMain {
            report.mainThreadCalls += 1
            if report.firstMainThreadCall.isEmpty { report.firstMainThreadCall = label }
        }
        lock.unlock()
        if onMain { print("[Stall] libmpv call on the main thread: \(label)") }

        let result = body()

        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        lock.lock()
        calls[id] = nil
        if ms > report.slowestCallMs {
            report.slowestCallMs = ms
            report.slowestCallName = label + (onMain ? " [main]" : "")
        }
        lock.unlock()
        if ms >= Self.slowCallMs {
            print("[Stall] slow libmpv call: \(label) took \(ms) ms\(onMain ? " ON THE MAIN THREAD" : "")")
        }
        return result
    }

    // MARK: Ping

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.1, repeating: 0.1)
        source.setEventHandler { [weak self] in self?.tick() }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if pingSentAt == 0 {
            pingSentAt = now
            culprit = ""
            culpritMs = 0
            lock.unlock()
            DispatchQueue.main.async { [self] in self.pingAnswered() }
            return
        }
        let waitedMs = Int((now - pingSentAt) * 1000)
        if waitedMs >= Self.thresholdMs {
            report.currentStallMs = waitedMs
            // The call that has been running the longest, a main-thread one first: that is the one
            // the main thread is most likely waiting on.
            let mainCalls = calls.values.filter(\.onMain)
            let pool = mainCalls.isEmpty ? Array(calls.values) : mainCalls
            if let oldest = pool.min(by: { $0.since < $1.since }) {
                let elapsed = Int((now - oldest.since) * 1000)
                if elapsed >= culpritMs {
                    culpritMs = elapsed
                    culprit = "\(oldest.name) [\(oldest.onMain ? "main" : "bg")] \(elapsed) ms"
                }
            }
        }
        lock.unlock()
    }

    private func pingAnswered() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let sent = pingSentAt
        pingSentAt = 0
        report.currentStallMs = 0
        guard sent > 0 else { lock.unlock(); return }
        let ms = Int((now - sent) * 1000)
        var logged: String?
        if ms >= Self.thresholdMs {
            report.stallCount += 1
            report.lastStallMs = ms
            let during = culprit.isEmpty ? "-" : culprit
            if ms > report.longestStallMs {
                report.longestStallMs = ms
                report.longestStallDuring = during
            }
            logged = "[Stall] main thread blocked for \(ms) ms; libmpv in flight: \(during)"
        }
        lock.unlock()
        if let logged { print(logged) }
    }

    // MARK: Display

    /// One line for the Stream Info rows: "none" / "812 ms \u{00B7} get time-pos [bg] 790 ms".
    /// Empty while the watchdog is not allowed in this build.
    func summaryLine() -> String {
        guard Self.isAllowed else { return "" }
        let r = snapshot()
        var parts: [String] = []
        if r.longestStallMs > 0 {
            parts.append("longest \(r.longestStallMs) ms")
            if !r.longestStallDuring.isEmpty && r.longestStallDuring != "-" { parts.append(r.longestStallDuring) }
        } else {
            parts.append("none over \(Self.thresholdMs) ms")
        }
        if r.mainThreadCalls > 0 { parts.append("\(r.mainThreadCalls) libmpv call(s) on main") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
