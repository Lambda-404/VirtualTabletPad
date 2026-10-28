import Foundation

/// Replay protection using a 128-bit sliding bitmap window (RFC 6479 / RFC 4303).
///
/// Tracks sequence numbers in constant-time with zero heap allocations:
/// - Bit 0 of `bitmap0` represents `highestSeq`.
/// - Bits 1..63 represent `highestSeq - 1` through `highestSeq - 63`.
/// - Bits 0..63 of `bitmap1` represent `highestSeq - 64` through `highestSeq - 127`.
public struct ReplayWindow: Sendable, Equatable {
    public static let windowSize: UInt64 = 128
    public static let rekeyThreshold: UInt64 = UInt64.max - 100_000

    private var highestSeq: UInt64?
    private var bitmap0: UInt64 = 0
    private var bitmap1: UInt64 = 0

    public init() {}

    public var highestSequenceNumber: UInt64? {
        highestSeq
    }

    public var isNearOverflow: Bool {
        guard let highest = highestSeq else { return false }
        return highest >= Self.rekeyThreshold
    }

    /// Tests whether a sequence number is acceptable, and if so, advances the window.
    ///
    /// - Parameter seq: The incoming sequence number.
    /// - Returns: `true` if accepted (valid, in-window, and previously unseen),
    ///   `false` if rejected (duplicate or stale).
    public mutating func checkAndAdvance(_ seq: UInt64) -> Bool {
        guard let highest = highestSeq else {
            highestSeq = seq
            bitmap0 = 1
            bitmap1 = 0
            return true
        }

        if seq > highest {
            let diff = seq - highest
            if diff >= Self.windowSize {
                bitmap0 = 1
                bitmap1 = 0
            } else if diff < 64 {
                let shift = Int(diff)
                bitmap1 = (bitmap1 << shift) | (bitmap0 >> (64 - shift))
                bitmap0 = (bitmap0 << shift) | 1
            } else {
                let shift = Int(diff - 64)
                bitmap1 = bitmap0 << shift
                bitmap0 = 1
            }
            highestSeq = seq
            return true
        }

        let diff = highest - seq
        if diff >= Self.windowSize {
            // Older than 128 packets: stale
            return false
        }

        if diff < 64 {
            let mask = UInt64(1) << Int(diff)
            if (bitmap0 & mask) != 0 {
                // Duplicate packet
                return false
            }
            bitmap0 |= mask
            return true
        } else {
            let mask = UInt64(1) << Int(diff - 64)
            if (bitmap1 & mask) != 0 {
                // Duplicate packet
                return false
            }
            bitmap1 |= mask
            return true
        }
    }
}
