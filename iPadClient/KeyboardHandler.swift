import SwiftUI
import UIKit
import VPadProtocol

enum KeyboardMode: String, CaseIterable, Identifiable {
    case off
    case hardware
    case software

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Keyboard Off"
        case .hardware: return "Hardware Keyboard"
        case .software: return "Software Keyboard"
        }
    }
}

/// Text sink for the software keyboard. `UITextField` does not call
/// `shouldChangeCharactersIn` reliably when it is empty, so the backspace is
/// captured at the `UIKeyInput` layer instead. `super` is intentionally not
/// called: the field must stay empty so every key remains a remote key press.
@MainActor
private final class BackspaceTextField: UITextField {
    var onBackspace: (() -> Void)?

    override func deleteBackward() {
        onBackspace?()
    }
}

/// Hidden first-responder view for hardware keys plus a hidden text field for
/// the software keyboard. Both paths produce 0x21 KeyboardPress packets.
@MainActor
final class KeyboardCaptureView: UIView, UITextFieldDelegate {
    private let textField = BackspaceTextField()
    private var currentMode: KeyboardMode = .off
    private var hardwareModifiers: UInt16 = 0
    private var pressedKeyCodes = Set<UInt16>()
    private var lastDeleteTimestamp: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        textField.delegate = self
        textField.onBackspace = { [weak self] in
            self?.requestDelete()
        }
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.keyboardType = .asciiCapable
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.backgroundColor = .clear
        textField.alpha = 0.01
        textField.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(textField)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var canBecomeFirstResponder: Bool { true }

    func activate(_ mode: KeyboardMode) {
        guard mode != currentMode else { return }
        if currentMode != .off {
            releaseAllKeys()
        }
        currentMode = mode
        switch mode {
        case .off:
            textField.resignFirstResponder()
            resignFirstResponder()
        case .hardware:
            textField.resignFirstResponder()
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
        case .software:
            resignFirstResponder()
            textField.text = ""
            DispatchQueue.main.async { [weak self] in
                self?.textField.becomeFirstResponder()
            }
        }
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let hid = UInt16(key.keyCode.rawValue)
            if handleModifier(hid, down: true) { continue }
            guard let macKey = Self.macKeyCode(for: hid) else { continue }
            let modifiers = hardwareModifiers
                | Self.modifiers(from: key.modifierFlags)
                | ModifierState.shared.snapshot()
            pressedKeyCodes.insert(macKey)
            UDPClient.shared.send(VPadPacket.keyboardPress(
                keyCode: macKey,
                phase: .began,
                modifiers: modifiers
            ))
        }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let hid = UInt16(key.keyCode.rawValue)
            guard let macKey = Self.macKeyCode(for: hid) else { continue }
            let modifiers = hardwareModifiers
                | Self.modifiers(from: key.modifierFlags)
                | ModifierState.shared.snapshot()
            UDPClient.shared.send(VPadPacket.keyboardPress(
                keyCode: macKey,
                phase: .moved,
                modifiers: modifiers
            ))
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let hid = UInt16(key.keyCode.rawValue)
            if handleModifier(hid, down: false) { continue }
            guard let macKey = Self.macKeyCode(for: hid) else { continue }
            pressedKeyCodes.remove(macKey)
            let modifiers = hardwareModifiers
                | Self.modifiers(from: key.modifierFlags)
                | ModifierState.shared.snapshot()
            UDPClient.shared.send(VPadPacket.keyboardPress(
                keyCode: macKey,
                phase: .ended,
                modifiers: modifiers
            ))
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseAllKeys()
    }

    // MARK: - Software keyboard

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        // On an empty field UIKit may report backspace as an empty replacement
        // with a zero-length range (or only call deleteBackward), so an empty
        // string is always a delete. requestDelete de-duplicates the two paths.
        if string.isEmpty {
            requestDelete()
            return false
        }
        for character in string {
            guard let (keyCode, shift) = Self.softwareKey(for: character) else { continue }
            sendSoftwareKey(keyCode, shift: shift)
        }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendSoftwareKey(36, shift: false)
        return false
    }

    /// Sends macOS Backspace (51). `BackspaceTextField.deleteBackward` and the
    /// delegate callback can both fire for one physical key press; the 30 ms
    /// window collapses them without swallowing key auto-repeat.
    private func requestDelete() {
        let now = CACurrentMediaTime()
        guard now - lastDeleteTimestamp >= 0.03 else { return }
        lastDeleteTimestamp = now
        #if DEBUG
        NSLog("VPAD_KEYBOARD software delete → mac 51")
        #endif
        sendSoftwareKey(VPadKeycode.delete, shift: false)
    }

    private func sendSoftwareKey(_ keyCode: UInt16, shift: Bool) {
        var modifiers = ModifierState.shared.snapshot()
        if shift {
            modifiers |= ModifierMask.shift.rawValue
        }
        UDPClient.shared.send(VPadPacket.keyboardPress(
            keyCode: keyCode,
            phase: .began,
            modifiers: modifiers
        ))
        UDPClient.shared.send(VPadPacket.keyboardPress(
            keyCode: keyCode,
            phase: .ended,
            modifiers: modifiers
        ))
    }

    // MARK: - Key state

    private func handleModifier(_ hid: UInt16, down: Bool) -> Bool {
        let mask: UInt16
        switch hid {
        case 0xE0, 0xE4: mask = ModifierMask.control.rawValue
        case 0xE1, 0xE5: mask = ModifierMask.shift.rawValue
        case 0xE2, 0xE6: mask = ModifierMask.option.rawValue
        case 0xE3, 0xE7: mask = ModifierMask.command.rawValue
        default: return false
        }
        if down {
            hardwareModifiers |= mask
        } else {
            hardwareModifiers &= ~mask
        }
        return true
    }

    private func releaseAllKeys() {
        hardwareModifiers = 0
        pressedKeyCodes.removeAll()
        UDPClient.shared.send(VPadPacket.keyboardPress(
            keyCode: 0,
            phase: .cancelled,
            modifiers: ModifierState.shared.snapshot()
        ))
    }

    // MARK: - HID → macOS virtual key codes

    private static func modifiers(from flags: UIKeyModifierFlags) -> UInt16 {
        var mask: UInt16 = 0
        if flags.contains(.command) { mask |= ModifierMask.command.rawValue }
        if flags.contains(.shift) || flags.contains(.alphaShift) { mask |= ModifierMask.shift.rawValue }
        if flags.contains(.alternate) { mask |= ModifierMask.option.rawValue }
        if flags.contains(.control) { mask |= ModifierMask.control.rawValue }
        return mask
    }

    private static let macKeyMap: [UInt16: UInt16] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4,
        0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31,
        0x13: 35, 0x14: 12, 0x15: 15, 0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9,
        0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26,
        0x25: 28, 0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49,
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42, 0x33: 41, 0x34: 39,
        0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44,
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97,
        0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121,
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        0x54: 75, 0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76,
        0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87, 0x5E: 88,
        0x5F: 89, 0x60: 91, 0x61: 92, 0x62: 82, 0x63: 65, 0x67: 81
    ]

    private static func macKeyCode(for hid: UInt16) -> UInt16? {
        macKeyMap[hid]
    }

    private static func softwareKey(for character: Character) -> (UInt16, Bool)? {
        if let ascii = character.asciiValue {
            switch ascii {
            case 0x61...0x7A: // a...z
                let hid: UInt16 = 0x04 + UInt16(ascii - 0x61)
                guard let keyCode = macKeyMap[hid] else { return nil }
                return (keyCode, false)
            case 0x41...0x5A: // A...Z
                let hid: UInt16 = 0x04 + UInt16(ascii - 0x41)
                guard let keyCode = macKeyMap[hid] else { return nil }
                return (keyCode, true)
            case 0x30...0x39: // 0...9
                // In USB HID, keys 1..9 are 0x1E..0x26, and key 0 is 0x27 (at the end of the row).
                let hid: UInt16 = ascii == 0x30 ? 0x27 : (0x1E + UInt16(ascii - 0x31))
                guard let keyCode = macKeyMap[hid] else { return nil }
                return (keyCode, false)
            default:
                break
            }
        }

        switch character {
        case " ": return (49, false)
        case "\n", "\r": return (36, false)
        case "\t": return (48, false)
        case "-": return (27, false)
        case "_": return (27, true)
        case "=": return (24, false)
        case "+": return (24, true)
        case "[": return (33, false)
        case "{": return (33, true)
        case "]": return (30, false)
        case "}": return (30, true)
        case "\\": return (42, false)
        case "|": return (42, true)
        case ";": return (41, false)
        case ":": return (41, true)
        case "'": return (39, false)
        case "\"": return (39, true)
        case "`": return (50, false)
        case "~": return (50, true)
        case ",": return (43, false)
        case "<": return (43, true)
        case ".": return (47, false)
        case ">": return (47, true)
        case "/": return (44, false)
        case "?": return (44, true)
        case "!": return (18, true)
        case "@": return (19, true)
        case "#": return (20, true)
        case "$": return (21, true)
        case "%": return (23, true)
        case "^": return (22, true)
        case "&": return (26, true)
        case "*": return (28, true)
        case "(": return (25, true)
        case ")": return (29, true)
        default: return nil
        }
    }
}

struct KeyboardHost: UIViewRepresentable {
    @Binding var mode: KeyboardMode

    func makeUIView(context: Context) -> KeyboardCaptureView {
        KeyboardCaptureView(frame: .zero)
    }

    func updateUIView(_ uiView: KeyboardCaptureView, context: Context) {
        uiView.activate(mode)
    }
}
