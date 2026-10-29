import Foundation

/// Statistical metrics for network transport latency and jitter (§3.5).
public struct LatencyMetrics: Sendable, Codable, Equatable {
    public let count: Int
    public let lostCount: Int
    public let lossRate: Double
    public let minMs: Double
    public let maxMs: Double
    public let meanMs: Double
    public let p50Ms: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let stdDevMs: Double
    public let jitterMs: Double

    public init(samplesMs: [Double], totalSent: Int) {
        let n = samplesMs.count
        self.count = n
        let lost = max(0, totalSent - n)
        self.lostCount = lost
        self.lossRate = totalSent > 0 ? Double(lost) / Double(totalSent) : 0.0

        guard n > 0 else {
            self.minMs = 0
            self.maxMs = 0
            self.meanMs = 0
            self.p50Ms = 0
            self.p95Ms = 0
            self.p99Ms = 0
            self.stdDevMs = 0
            self.jitterMs = 0
            return
        }

        let sorted = samplesMs.sorted()
        self.minMs = sorted.first!
        self.maxMs = sorted.last!
        let sum = sorted.reduce(0.0, +)
        let mean = sum / Double(n)
        self.meanMs = mean

        self.p50Ms = Self.percentile(sorted: sorted, p: 0.50)
        self.p95Ms = Self.percentile(sorted: sorted, p: 0.95)
        self.p99Ms = Self.percentile(sorted: sorted, p: 0.99)

        if n > 1 {
            let variance = sorted.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
            self.stdDevMs = sqrt(variance)
        } else {
            self.stdDevMs = 0.0
        }

        // RFC 3550 interarrival jitter: J_i = J_{i-1} + (|D(i-1, i)| - J_{i-1}) / 16
        var j: Double = 0.0
        if samplesMs.count > 1 {
            for i in 1..<samplesMs.count {
                let d = abs(samplesMs[i] - samplesMs[i - 1])
                j += (d - j) / 16.0
            }
        }
        self.jitterMs = j
    }

    public static func percentile(sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        if sorted.count == 1 { return sorted[0] }
        let clampedP = max(0.0, min(1.0, p))
        let rank = clampedP * Double(sorted.count - 1)
        let lowerIndex = Int(floor(rank))
        let upperIndex = Int(ceil(rank))
        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }
        let fraction = rank - Double(lowerIndex)
        return sorted[lowerIndex] + fraction * (sorted[upperIndex] - sorted[lowerIndex])
    }
}
