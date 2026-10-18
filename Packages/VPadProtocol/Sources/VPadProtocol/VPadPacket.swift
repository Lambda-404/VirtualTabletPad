import Foundation

public enum TrackpadButton: Sendable {
    case left
    case right

    /// The wire protocol encodes the button in the `pressure` sentinel field.
    public var pressureSentinel: Float32 {
        switch self {
        case .left: return 1.0
        case .right: return 2.0
        }
    }
}

/// Frozen 28-byte core packet (§2.1).
///
/// Stored properties intentionally have internal setters: callers construct
/// packets through the typed factories below so field multiplexing rules from
/// §2.2 cannot be violated accidentally.
@frozen
public struct VPadPacket: Equatable, Sendable {
    public internal(set) var type: UInt8
    public internal(set) var phase: UInt8
    public internal(set) var modifiers: UInt16
    public internal(set) var x: Float32
    public internal(set) var y: Float32
    public internal(set) var pressure: Float32
    public internal(set) var tiltX: Float32
    public internal(set) var tiltY: Float32
    public internal(set) var rollAngle: Float32

    internal init(
        type: UInt8,
        phase: UInt8,
        modifiers: UInt16 = 0,
        x: Float32 = 0,
        y: Float32 = 0,
        pressure: Float32 = 0,
        tiltX: Float32 = 0,
        tiltY: Float32 = 0,
        rollAngle: Float32 = 0
    ) {
        self.type = type
        self.phase = phase
        self.modifiers = modifiers
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.rollAngle = rollAngle
    }

    @inlinable
    public func toData() -> Data {
        withUnsafeBytes(of: self) { Data($0) }
    }

    @inlinable
    public static func fromData(_ data: Data) -> VPadPacket? {
        guard data.count == 28 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: VPadPacket.self) }
    }

    /// System-level media/brightness/Mission Control action.
    public static func systemAction(_ action: SystemAction) -> VPadPacket {
        VPadPacket(
            type: EventType.systemAction.rawValue,
            phase: Phase.began.rawValue,
            x: Float32(action.rawValue)
        )
    }

    // MARK: - Trackpad factories

    public static func trackpadMove(dx: Float32, dy: Float32, modifiers: UInt16 = 0) -> VPadPacket {
        VPadPacket(
            type: EventType.trackpadMove.rawValue,
            phase: Phase.moved.rawValue,
            modifiers: modifiers,
            x: finite(dx),
            y: finite(dy)
        )
    }

    public static func trackpadScroll(dx: Float32, dy: Float32, modifiers: UInt16 = 0) -> VPadPacket {
        VPadPacket(
            type: EventType.trackpadScroll.rawValue,
            phase: Phase.moved.rawValue,
            modifiers: modifiers,
            x: finite(dx),
            y: finite(dy)
        )
    }

    public static func trackpadClick(
        button: TrackpadButton,
        phase: Phase,
        modifiers: UInt16 = 0
    ) -> VPadPacket {
        VPadPacket(
            type: EventType.trackpadClick.rawValue,
            phase: phase.rawValue,
            modifiers: modifiers,
            pressure: button.pressureSentinel
        )
    }

    // MARK: - Stylus factories

    public static func stylusStroke(
        x: Float32,
        y: Float32,
        pressure: Float32,
        tiltX: Float32,
        tiltY: Float32,
        rollAngle: Float32,
        phase: Phase,
        modifiers: UInt16 = 0
    ) -> VPadPacket {
        VPadPacket(
            type: EventType.stylusStroke.rawValue,
            phase: phase.rawValue,
            modifiers: modifiers,
            x: clamp01(x),
            y: clamp01(y),
            pressure: clamp01(pressure),
            tiltX: clampBipolar(tiltX),
            tiltY: clampBipolar(tiltY),
            rollAngle: clampRoll(rollAngle)
        )
    }

    public static func stylusHover(
        x: Float32,
        y: Float32,
        tiltX: Float32,
        tiltY: Float32,
        rollAngle: Float32,
        phase: Phase = .moved,
        modifiers: UInt16 = 0
    ) -> VPadPacket {
        VPadPacket(
            type: EventType.stylusHover.rawValue,
            phase: phase.rawValue,
            modifiers: modifiers,
            x: clamp01(x),
            y: clamp01(y),
            tiltX: clampBipolar(tiltX),
            tiltY: clampBipolar(tiltY),
            rollAngle: clampRoll(rollAngle)
        )
    }

    public static func stylusProximity(phase: Phase) -> VPadPacket {
        VPadPacket(type: EventType.stylusProximity.rawValue, phase: phase.rawValue)
    }

    public static func stylusSqueeze(
        x: Float32,
        y: Float32,
        rollAngle: Float32,
        modifiers: UInt16 = 0
    ) -> VPadPacket {
        VPadPacket(
            type: EventType.stylusSqueeze.rawValue,
            phase: Phase.began.rawValue,
            modifiers: modifiers,
            x: clamp01(x),
            y: clamp01(y),
            rollAngle: clampRoll(rollAngle)
        )
    }

    public static func stylusDoubleTap(modifiers: UInt16 = 0) -> VPadPacket {
        VPadPacket(
            type: EventType.stylusDoubleTap.rawValue,
            phase: Phase.began.rawValue,
            modifiers: modifiers
        )
    }

    // MARK: - Keyboard / gesture factories

    public static func keyShortcut(keyCode: UInt16, modifiers: UInt16 = 0) -> VPadPacket {
        VPadPacket(
            type: EventType.keyShortcut.rawValue,
            phase: Phase.began.rawValue,
            modifiers: modifiers,
            rollAngle: Float32(keyCode)
        )
    }

    public static func keyboardPress(
        keyCode: UInt16,
        phase: Phase,
        modifiers: UInt16 = 0
    ) -> VPadPacket {
        VPadPacket(
            type: EventType.keyboardPress.rawValue,
            phase: phase.rawValue,
            modifiers: modifiers,
            rollAngle: Float32(keyCode)
        )
    }

    public static func customGesture(id: UInt16, phase: Phase = .began) -> VPadPacket {
        VPadPacket(
            type: EventType.customGesture.rawValue,
            phase: phase.rawValue,
            modifiers: id
        )
    }

    // MARK: - Helpers

    private static func finite(_ value: Float32, fallback: Float32 = 0) -> Float32 {
        value.isFinite ? value : fallback
    }

    private static func clamp01(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func clampBipolar(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        return min(max(value, -1), 1)
    }

    private static func clampRoll(_ value: Float32) -> Float32 {
        guard value.isFinite else { return 0 }
        let pi = Float32.pi
        return min(max(value, -pi), pi)
    }
}
