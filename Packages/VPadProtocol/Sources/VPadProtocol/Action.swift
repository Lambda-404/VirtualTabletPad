import Foundation

/// Key combination representing a virtual keycode and modifier bitmask (§4.4).
public struct KeyCombo: Sendable, Codable, Equatable, Hashable {
    public var keyCode: UInt16
    public var modifiers: UInt16

    public init(keyCode: UInt16, modifiers: UInt16 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Atomic execution step within a timed macro sequence (§4.4).
public enum MacroStep: Sendable, Codable, Equatable, Hashable {
    case keyDown(UInt16, modifiers: UInt16)
    case keyUp(UInt16)
    case delayMs(UInt32)
}

/// Extensible action model assignable to Pencil squeeze, double-tap, and F-keys (§4.4).
public enum Action: Sendable, Codable, Equatable, Hashable {
    case key(KeyCombo)
    case systemAction(SystemAction)
    case macro([MacroStep])
    case toggleTool(String)

    public var title: String {
        switch self {
        case .key(let combo):
            return "Key (\(combo.keyCode))"
        case .systemAction(let sys):
            return sys.displayName
        case .macro(let steps):
            return "Macro (\(steps.count) steps)"
        case .toggleTool(let tool):
            return "Tool: \(tool.capitalized)"
        }
    }
}

extension SystemAction {
    public var displayName: String {
        switch self {
        case .brightnessDown: return "Brightness Down"
        case .brightnessUp: return "Brightness Up"
        case .missionControl: return "Mission Control"
        case .launchpad: return "Launchpad"
        case .appExpose: return "App Exposé"
        case .desktopLeft: return "Desktop Left"
        case .desktopRight: return "Desktop Right"
        case .previousTrack: return "Previous Track"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .mute: return "Mute"
        case .volumeDown: return "Volume Down"
        case .volumeUp: return "Volume Up"
        }
    }
}

/// Action bindings for Apple Pencil gestures (§4.4).
public struct PencilGestureBindings: Sendable, Codable, Equatable, Hashable {
    public var squeezeAction: Action
    public var doubleTapAction: Action

    public init(
        squeezeAction: Action = .key(KeyCombo(keyCode: 53)), // Esc / Menu
        doubleTapAction: Action = .toggleTool("eraser")
    ) {
        self.squeezeAction = squeezeAction
        self.doubleTapAction = doubleTapAction
    }
}

/// Protocol for delivering actions to the host network transport or local application (§4.4).
@MainActor
public protocol ActionDispatcher: AnyObject {
    func sendShortcut(keyCode: UInt16, modifiers: UInt16)
    func sendKeyboardPress(keyCode: UInt16, phase: Phase, modifiers: UInt16)
    func sendSystemAction(_ action: SystemAction)
    func selectTool(_ tool: String)
}

/// Executes actions asynchronously (§4.4).
@MainActor
public enum ActionRunner {
    public static func execute(_ action: Action, via dispatcher: ActionDispatcher) {
        switch action {
        case .key(let combo):
            dispatcher.sendShortcut(keyCode: combo.keyCode, modifiers: combo.modifiers)
        case .systemAction(let sys):
            dispatcher.sendSystemAction(sys)
        case .macro(let steps):
            Task { @MainActor in
                for step in steps {
                    switch step {
                    case .keyDown(let code, let mods):
                        dispatcher.sendKeyboardPress(keyCode: code, phase: .began, modifiers: mods)
                    case .keyUp(let code):
                        dispatcher.sendKeyboardPress(keyCode: code, phase: .ended, modifiers: 0)
                    case .delayMs(let ms):
                        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    }
                }
            }
        case .toggleTool(let tool):
            dispatcher.selectTool(tool)
        }
    }
}
