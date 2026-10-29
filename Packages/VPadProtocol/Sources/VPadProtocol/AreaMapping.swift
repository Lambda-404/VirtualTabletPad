import Foundation
import CoreGraphics

/// Tablet physical orientation (§4.1).
public enum TabletRotation: Int, Sendable, Codable, CaseIterable {
    case rotation0 = 0
    case rotation90 = 90
    case rotation180 = 180
    case rotation270 = 270
}

/// Explicit rectangular region in global screen coordinates (§4.1).
public struct MappingRegion: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    public static func from(cgRect: CGRect) -> MappingRegion {
        MappingRegion(
            x: Double(cgRect.origin.x),
            y: Double(cgRect.origin.y),
            width: Double(cgRect.size.width),
            height: Double(cgRect.size.height)
        )
    }
}

/// Area mapping configuration for digitizer input mapping (§4.1).
public struct AreaMappingConfiguration: Sendable, Codable, Equatable {
    public var targetDisplayID: UInt32?
    public var customRegion: MappingRegion?
    public var lockAspectRatio: Bool
    public var tabletAspectRatio: Double
    public var rotation: TabletRotation
    public var isLeftHanded: Bool

    public init(
        targetDisplayID: UInt32? = nil,
        customRegion: MappingRegion? = nil,
        lockAspectRatio: Bool = false,
        tabletAspectRatio: Double = 4.0 / 3.0,
        rotation: TabletRotation = .rotation0,
        isLeftHanded: Bool = false
    ) {
        self.targetDisplayID = targetDisplayID
        self.customRegion = customRegion
        self.lockAspectRatio = lockAspectRatio
        self.tabletAspectRatio = tabletAspectRatio > 0 ? tabletAspectRatio : 4.0 / 3.0
        self.rotation = rotation
        self.isLeftHanded = isLeftHanded
    }

    /// Maps normalized tablet coordinates (0.0 ... 1.0) to screen coordinates.
    public func map(normalizedX: Double, normalizedY: Double, displayBounds: CGRect) -> CGPoint {
        guard normalizedX.isFinite, normalizedY.isFinite else {
            return displayBounds.origin
        }

        let clampedX = min(max(normalizedX, 0.0), 1.0)
        let clampedY = min(max(normalizedY, 0.0), 1.0)

        // 1. Calculate effective rotation angle combining rotation and left-handed mode
        var effectiveDegrees = rotation.rawValue
        if isLeftHanded {
            effectiveDegrees = (effectiveDegrees + 180) % 360
        }

        // 2. Apply rotation to normalized point
        let rotX: Double
        let rotY: Double
        switch effectiveDegrees {
        case 90:
            rotX = 1.0 - clampedY
            rotY = clampedX
        case 180:
            rotX = 1.0 - clampedX
            rotY = 1.0 - clampedY
        case 270:
            rotX = clampedY
            rotY = 1.0 - clampedX
        default: // 0
            rotX = clampedX
            rotY = clampedY
        }

        // 3. Determine base bounding box
        let baseRect: CGRect
        if let custom = customRegion?.cgRect, custom.width > 0, custom.height > 0 {
            baseRect = custom
        } else {
            baseRect = displayBounds
        }

        guard baseRect.width > 0, baseRect.height > 0 else {
            return displayBounds.origin
        }

        // 4. Calculate active target rect with optional aspect ratio lock
        let targetRect: CGRect
        if lockAspectRatio {
            let rotatedAspect = (effectiveDegrees == 90 || effectiveDegrees == 270)
                ? (1.0 / tabletAspectRatio)
                : tabletAspectRatio

            let baseAspect = Double(baseRect.width / baseRect.height)
            if baseAspect > rotatedAspect {
                // Base is wider than tablet: letterbox left and right
                let targetWidth = CGFloat(Double(baseRect.height) * rotatedAspect)
                let offsetX = baseRect.origin.x + (baseRect.width - targetWidth) / 2.0
                targetRect = CGRect(x: offsetX, y: baseRect.origin.y, width: targetWidth, height: baseRect.height)
            } else {
                // Base is taller than tablet: letterbox top and bottom
                let targetHeight = CGFloat(Double(baseRect.width) / rotatedAspect)
                let offsetY = baseRect.origin.y + (baseRect.height - targetHeight) / 2.0
                targetRect = CGRect(x: baseRect.origin.x, y: offsetY, width: baseRect.width, height: targetHeight)
            }
        } else {
            targetRect = baseRect
        }

        // 5. Map to global display coordinates
        let screenX = targetRect.origin.x + CGFloat(rotX) * max(targetRect.width - 1.0, 1.0)
        let screenY = targetRect.origin.y + CGFloat(rotY) * max(targetRect.height - 1.0, 1.0)

        // Clamp to enclosing display bounds to avoid escaping monitor
        let clampedScreenX = min(max(screenX, displayBounds.minX), max(displayBounds.maxX - 1.0, displayBounds.minX))
        let clampedScreenY = min(max(screenY, displayBounds.minY), max(displayBounds.maxY - 1.0, displayBounds.minY))

        return CGPoint(x: clampedScreenX, y: clampedScreenY)
    }
}
