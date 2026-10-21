import CoreGraphics
import Foundation
import os
import VPadProtocol

struct KeyStroke: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt16

    init(keyCode: UInt16, modifiers: UInt16 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

enum GestureAction: Equatable, Sendable {
    case keyMacro([KeyStroke])
    case runScript(path: String, arguments: [String])
}

extension GestureAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case strokes
        case path
        case arguments
    }

    private enum Kind: String, Codable {
        case keyMacro
        case runScript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .keyMacro:
            self = .keyMacro(try container.decode([KeyStroke].self, forKey: .strokes))
        case .runScript:
            self = .runScript(
                path: try container.decode(String.self, forKey: .path),
                arguments: try container.decode([String].self, forKey: .arguments)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyMacro(let strokes):
            try container.encode(Kind.keyMacro, forKey: .kind)
            try container.encode(strokes, forKey: .strokes)
        case .runScript(let path, let arguments):
            try container.encode(Kind.runScript, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

/// GestureID → action map persisted as JSON in UserDefaults.
final class GestureMapper: @unchecked Sendable {
    static let shared = GestureMapper()

    private static let storageKey = "vpad.gestureActions"
    private static let log = Logger(subsystem: "com.vpad.MacHost", category: "gesture")

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var actions: [UInt16: GestureAction]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.actions = Self.load(defaults: defaults)
    }

    // MARK: - Store

    func action(for id: UInt16) -> GestureAction? {
        lock.lock()
        defer { lock.unlock() }
        return actions[id]
    }

    func allActions() -> [UInt16: GestureAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    @discardableResult
    func replaceAll(_ newActions: [UInt16: GestureAction]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        actions = newActions
        return saveLocked()
    }

    @discardableResult
    func resetToDefaults() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        actions = Self.makeDefaults()
        return saveLocked()
    }

    // MARK: - Execution

    func perform(_ action: GestureAction) {
        switch action {
        case .keyMacro(let strokes):
            let mapped = strokes.map { stroke in
                (CGKeyCode(stroke.keyCode), EventInjector.shared.mapModifiers(stroke.modifiers))
            }
            EventInjector.shared.performKeyStrokes(mapped)
        case .runScript(let path, let arguments):
            Self.runScript(path: path, arguments: arguments)
        }
    }

    func describe(_ action: GestureAction) -> String {
        switch action {
        case .keyMacro(let strokes):
            guard !strokes.isEmpty else { return "Key macro (empty)" }
            return strokes.map(Self.describeStroke).joined(separator: " → ")
        case .runScript(let path, let arguments):
            let suffix = arguments.isEmpty ? "" : " " + arguments.joined(separator: " ")
            return "Script: \(path)\(suffix)"
        }
    }

    // MARK: - Defaults

    static func makeDefaults() -> [UInt16: GestureAction] {
        [
            VPadConstants.defaultGestureCommandTab: .keyMacro([
                KeyStroke(keyCode: VPadKeycode.tab, modifiers: ModifierMask.command.rawValue)
            ]),
            VPadConstants.defaultGestureDarkMode: .runScript(
                path: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
                ]
            ),
            VPadConstants.defaultGestureTerminal: .runScript(
                path: "/usr/bin/open",
                arguments: ["-a", "Terminal"]
            )
        ]
    }

    // MARK: - Persistence

    private static func load(defaults: UserDefaults) -> [UInt16: GestureAction] {
        guard let data = defaults.data(forKey: storageKey) else {
            return makeDefaults()
        }
        do {
            let decoded = try JSONDecoder().decode([String: GestureAction].self, from: data)
            var result: [UInt16: GestureAction] = [:]
            for (key, value) in decoded {
                if let id = UInt16(key) {
                    result[id] = value
                }
            }
            return result.isEmpty ? makeDefaults() : result
        } catch {
            log.error("failed to decode gesture map: \(error.localizedDescription, privacy: .public)")
            return makeDefaults()
        }
    }

    private func saveLocked() -> Bool {
        do {
            let encoded: [String: GestureAction] = Dictionary(
                uniqueKeysWithValues: actions.map { (String($0.key), $0.value) }
            )
            let data = try JSONEncoder().encode(encoded)
            defaults.set(data, forKey: Self.storageKey)
            return true
        } catch {
            Self.log.error("failed to encode gesture map: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Script execution

    private static func runScript(path: String, arguments: [String]) {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            log.error("gesture script is not an executable absolute path: \(path, privacy: .public)")
            return
        }

        if ProcessInfo.processInfo.environment["VPAD_DRY_RUN_INJECT"] == "1" {
            let line = "[DRY_RUN] SCRIPT path=\(path) arguments=\(arguments)\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
            log.notice("VPAD_DRY_RUN SCRIPT path=\(path, privacy: .public) args=\(arguments, privacy: .public)")
            return
        }

        let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            if extensionName == "scpt" || extensionName == "applescript" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [path] + arguments
            } else if extensionName == "sh" {
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [path] + arguments
            } else {
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    log.error("gesture script exited with \(process.terminationStatus, privacy: .public)")
                }
            } catch {
                log.error("failed to run gesture script: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func describeStroke(_ stroke: KeyStroke) -> String {
        var prefix = ""
        if stroke.modifiers & ModifierMask.command.rawValue != 0 { prefix += "⌘" }
        if stroke.modifiers & ModifierMask.shift.rawValue != 0 { prefix += "⇧" }
        if stroke.modifiers & ModifierMask.option.rawValue != 0 { prefix += "⌥" }
        if stroke.modifiers & ModifierMask.control.rawValue != 0 { prefix += "⌃" }
        if stroke.modifiers & ModifierMask.space.rawValue != 0 { prefix += "Space+" }
        return "\(prefix)key \(stroke.keyCode)"
    }
}
