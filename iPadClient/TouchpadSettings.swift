import Combine
import CoreGraphics
import Foundation

// MARK: - Model

enum TouchpadPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case precise
    case balanced
    case swift
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precise: return "Precise"
        case .balanced: return "Balanced"
        case .swift: return "Swift"
        case .custom: return "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .precise: return "Fine control"
        case .balanced: return "Recommended"
        case .swift: return "Faster across screens"
        case .custom: return "Your tuning"
        }
    }

    var symbol: String {
        switch self {
        case .precise: return "scope"
        case .balanced: return "slider.horizontal.3"
        case .swift: return "wind"
        case .custom: return "dial.medium"
        }
    }

    var base: TouchpadSettings {
        switch self {
        case .precise:
            return TouchpadSettings(
                pointerSpeed: 0.85,
                acceleration: 0.65,
                slowPrecision: 1.25,
                jitterFilter: 1.0,
                smoothing: 0.62,
                stopSmoothing: 0.0,
                scrollSensitivity: 0.65,
                naturalScrolling: true,
                showTouchIndicator: true,
                hapticFeedback: true,
                preset: .precise
            )
        case .balanced:
            return .balanced
        case .swift:
            return TouchpadSettings(
                pointerSpeed: 1.45,
                acceleration: 1.80,
                slowPrecision: 0.70,
                jitterFilter: 0.55,
                smoothing: 0.25,
                stopSmoothing: 0.03,
                scrollSensitivity: 1.15,
                naturalScrolling: true,
                showTouchIndicator: true,
                hapticFeedback: true,
                preset: .swift
            )
        case .custom:
            return .balanced
        }
    }
}

struct TouchpadSettings: Codable, Equatable, Sendable {
    var pointerSpeed: Double = 1.08
    var acceleration: Double = 1.25
    var slowPrecision: Double = 0.95
    var jitterFilter: Double = 0.85
    var smoothing: Double = 0.45
    var stopSmoothing: Double = 0.02
    var scrollSensitivity: Double = 0.80
    var naturalScrolling: Bool = true
    var showTouchIndicator: Bool = true
    var hapticFeedback: Bool = true
    /// Sofatap/Touchpad-style drag: a stationary hold presses the left button.
    var holdToDrag: Bool = true
    var dragDelay: Double = 0.30
    var preset: TouchpadPreset = .balanced

    static let balanced = TouchpadSettings()

    func applying(_ preset: TouchpadPreset) -> TouchpadSettings {
        var next = preset.base
        next.showTouchIndicator = showTouchIndicator
        next.hapticFeedback = hapticFeedback
        next.preset = preset
        return next
    }
}

// MARK: - Store

@MainActor
final class TouchpadSettingsStore: ObservableObject {
    static let shared = TouchpadSettingsStore()

    @Published private(set) var settings: TouchpadSettings

    private static let storageKey = "vpad.touchpadSettings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(TouchpadSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .balanced
        }
    }

    func update(_ next: TouchpadSettings) {
        settings = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func applyPreset(_ preset: TouchpadPreset) {
        update(settings.applying(preset))
    }

    func reset() {
        update(.balanced)
    }
}

// MARK: - Motion processing

/// Applies the touchpad feel settings on-device before packets reach the Mac.
/// The Mac remains a thin event injector, so sliders are responsive and do not
/// require reconnecting.
struct TouchpadMotionFilter {
    private var lastTime: TimeInterval = 0
    private var smoothed = CGVector.zero
    private(set) var velocity = CGVector.zero

    mutating func process(
        dx: Double,
        dy: Double,
        now: TimeInterval,
        settings: TouchpadSettings
    ) -> (Float32, Float32) {
        let dt = lastTime == 0 ? 1.0 / 120.0 : min(max(now - lastTime, 1.0 / 240.0), 0.05)
        lastTime = now

        var x = dx
        var y = dy
        let rawSpeed = hypot(x, y) / dt

        // Tiny finger tremors are dropped instead of being amplified by the
        // pointer-speed multiplier. At 0 this is disabled.
        let jitterThreshold = settings.jitterFilter * 1.6
        if hypot(x, y) < jitterThreshold, rawSpeed < 90 {
            x = 0
            y = 0
        }

        // Higher smoothing means a steadier cursor but slightly more lag.
        let alpha = min(max(settings.smoothing * 0.85, 0), 0.94)
        smoothed.dx = smoothed.dx * alpha + x * (1 - alpha)
        smoothed.dy = smoothed.dy * alpha + y * (1 - alpha)

        let speed = hypot(smoothed.dx, smoothed.dy) / dt
        let fastGain = 1 + settings.acceleration * min(speed / 1500, 1.4)
        let slowGain = max(0.22, 1 - settings.slowPrecision * 0.45 * max(0, 1 - speed / 600))
        let gain = settings.pointerSpeed * fastGain * slowGain

        var outX = smoothed.dx * gain
        var outY = smoothed.dy * gain
        outX = min(max(outX, -140), 140)
        outY = min(max(outY, -140), 140)

        velocity = CGVector(dx: outX / dt, dy: outY / dt)
        return (Float32(outX), Float32(outY))
    }

    mutating func reset() {
        lastTime = 0
        smoothed = .zero
        velocity = .zero
    }
}
