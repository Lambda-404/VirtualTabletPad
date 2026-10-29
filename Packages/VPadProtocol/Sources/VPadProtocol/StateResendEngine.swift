import Foundation

/// Manages reliable transmission of discrete state events (press, release, proximity, modifier)
/// over an unreliable datagram transport (UDP).
public final class StateResendEngine: @unchecked Sendable {
    public struct Config: Sendable {
        public let maxResends: Int
        public let resendInterval: TimeInterval

        public init(maxResends: Int = 4, resendInterval: TimeInterval = 0.015) {
            self.maxResends = maxResends
            self.resendInterval = resendInterval
        }
    }

    public struct PendingStateEvent: Sendable, Equatable {
        public let packet: VPadPacket
        public let initialSeq: UInt64
        public var attemptsRemaining: Int
        public var nextResendTime: TimeInterval

        public init(
            packet: VPadPacket,
            initialSeq: UInt64,
            attemptsRemaining: Int,
            nextResendTime: TimeInterval
        ) {
            self.packet = packet
            self.initialSeq = initialSeq
            self.attemptsRemaining = attemptsRemaining
            self.nextResendTime = nextResendTime
        }
    }

    private let lock = NSLock()
    public let config: Config
    private var pending: [PendingStateEvent] = []
    private let maxPendingCount: Int = 16

    public init(config: Config = Config()) {
        self.config = config
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    public var pendingEvents: [PendingStateEvent] {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// Registers a sent packet. If the packet is a discrete state event,
    /// it will be tracked for cumulative acknowledgement and retransmitted if needed.
    public func onPacketSent(
        _ packet: VPadPacket,
        seq: UInt64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard packet.isStateEvent else { return }

        lock.lock()
        defer { lock.unlock() }

        if pending.count >= maxPendingCount {
            pending.removeFirst()
        }

        let record = PendingStateEvent(
            packet: packet,
            initialSeq: seq,
            attemptsRemaining: config.maxResends,
            nextResendTime: now + config.resendInterval
        )
        pending.append(record)
    }

    /// Processes a cumulative acknowledgement from the host.
    /// All pending state events with initialSeq <= cumulativeAckSeq are retired.
    public func onAckReceived(_ cumulativeAckSeq: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll { $0.initialSeq <= cumulativeAckSeq }
    }

    /// Returns any pending state event that is ready for retransmission.
    /// Updates its next resend time and decrements remaining attempts.
    public func nextResendPacket(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> VPadPacket? {
        lock.lock()
        defer { lock.unlock() }

        // Clean up exhausted items first
        pending.removeAll { $0.attemptsRemaining <= 0 }

        for i in 0..<pending.count {
            if pending[i].attemptsRemaining > 0 && now >= pending[i].nextResendTime {
                pending[i].attemptsRemaining -= 1
                pending[i].nextResendTime = now + config.resendInterval
                return pending[i].packet
            }
        }

        return nil
    }

    /// Resets all pending state (e.g. on session disconnect).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }
}
