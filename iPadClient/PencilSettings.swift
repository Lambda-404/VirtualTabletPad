import Combine
import CoreGraphics
import Foundation
import VPadProtocol

enum PressureCurve: String, CaseIterable, Codable, Identifiable, Sendable {
    case natural
    case soft
    case hard
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "Natural"
        case .soft: return "Soft"
        case .hard: return "Hard"
        case .custom: return "Custom"
        }
    }

    var config: PressureCurveConfiguration {
        switch self {
        case .natural: return PressureCurveConfiguration(preset: .natural)
        case .soft: return PressureCurveConfiguration(preset: .soft)
        case .hard: return PressureCurveConfiguration(preset: .hard)
        case .custom: return PressureCurveConfiguration(preset: .custom)
        }
    }

    func apply(_ value: Float32) -> Float32 {
        config.apply(value)
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

    var pressureCurveConfig: PressureCurveConfiguration
    var penOnly: Bool
    /// 0 = follow the Pencil tip directly; 1 = maximum jitter smoothing.
    var stabilization: Double

    var pressureCurve: PressureCurve {
        get {
            switch pressureCurveConfig.preset {
            case .natural: return .natural
            case .soft: return .soft
            case .hard: return .hard
            case .custom: return .custom
            }
        }
        set {
            switch newValue {
            case .natural: pressureCurveConfig.selectPreset(.natural)
            case .soft: pressureCurveConfig.selectPreset(.soft)
            case .hard: pressureCurveConfig.selectPreset(.hard)
            case .custom: pressureCurveConfig.selectPreset(.custom)
            }
        }
    }

    init(
        pressureCurveConfig: PressureCurveConfiguration = PressureCurveConfiguration(),
        penOnly: Bool = false,
        stabilization: Double = PencilInputSettings.defaultStabilization
    ) {
        self.pressureCurveConfig = pressureCurveConfig
        self.penOnly = penOnly
        self.stabilization = Self.normalizedStabilization(stabilization)
    }

    init(
        pressureCurve: PressureCurve,
        penOnly: Bool = false,
        stabilization: Double = PencilInputSettings.defaultStabilization
    ) {
        self.pressureCurveConfig = pressureCurve.config
        self.penOnly = penOnly
        self.stabilization = Self.normalizedStabilization(stabilization)
    }

    private enum CodingKeys: String, CodingKey {
        case pressureCurveConfig
        case pressureCurve
        case penOnly
        case stabilization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let config = try container.decodeIfPresent(PressureCurveConfiguration.self, forKey: .pressureCurveConfig) {
            pressureCurveConfig = config
        } else if let legacy = try container.decodeIfPresent(PressureCurve.self, forKey: .pressureCurve) {
            pressureCurveConfig = legacy.config
        } else {
            pressureCurveConfig = PressureCurveConfiguration()
        }
        penOnly = try container.decodeIfPresent(Bool.self, forKey: .penOnly) ?? false
        stabilization = Self.normalizedStabilization(
            try container.decodeIfPresent(Double.self, forKey: .stabilization)
                ?? Self.defaultStabilization
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pressureCurveConfig, forKey: .pressureCurveConfig)
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

