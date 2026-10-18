import Combine
import SwiftUI
import UIKit
import VPadProtocol

// MARK: - Guided Access / safety mode

enum GestureModePreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case native
    case safe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .native: return "Full"
        case .safe: return "Safe"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Follow the iPadOS Guided Access switch."
        case .native:
            return "Force full 1–5 finger gestures for this app."
        case .safe:
            return "Force Fn/Drag zones and 4/5-finger suppression."
        }
    }
}

extension Notification.Name {
    static let gestureModePreferenceDidChange = Notification.Name("vpad.gestureModePreferenceDidChange")
}

/// Tracks the system Guided Access switch. When Guided Access is on, iPadOS
/// multi-task gestures are locked, so the full native gesture set is safe.
/// When it is off, the canvas switches to the reduced "safe" gesture set.
///
/// A manual in-app preference can force either engine mode. It only changes the
/// app's gesture recognizer; it does not enable or disable iPadOS Guided Access
/// itself.
@MainActor
final class GuidedAccessMonitor: ObservableObject {
    static let shared = GuidedAccessMonitor()

    private static let preferenceKey = "vpad.gestureModePreference"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var preference: GestureModePreference

    var isSystemGuidedAccessEnabled: Bool {
        UIAccessibility.isGuidedAccessEnabled
    }

    var badgeTitle: String {
        switch preference {
        case .automatic:
            return isEnabled ? "GUIDED" : "SAFE"
        case .native:
            return "FULL"
        case .safe:
            return "SAFE"
        }
    }

    private init() {
        var stored = UserDefaults.standard
            .string(forKey: Self.preferenceKey)
            .flatMap(GestureModePreference.init(rawValue:)) ?? .automatic

        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["VPAD_GUIDED_ACCESS"] {
            stored = raw == "1" ? .native : .safe
        }
        #endif

        preference = stored
        let systemGuidedAccess = UIAccessibility.isGuidedAccessEnabled
        isEnabled = Self.effectiveEnabled(for: stored, systemGuidedAccess: systemGuidedAccess)
        ScreenEdgeDeferringController.isEnabled = !isEnabled

        NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard preference == .automatic else {
            ScreenEdgeDeferringController.isEnabled = !isEnabled
            return
        }
        let next = UIAccessibility.isGuidedAccessEnabled
        if next != isEnabled {
            isEnabled = next
        }
        ScreenEdgeDeferringController.isEnabled = !isEnabled
    }

    func setPreference(_ next: GestureModePreference) {
        guard next != preference else { return }
        preference = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.preferenceKey)

        let nextEnabled = Self.effectiveEnabled(
            for: next,
            systemGuidedAccess: UIAccessibility.isGuidedAccessEnabled
        )
        if nextEnabled != isEnabled {
            isEnabled = nextEnabled
        }
        ScreenEdgeDeferringController.isEnabled = !isEnabled
        NotificationCenter.default.post(name: .gestureModePreferenceDidChange, object: nil)
    }

    private static func effectiveEnabled(
        for preference: GestureModePreference,
        systemGuidedAccess: Bool
    ) -> Bool {
        switch preference {
        case .automatic: return systemGuidedAccess
        case .native: return true
        case .safe: return false
        }
    }
}

/// A transparent child controller that tells iPadOS to defer all edge gestures
/// in safe mode. SwiftUI's hosting controller is not directly settable, so the
/// representable below injects this child into the hierarchy.
@MainActor
final class ScreenEdgeDeferringController: UIViewController {
    static var isEnabled = false

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        Self.isEnabled ? .all : []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
}

struct ScreenEdgeDeferringView: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> ScreenEdgeDeferringController {
        ScreenEdgeDeferringController.isEnabled = enabled
        return ScreenEdgeDeferringController()
    }

    func updateUIViewController(
        _ uiViewController: ScreenEdgeDeferringController,
        context: Context
    ) {
        ScreenEdgeDeferringController.isEnabled = enabled
        uiViewController.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

/// Hold-state for the safe-mode `Fn` and `Drag` hot zones. This is local input
/// state and is deliberately not sent to the Mac as a modifier bit.
@MainActor
final class SafetyGestureState: ObservableObject {
    static let shared = SafetyGestureState()

    @Published private(set) var isFnHeld = false
    @Published private(set) var isDragHeld = false

    private init() {}

    func setFnHeld(_ value: Bool) {
        guard isFnHeld != value else { return }
        isFnHeld = value
    }

    func setDragHeld(_ value: Bool) {
        guard isDragHeld != value else { return }
        isDragHeld = value
    }

    func clear() {
        isFnHeld = false
        isDragHeld = false
    }
}

// MARK: - Gesture engine

struct GesturePattern: Codable, Identifiable, Sendable, Equatable {
    let id: UInt16
    let tokens: [String]
}

/// Recognizes ≥3-finger gestures forwarded by the canvas. One- and two-finger
/// input stays in the canvas trackpad path and never reaches this engine.
///
/// Native mode (Guided Access ON):
///   3 fingers → drag; 3-finger tap → Look Up
///   4 fingers → Mission Control / App Exposé / Spaces
///   5 fingers → Launchpad (pinch) / Show Desktop (spread)
///
/// Safe mode (Guided Access OFF):
///   3-finger movement is discarded (iPadOS would claim it)
///   3-finger stationary tap → Look Up
@MainActor
final class GestureEngine {
    static let shared = GestureEngine()

    struct Binding: Identifiable, Sendable {
        let id: UInt16
        let title: String
        let detail: String
    }

    private enum StandardAction {
        case lookUp
        case missionControl
        case appExpose
        case desktopLeft
        case desktopRight
        case launchpad
        case showDesktop
    }

    private static let patternsKey = "vpad.gesturePatterns"
    private static let tapSlop: CGFloat = 4
    private static let swipeThreshold: CGFloat = 60
    private static let pinchThreshold: CGFloat = 80

    private(set) var patterns: [GesturePattern]

    private var active = false
    private var fingerCount = 0
    private var startCentroid: CGPoint = .zero
    private var lastCentroid: CGPoint = .zero
    private var startSpread: CGFloat = 0
    private var triggered = false
    private var dragging = false
    private var threeFingerMoved = false
    private var lastTriggerTime: TimeInterval = 0

    private init() {
        patterns = Self.loadPatterns()
    }

    // MARK: - Public descriptions

    var isActive: Bool { active }

    static let bindings: [Binding] = [
        Binding(
            id: 10,
            title: "3-finger tap",
            detail: "Look Up (⌃⌘D) · both modes"
        ),
        Binding(
            id: 11,
            title: "3-finger drag",
            detail: "Guided Access ON · drag window / selection"
        ),
        Binding(
            id: 12,
            title: "4-finger swipe",
            detail: "Guided Access ON · Mission Control / App Exposé / Spaces"
        ),
        Binding(
            id: 13,
            title: "5-finger pinch / spread",
            detail: "Guided Access ON · Launchpad / Show Desktop"
        ),
        Binding(
            id: 14,
            title: "Safe mode",
            detail: "Fn + 2-finger swipe; Drag + 1 finger; 4/5 fingers suppressed"
        )
    ]

    var patternBindings: [Binding] {
        patterns.map { pattern in
            Binding(
                id: pattern.id,
                title: "Pattern \(pattern.id)",
                detail: pattern.tokens.joined(separator: " → ")
            )
        }
    }

    // MARK: - Touch forwarding

    func begin(touches: [UITouch], in view: UIView) {
        guard touches.count >= 3, !active else { return }
        let centroid = Self.centroid(of: touches, in: view)
        active = true
        fingerCount = touches.count
        startCentroid = centroid
        lastCentroid = centroid
        startSpread = Self.spread(of: touches, in: view)
        triggered = false
        dragging = false
        threeFingerMoved = false
    }

    func move(touches: [UITouch], in view: UIView) {
        guard active, !touches.isEmpty else { return }

        let guided = GuidedAccessMonitor.shared.isEnabled
        let count = touches.count
        let centroid = Self.centroid(of: touches, in: view)
        let spread = Self.spread(of: touches, in: view)

        // A finger added mid-gesture promotes the gesture (3 → 4/5). The native
        // path restarts with the new finger count; the safe path cancels.
        if count > fingerCount {
            if guided {
                cancel()
                begin(touches: touches, in: view)
                return
            } else if count >= 4 {
                cancel()
                return
            }
        }

        let moved = hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y)

        if guided {
            switch count {
            case 3:
                if !triggered, moved > Self.tapSlop {
                    triggered = true
                    dragging = true
                    sendTrackpadClick(phase: .began)
                    haptic()
                }
                if dragging {
                    let dx = centroid.x - lastCentroid.x
                    let dy = centroid.y - lastCentroid.y
                    if abs(dx) > 0.01 || abs(dy) > 0.01 {
                        send(VPadPacket.trackpadMove(
                            dx: Float32(dx),
                            dy: Float32(dy),
                            modifiers: ModifierState.shared.snapshot()
                        ))
                    }
                }
            case 4:
                guard !triggered, moved > Self.swipeThreshold else { break }
                let dx = centroid.x - startCentroid.x
                let dy = centroid.y - startCentroid.y
                if abs(dx) >= abs(dy) * 1.3 {
                    perform(dx < 0 ? .desktopLeft : .desktopRight)
                    triggered = true
                } else if abs(dy) >= abs(dx) * 1.3 {
                    perform(dy < 0 ? .missionControl : .appExpose)
                    triggered = true
                }
            case 5:
                guard !triggered else { break }
                let delta = spread - startSpread
                if abs(delta) > Self.pinchThreshold {
                    perform(delta > 0 ? .showDesktop : .launchpad)
                    triggered = true
                }
            default:
                break
            }
        } else if count >= 4 {
            cancel()
            return
        } else if count == 3, moved > Self.tapSlop {
            // Moving three fingers is unsafe without Guided Access; keep the
            // gesture captured but emit nothing.
            threeFingerMoved = true
        }

        lastCentroid = centroid
    }

    func end(remainingTouches: Int) {
        guard active, remainingTouches < fingerCount else { return }
        if dragging {
            sendTrackpadClick(phase: .ended)
            dragging = false
        } else if !triggered, fingerCount == 3, !threeFingerMoved {
            perform(.lookUp)
        }
        reset()
    }

    func cancel() {
        guard active else { return }
        if dragging {
            sendTrackpadClick(phase: .ended)
            dragging = false
        }
        reset()
    }

    // MARK: - Actions

    private func perform(_ action: StandardAction) {
        let now = CACurrentMediaTime()
        guard now - lastTriggerTime > 0.25 else { return }
        lastTriggerTime = now

        switch action {
        case .lookUp:
            send(VPadPacket.keyShortcut(
                keyCode: 2,
                modifiers: ModifierMask.command.rawValue | ModifierMask.control.rawValue
            ))
        case .missionControl:
            send(VPadPacket.systemAction(.missionControl))
        case .appExpose:
            send(VPadPacket.systemAction(.appExpose))
        case .desktopLeft:
            send(VPadPacket.systemAction(.desktopLeft))
        case .desktopRight:
            send(VPadPacket.systemAction(.desktopRight))
        case .launchpad:
            send(VPadPacket.systemAction(.launchpad))
        case .showDesktop:
            // F11 is the macOS Show Desktop key by default.
            send(VPadPacket.keyShortcut(keyCode: 103, modifiers: 0))
        }
        haptic()
    }

    private func sendTrackpadClick(phase: Phase) {
        send(VPadPacket.trackpadClick(
            button: .left,
            phase: phase,
            modifiers: ModifierState.shared.snapshot()
        ))
    }

    private func send(_ packet: VPadPacket) {
        UDPClient.shared.send(packet)
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func reset() {
        active = false
        fingerCount = 0
        startCentroid = .zero
        lastCentroid = .zero
        startSpread = 0
        triggered = false
        dragging = false
        threeFingerMoved = false
    }

    // MARK: - Geometry

    private static func centroid(of touches: [UITouch], in view: UIView) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for touch in touches {
            let point = touch.location(in: view)
            x += point.x
            y += point.y
        }
        return CGPoint(x: x / CGFloat(touches.count), y: y / CGFloat(touches.count))
    }

    private static func spread(of touches: [UITouch], in view: UIView) -> CGFloat {
        guard touches.count > 1 else { return 0 }
        let center = centroid(of: touches, in: view)
        var total: CGFloat = 0
        for touch in touches {
            let point = touch.location(in: view)
            total += hypot(point.x - center.x, point.y - center.y)
        }
        return total / CGFloat(touches.count)
    }

    // MARK: - Persistence

    private static func loadPatterns() -> [GesturePattern] {
        guard let data = UserDefaults.standard.data(forKey: patternsKey),
              let decoded = try? JSONDecoder().decode([GesturePattern].self, from: data) else {
            return []
        }
        return decoded
    }

    func setPatterns(_ newPatterns: [GesturePattern]) {
        patterns = newPatterns
        if let data = try? JSONEncoder().encode(newPatterns) {
            UserDefaults.standard.set(data, forKey: Self.patternsKey)
        }
    }
}
