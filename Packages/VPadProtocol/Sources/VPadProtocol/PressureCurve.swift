import Foundation
import CoreGraphics

/// Cubic Bézier pressure response curve (§4.2).
public struct PressureCurveConfiguration: Sendable, Codable, Equatable {
    public enum Preset: String, Sendable, Codable, CaseIterable, Identifiable {
        case natural
        case soft
        case hard
        case custom

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .natural: return "Natural"
            case .soft: return "Soft"
            case .hard: return "Hard"
            case .custom: return "Custom"
            }
        }
    }

    public var preset: Preset
    public var controlPoint1: CGPoint
    public var controlPoint2: CGPoint

    public private(set) var lookupTable: [Float32]

    public init(
        preset: Preset = .natural,
        controlPoint1: CGPoint? = nil,
        controlPoint2: CGPoint? = nil
    ) {
        self.preset = preset
        let (p1, p2) = Self.controlPoints(for: preset, override1: controlPoint1, override2: controlPoint2)
        self.controlPoint1 = p1
        self.controlPoint2 = p2
        self.lookupTable = Self.buildLookupTable(p1: p1, p2: p2)
    }

    // MARK: - Hot Path Evaluation (O(1) Table Lookup)

    /// Applies the precomputed 256-entry lookup table in O(1) time with zero allocations.
    @inlinable
    public func apply(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        if value <= 0 { return 0 }
        if value >= 1 { return 1 }
        let index = Int(value * 255.0)
        return lookupTable[min(max(index, 0), 255)]
    }

    /// Evaluates with linear interpolation between adjacent LUT entries.
    @inlinable
    public func applyInterpolated(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        if value <= 0 { return 0 }
        if value >= 1 { return 1 }
        let scaled = value * 255.0
        let i = Int(scaled)
        if i >= 255 { return 1.0 }
        let frac = scaled - Float32(i)
        let low = lookupTable[i]
        let high = lookupTable[i + 1]
        return low + frac * (high - low)
    }

    // MARK: - Mutating Updates

    public mutating func updateControlPoints(p1: CGPoint, p2: CGPoint) {
        self.preset = .custom
        self.controlPoint1 = CGPoint(x: min(max(p1.x, 0), 1), y: min(max(p1.y, 0), 1))
        self.controlPoint2 = CGPoint(x: min(max(p2.x, 0), 1), y: min(max(p2.y, 0), 1))
        self.lookupTable = Self.buildLookupTable(p1: self.controlPoint1, p2: self.controlPoint2)
    }

    public mutating func selectPreset(_ newPreset: Preset) {
        self.preset = newPreset
        let (p1, p2) = Self.controlPoints(for: newPreset, override1: nil, override2: nil)
        self.controlPoint1 = p1
        self.controlPoint2 = p2
        self.lookupTable = Self.buildLookupTable(p1: p1, p2: p2)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case preset
        case p1x, p1y
        case p2x, p2y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try container.decodeIfPresent(Preset.self, forKey: .preset) ?? .natural
        let p1x = try container.decodeIfPresent(Double.self, forKey: .p1x)
        let p1y = try container.decodeIfPresent(Double.self, forKey: .p1y)
        let p2x = try container.decodeIfPresent(Double.self, forKey: .p2x)
        let p2y = try container.decodeIfPresent(Double.self, forKey: .p2y)

        let p1 = (p1x != nil && p1y != nil) ? CGPoint(x: p1x!, y: p1y!) : nil
        let p2 = (p2x != nil && p2y != nil) ? CGPoint(x: p2x!, y: p2y!) : nil
        self.init(preset: preset, controlPoint1: p1, controlPoint2: p2)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(Double(controlPoint1.x), forKey: .p1x)
        try container.encode(Double(controlPoint1.y), forKey: .p1y)
        try container.encode(Double(controlPoint2.x), forKey: .p2x)
        try container.encode(Double(controlPoint2.y), forKey: .p2y)
    }

    // MARK: - Mathematics & LUT Builder

    private static func controlPoints(
        for preset: Preset,
        override1: CGPoint?,
        override2: CGPoint?
    ) -> (CGPoint, CGPoint) {
        if let o1 = override1, let o2 = override2 {
            return (o1, o2)
        }
        switch preset {
        case .natural:
            return (CGPoint(x: 0.333, y: 0.333), CGPoint(x: 0.667, y: 0.667))
        case .soft:
            // High sensitivity: steep initial ramp
            return (CGPoint(x: 0.15, y: 0.45), CGPoint(x: 0.35, y: 0.85))
        case .hard:
            // Controlled firm pressure: gentle initial ramp, steep at top
            return (CGPoint(x: 0.55, y: 0.20), CGPoint(x: 0.85, y: 0.55))
        case .custom:
            return (
                override1 ?? CGPoint(x: 0.333, y: 0.333),
                override2 ?? CGPoint(x: 0.667, y: 0.667)
            )
        }
    }

    public static func buildLookupTable(p1: CGPoint, p2: CGPoint) -> [Float32] {
        var table = [Float32](repeating: 0, count: 256)
        let x1 = min(max(Double(p1.x), 0.0), 1.0)
        let y1 = min(max(Double(p1.y), 0.0), 1.0)
        let x2 = min(max(Double(p2.x), 0.0), 1.0)
        let y2 = min(max(Double(p2.y), 0.0), 1.0)

        table[0] = 0.0
        table[255] = 1.0

        var previousY: Float32 = 0.0
        for i in 1..<255 {
            let targetX = Double(i) / 255.0
            let t = solveTForX(targetX, x1: x1, x2: x2)
            let y = bezier(t, p1: y1, p2: y2)
            let clampedY = Float32(min(max(y, 0.0), 1.0))
            // Guarantee monotonic non-decreasing output
            let monotonicY = max(previousY, clampedY)
            table[i] = monotonicY
            previousY = monotonicY
        }
        return table
    }

    private static func solveTForX(_ targetX: Double, x1: Double, x2: Double) -> Double {
        var low = 0.0
        var high = 1.0
        var t = targetX
        for _ in 0..<14 {
            let curX = bezier(t, p1: x1, p2: x2)
            if abs(curX - targetX) < 1e-5 {
                break
            }
            if curX < targetX {
                low = t
            } else {
                high = t
            }
            t = (low + high) * 0.5
        }
        return t
    }

    private static func bezier(_ t: Double, p1: Double, p2: Double) -> Double {
        let u = 1.0 - t
        return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t
    }
}
