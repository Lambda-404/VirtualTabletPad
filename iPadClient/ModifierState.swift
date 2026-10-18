import Foundation
import VPadProtocol

/// Lock-protected modifier bitmask shared by the canvas hot path and sidebar UI.
final class ModifierState: @unchecked Sendable {
    static let shared = ModifierState()

    private let lock = NSLock()
    private var flags: UInt16 = 0

    private init() {}

    func snapshot() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return flags
    }

    func set(_ mask: ModifierMask, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            flags |= mask.rawValue
        } else {
            flags &= ~mask.rawValue
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        flags = 0
    }
}
