import Foundation

/// Per-app workflow profile (§4.3).
public struct Profile: Identifiable, Sendable, Codable, Equatable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var name: String
    public var pressureCurve: PressureCurveConfiguration
    public var areaMapping: AreaMappingConfiguration
    public var shortcutLayout: [UInt16]
    public var pencilGestures: PencilGestureBindings
    public var functionKeyActions: [Int: Action]

    public init(
        bundleIdentifier: String,
        name: String,
        pressureCurve: PressureCurveConfiguration = PressureCurveConfiguration(),
        areaMapping: AreaMappingConfiguration = AreaMappingConfiguration(),
        shortcutLayout: [UInt16] = [],
        pencilGestures: PencilGestureBindings = PencilGestureBindings(),
        functionKeyActions: [Int: Action] = [:]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.pressureCurve = pressureCurve
        self.areaMapping = areaMapping
        self.shortcutLayout = shortcutLayout
        self.pencilGestures = pencilGestures
        self.functionKeyActions = functionKeyActions
    }

    public static let `default` = Profile(
        bundleIdentifier: "*",
        name: "Default",
        pressureCurve: PressureCurveConfiguration(preset: .natural),
        areaMapping: AreaMappingConfiguration(),
        shortcutLayout: [0, 1, 2, 3],
        pencilGestures: PencilGestureBindings(),
        functionKeyActions: [:]
    )

    public static let photoshop = Profile(
        bundleIdentifier: "com.adobe.Photoshop",
        name: "Adobe Photoshop",
        pressureCurve: PressureCurveConfiguration(preset: .soft),
        areaMapping: AreaMappingConfiguration(lockAspectRatio: true),
        shortcutLayout: [53, 6, 7, 8],
        pencilGestures: PencilGestureBindings(
            squeezeAction: .key(KeyCombo(keyCode: 49)), // Space / Hand tool
            doubleTapAction: .toggleTool("eraser")
        ),
        functionKeyActions: [1: .key(KeyCombo(keyCode: 6, modifiers: 0x0100))] // Cmd+Z
    )

    public static let krita = Profile(
        bundleIdentifier: "org.krita",
        name: "Krita",
        pressureCurve: PressureCurveConfiguration(preset: .natural),
        areaMapping: AreaMappingConfiguration(lockAspectRatio: true),
        shortcutLayout: [49, 12, 13, 14],
        pencilGestures: PencilGestureBindings(
            squeezeAction: .key(KeyCombo(keyCode: 49)), // Space / Pan
            doubleTapAction: .toggleTool("eraser")
        ),
        functionKeyActions: [1: .key(KeyCombo(keyCode: 6, modifiers: 0x0100))] // Cmd+Z
    )

    public static let blender = Profile(
        bundleIdentifier: "org.blenderfoundation.blender",
        name: "Blender",
        pressureCurve: PressureCurveConfiguration(preset: .hard),
        areaMapping: AreaMappingConfiguration(),
        shortcutLayout: [49, 56, 55, 58],
        pencilGestures: PencilGestureBindings(
            squeezeAction: .key(KeyCombo(keyCode: 53)), // Esc
            doubleTapAction: .key(KeyCombo(keyCode: 48)) // Tab
        ),
        functionKeyActions: [1: .key(KeyCombo(keyCode: 6, modifiers: 0x0100))] // Cmd+Z
    )

    public static let defaultProfiles: [Profile] = [
        .default,
        .photoshop,
        .krita,
        .blender
    ]
}

/// Storage and lookup registry for per-app profiles (§4.3).
public struct ProfileStore: Sendable, Codable, Equatable {
    public var profiles: [Profile]

    public init(profiles: [Profile] = Profile.defaultProfiles) {
        self.profiles = profiles
    }

    public func profile(for bundleID: String) -> Profile {
        if let match = profiles.first(where: { $0.bundleIdentifier == bundleID }) {
            return match
        }
        return profiles.first(where: { $0.bundleIdentifier == "*" }) ?? .default
    }

    public mutating func setProfile(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.bundleIdentifier == profile.bundleIdentifier }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
    }
}
