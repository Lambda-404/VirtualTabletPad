import Combine
import CoreGraphics
import Foundation

enum PressureCurve: String, CaseIterable, Codable, Identifiable, Sendable {
    case natural
    case soft
    case hard

    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "Natural"
        case .soft: return "Soft / Sensitive"
        case .hard: return "Hard / Controlled"
        }
    }

    func apply(_ value: Float32) -> Float32 {
        let clamped = min(max(value, 0), 1)
        switch self {
        case .natural:
            return clamped
        case .soft:
            return pow(clamped, 0.72)
        case .hard:
            return pow(clamped, 1.45)
        }
    }
}

enum PencilStabilizationPreset: String, CaseIterable, Identifiable, Sendable {
    case off
    case light
    case balanced
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        }
    }

    var value: Double {
        switch self {
        case .off: return 0.0
        case .light: return 0.25
        case .balanced: return PencilInputSettings.defaultStabilization
        case .strong: return 0.70
        }
    }
}

struct PencilInputSettings: Codable, Equatable, Sendable {
    static let defaultStabilization: Double = 0.35

    var pressureCurve: PressureCurve
    var penOnly: Bool
    /// 0 = follow the Pencil tip directly; 1 = maximum jitter smoothing.
    var stabilization: Double

    init(
        pressureCurve: PressureCurve = .natural,
        penOnly: Bool = false,
        stabilization: Double = PencilInputSettings.defaultStabilization
    ) {
        self.pressureCurve = pressureCurve
        self.penOnly = penOnly
        self.stabilization = Self.normalizedStabilization(stabilization)
    }

    private enum CodingKeys: String, CodingKey {
        case pressureCurve
        case penOnly
        case stabilization
    }

    /// Old stored payloads only contain pressureCurve/penOnly; decode the new
    /// key with a default instead of failing the whole settings record.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pressureCurve = try container.decodeIfPresent(PressureCurve.self, forKey: .pressureCurve) ?? .natural
        penOnly = try container.decodeIfPresent(Bool.self, forKey: .penOnly) ?? false
        stabilization = Self.normalizedStabilization(
            try container.decodeIfPresent(Double.self, forKey: .stabilization)
                ?? Self.defaultStabilization
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pressureCurve, forKey: .pressureCurve)
        try container.encode(penOnly, forKey: .penOnly)
        try container.encode(stabilization, forKey: .stabilization)
    }

    static func normalizedStabilization(_ value: Double) -> Double {
        guard value.isFinite else { return defaultStabilization }
        return min(max(value, 0), 1)
    }
}

/// Time-constant exponential filter for Pencil positions. The effective
/// smoothing window is longer at slow speeds (where hand tremor is visible) and
/// shorter during fast strokes (where lag matters). Coordinates are in view
/// points and timestamps come from `UITouch.timestamp`.
struct PencilStrokeFilter: Sendable {
    private var lastRaw: CGPoint?
    private var smoothed: CGPoint?
    private var lastTimestamp: TimeInterval?

    mutating func reset() {
        lastRaw = nil
        smoothed = nil
        lastTimestamp = nil
    }

    mutating func process(
        _ raw: CGPoint,
        at timestamp: TimeInterval,
        stabilization: Double
    ) -> CGPoint {
        let strength = PencilInputSettings.normalizedStabilization(stabilization)

        guard strength > 0.001 else {
            lastRaw = raw
            smoothed = raw
            lastTimestamp = timestamp
            return raw
        }

        guard let previousRaw = lastRaw,
              let previousSmoothed = smoothed,
              let previousTimestamp = lastTimestamp else {
            lastRaw = raw
            smoothed = raw
            lastTimestamp = timestamp
            return raw
        }

        let dt = min(max(timestamp - previousTimestamp, 1.0 / 240.0), 0.05)
        let distance = Double(hypot(raw.x - previousRaw.x, raw.y - previousRaw.y))
        let speed = distance / dt
        let baseTau = 0.004 + 0.050 * strength
        let speedScale = 1 - 0.65 * min(speed / 1400.0, 1)
        let tau = max(baseTau * speedScale, 0.0025)
        let alpha = 1 - exp(-dt / tau)
        let next = CGPoint(
            x: previousSmoothed.x + (raw.x - previousSmoothed.x) * CGFloat(alpha),
            y: previousSmoothed.y + (raw.y - previousSmoothed.y) * CGFloat(alpha)
        )

        lastRaw = raw
        smoothed = next
        lastTimestamp = timestamp
        return next
    }
}

@MainActor
final class PencilSettingsStore: ObservableObject {
    static let shared = PencilSettingsStore()
    @Published private(set) var settings: PencilInputSettings

    private static let key = "vpad.pencilInputSettings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PencilInputSettings.self, from: data) {
            settings = decoded
        } else {
            settings = PencilInputSettings()
        }
    }

    func update(_ next: PencilInputSettings) {
        var normalized = next
        normalized.stabilization = PencilInputSettings.normalizedStabilization(next.stabilization)
        settings = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

