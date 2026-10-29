import Foundation
import os

/// Host input watchdog (§3.3).
///
/// Monitors connection activity while input states (mouse buttons, stylus contact,
/// keyboard keys, or modifiers) are considered held. If no valid packet arrives
/// within the timeout window (~500 ms), invokes the release handler to unstick
/// any held state.
final class HostWatchdog: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 0.500

    private let timeout: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let onTimeout: @Sendable () -> Void
    private let queue: DispatchQueue
    private let log = Logger(subsystem: "com.vpad.MacHost", category: "watchdog")

    private var timer: DispatchSourceTimer?
    private var lastPacketTime: TimeInterval
    private var isTimerRunning = false
    private let lock = NSLock()

    var onTimeoutCheck: (@Sendable () -> Void)?

    init(
        timeout: TimeInterval = HostWatchdog.defaultTimeout,
        queue: DispatchQueue = DispatchQueue(label: "com.vpad.watchdog", qos: .userInteractive),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onTimeout: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.queue = queue
        self.clock = clock
        self.onTimeout = onTimeout
        self.lastPacketTime = clock()
    }

    deinit {
        stopTimer()
    }

    /// Notifies the watchdog that a valid packet arrived.
    func packetReceived(now: TimeInterval? = nil) {
        lock.lock()
        lastPacketTime = now ?? clock()
        lock.unlock()
    }

    /// Arms the background timer if held state exists and timer is not yet running.
    func armIfNeeded(hasHeldState: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if hasHeldState {
            if !isTimerRunning {
                startTimerLocked()
            }
        } else {
            if isTimerRunning {
                stopTimerLocked()
            }
        }
    }

    /// Explicitly checks timeout against the current timestamp. Used by the timer
    /// and by deterministic unit tests.
    @discardableResult
    func checkTimeout(now: TimeInterval? = nil, hasHeldState: Bool) -> Bool {
        let current = now ?? clock()
        lock.lock()
        let elapsed = current - lastPacketTime
        let shouldFire = hasHeldState && elapsed >= timeout
        if shouldFire {
            // Reset to prevent repeated firing without new packets
            lastPacketTime = current
        }
        lock.unlock()

        if shouldFire {
            log.notice("VPAD_WATCHDOG timeout elapsed=\(elapsed, privacy: .public)s: releasing held inputs")
            onTimeout()
            return true
        }
        return false
    }

    // MARK: - Private Timer

    private func startTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.onTimerTick()
        }
        timer.resume()
        self.timer = timer
        self.isTimerRunning = true
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
        isTimerRunning = false
    }

    private func stopTimer() {
        lock.lock()
        stopTimerLocked()
        lock.unlock()
    }

    private func onTimerTick() {
        onTimeoutCheck?()
    }
}
