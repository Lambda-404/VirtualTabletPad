import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt
import Foundation
import os
import VPadProtocol

/// Synthesizes macOS input events. All calls are expected from the single
/// `com.vpad.network` serial queue; macro key-ups are posted on a separate
/// utility queue and do not mutate injector state.
final class EventInjector: @unchecked Sendable {
    static let shared = EventInjector()

    private let log = Logger(subsystem: "com.vpad.MacHost", category: "inject")
    private let eventSource: CGEventSource?
    private let poster: any EventPosting
    private let screenBoundsProvider: @Sendable () -> CGRect
    private let pointerLocationProvider: @Sendable () -> CGPoint
    private let warpCursorHandler: @Sendable (CGPoint) -> Void
    private let macroQueue = DispatchQueue(label: "com.vpad.macro", qos: .utility)
    private let isDryRun: Bool

    private var isSpacebarHeld = false
    private var isLeftMouseDown = false
    private var isRightMouseDown = false
    private var isStylusDown = false
    private var isStylusInProximity = false
    private var keyboardDown: [CGKeyCode: CGEventFlags] = [:]
    private var didWakeDisplay = false

    init(
        poster: any EventPosting = DefaultEventPoster(),
        eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState),
        screenBoundsProvider: (@Sendable () -> CGRect)? = nil,
        pointerLocationProvider: (@Sendable () -> CGPoint)? = nil,
        warpCursorHandler: (@Sendable (CGPoint) -> Void)? = nil,
        isDryRun: Bool = ProcessInfo.processInfo.environment["VPAD_DRY_RUN_INJECT"] == "1"
    ) {
        self.poster = poster
        self.eventSource = eventSource
        self.screenBoundsProvider = screenBoundsProvider ?? {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            guard bounds.width > 0, bounds.height > 0 else {
                return CGRect(x: 0, y: 0, width: 1920, height: 1080)
            }
            return bounds
        }
        self.pointerLocationProvider = pointerLocationProvider ?? {
            CGEvent(source: nil)?.location ?? .zero
        }
        self.warpCursorHandler = warpCursorHandler ?? { point in
            CGWarpMouseCursorPosition(point)
        }
        self.isDryRun = isDryRun
    }

    private func logDryRun(_ message: String) {
        log.notice("VPAD_DRY_RUN \(message, privacy: .public)")
        let line = "[DRY_RUN] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
            try? FileHandle.standardOutput.synchronize()
        }
    }

    // MARK: - Public entry points

    func inject(_ packet: VPadPacket) {
        guard let type = EventType(rawValue: packet.type) else { return }

        // `0x40` reuses `modifiers` for the GestureID, not modifier bits.
        let usesModifierBits = type != .customGesture
        if usesModifierBits {
            updateSpacebar(for: packet.modifiers)
        }
        let flags = usesModifierBits ? mapModifiers(packet.modifiers) : []

        switch type {
        case .trackpadMove:
            injectTrackpadMove(packet, flags: flags)
        case .trackpadScroll:
            injectTrackpadScroll(packet, flags: flags)
        case .trackpadClick:
            injectTrackpadClick(packet, flags: flags)
        case .stylusStroke, .stylusHover:
            injectStylus(packet, isHover: type == .stylusHover, flags: flags)
        case .stylusProximity:
            injectProximity(packet, flags: flags)
        case .stylusSqueeze:
            injectSqueeze(packet, flags: flags)
        case .stylusDoubleTap:
            guard packet.phase == Phase.began.rawValue else { return }
            postAtomicKey(CGKeyCode(VPadKeycode.e), flags: flags)
        case .keyShortcut:
            guard packet.phase == Phase.began.rawValue,
                  let keyCode = keyCode(from: packet.rollAngle) else { return }
            if keyCode == CGKeyCode(103), flags.isEmpty {
                performDockExposeAction("AXExposeShowDesktop") { [weak self] in
                    self?.postAtomicKey(keyCode, flags: flags)
                }
                return
            }
            postAtomicKey(keyCode, flags: flags)
        case .keyboardPress:
            injectKeyboard(packet, flags: flags)
        case .systemAction:
            guard packet.phase == Phase.began.rawValue,
                  let action = SystemAction(rawValue: UInt8(clamping: Int(packet.x))) else { return }
            injectSystemAction(action)
        case .customGesture:
            guard packet.phase == Phase.began.rawValue else { return }
            let gestureID = packet.modifiers
            guard let action = GestureMapper.shared.action(for: gestureID) else {
                log.info("unmapped gesture id \(gestureID, privacy: .public)")
                return
            }
            GestureMapper.shared.perform(action)
        case .heartbeat:
            reconcile(with: packet)
        case .hostAck, .ping, .pong:
            // Control plane packets are processed at the network layer and never injected as OS events.
            break
        }
    }

    // MARK: - Testing inspections

    var stylusDown: Bool { isStylusDown }
    var stylusInProximity: Bool { isStylusInProximity }
    var leftMouseDown: Bool { isLeftMouseDown }
    var rightMouseDown: Bool { isRightMouseDown }
    var spacebarHeld: Bool { isSpacebarHeld }

    // MARK: - Heartbeat & State Reconciliation (§3.2)

    func reconcile(with packet: VPadPacket) {
        let flags = mapModifiers(packet.modifiers)
        updateSpacebar(for: packet.modifiers)

        // 1. Reconcile mouse / trackpad buttons
        let wantLeft = (packet.heartbeatButtonMask & HeartbeatButtonMask.leftButton) != 0
        let wantRight = (packet.heartbeatButtonMask & HeartbeatButtonMask.rightButton) != 0
        let location = currentPointerLocation()

        if isLeftMouseDown != wantLeft {
            isLeftMouseDown = wantLeft
            postMouse(wantLeft ? .leftMouseDown : .leftMouseUp, at: location, button: .left, flags: flags)
        }

        if isRightMouseDown != wantRight {
            isRightMouseDown = wantRight
            postMouse(wantRight ? .rightMouseDown : .rightMouseUp, at: location, button: .right, flags: flags)
        }

        // 2. Reconcile stylus proximity and tip contact
        let wantProximity = packet.heartbeatInProximity
        let wantPenDown = packet.heartbeatPenDown
        let point = displayPoint(normalizedX: packet.x, normalizedY: packet.y) ?? location

        if isStylusInProximity != wantProximity {
            if !wantProximity {
                if isStylusDown {
                    isStylusDown = false
                    postTabletMouse(.leftMouseUp, at: point, button: .left, packet: packet, flags: flags)
                }
                isStylusInProximity = false
                postProximity(entering: false, flags: flags)
            } else {
                isStylusInProximity = true
                postProximity(entering: true, flags: flags)
            }
        }

        if isStylusDown != wantPenDown {
            if wantPenDown {
                if !isStylusInProximity {
                    isStylusInProximity = true
                    postProximity(entering: true, flags: flags)
                }
                isStylusDown = true
                let effectivePressure = packet.pressure > 0.05 ? packet.pressure : 0.5
                let strokePacket = VPadPacket.stylusStroke(
                    x: packet.x,
                    y: packet.y,
                    pressure: effectivePressure,
                    tiltX: packet.tiltX,
                    tiltY: packet.tiltY,
                    rollAngle: packet.rollAngle,
                    phase: .began
                )
                postTabletMouse(.leftMouseDown, at: point, button: .left, packet: strokePacket, flags: flags)
            } else {
                isStylusDown = false
                let strokePacket = VPadPacket.stylusStroke(
                    x: packet.x,
                    y: packet.y,
                    pressure: 0.0,
                    tiltX: packet.tiltX,
                    tiltY: packet.tiltY,
                    rollAngle: packet.rollAngle,
                    phase: .ended
                )
                postTabletMouse(.leftMouseUp, at: point, button: .left, packet: strokePacket, flags: flags)
            }
        }
    }

    /// Releases Space, mouse buttons and all tracked keyboard keys.
    func releaseAll() {
        if isDryRun {
            logDryRun("RELEASE_ALL")
        }
        releaseAllKeys()
        if isSpacebarHeld {
            isSpacebarHeld = false
            postKey(CGKeyCode(VPadKeycode.space), flags: [], down: false)
        }
        let location = currentPointerLocation()
        if isLeftMouseDown {
            isLeftMouseDown = false
            postMouse(.leftMouseUp, at: location, button: .left, flags: [])
        }
        if isRightMouseDown {
            isRightMouseDown = false
            postMouse(.rightMouseUp, at: location, button: .right, flags: [])
        }
        if isStylusDown {
            isStylusDown = false
            postMouse(.leftMouseUp, at: location, button: .left, flags: [])
        }
        if isStylusInProximity {
            isStylusInProximity = false
            postProximity(entering: false, flags: [])
        }
    }

    func mapModifiers(_ modifiers: UInt16) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & ModifierMask.command.rawValue != 0 { flags.insert(.maskCommand) }
        if modifiers & ModifierMask.shift.rawValue != 0 { flags.insert(.maskShift) }
        if modifiers & ModifierMask.option.rawValue != 0 { flags.insert(.maskAlternate) }
        if modifiers & ModifierMask.control.rawValue != 0 { flags.insert(.maskControl) }
        return flags
    }

    /// Executes a sequence of key strokes, holding each for ~40 ms.
    func performKeyStrokes(_ strokes: [(CGKeyCode, CGEventFlags)]) {
        guard !strokes.isEmpty else { return }
        macroQueue.async { [weak self] in
            guard let self else { return }
            for (keyCode, flags) in strokes {
                self.postKey(keyCode, flags: flags, down: true)
                Thread.sleep(forTimeInterval: 0.040)
                self.postKey(keyCode, flags: flags, down: false)
            }
        }
    }

    // MARK: - Wake

    private func wakeDisplayIfNeeded() {
        guard !didWakeDisplay else { return }
        didWakeDisplay = true
        if isDryRun {
            logDryRun("WAKE_DISPLAY")
            return
        }
        var assertionID: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "VirtualTabletPad" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }

    // MARK: - System actions

    private func injectSystemAction(_ action: SystemAction) {
        log.notice("VPAD_SYSTEM_ACTION action=\(action.rawValue, privacy: .public)")
        switch action {
        case .brightnessDown:
            postSystemKey(3)
        case .brightnessUp:
            postSystemKey(2)
        case .volumeDown:
            postSystemKey(1)
        case .volumeUp:
            postSystemKey(0)
        case .mute:
            postSystemKey(7)
        case .playPause:
            postSystemKey(16)
        case .nextTrack:
            postSystemKey(17)
        case .previousTrack:
            postSystemKey(18)
        case .missionControl:
            postKeyCombo(CGKeyCode(126), flags: .maskControl)
        case .appExpose:
            performDockExposeAction("AXExposeShowFrontWindows") { [weak self] in
                self?.postKeyCombo(CGKeyCode(125), flags: .maskControl)
            }
        case .desktopLeft:
            postKeyCombo(CGKeyCode(123), flags: .maskControl)
        case .desktopRight:
            postKeyCombo(CGKeyCode(124), flags: .maskControl)
        case .launchpad:
            if isDryRun {
                logDryRun("OPEN_URL url=/System/Applications/Launchpad.app action=launchpad")
                return
            }
            DispatchQueue.main.async {
                let modern = "/System/Applications/Apps.app"
                let legacy = "/System/Applications/Launchpad.app"
                let path = FileManager.default.fileExists(atPath: modern) ? modern : legacy
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    private func postSystemKey(_ keyType: Int) {
        macroQueue.async { [weak self] in
            guard let self else { return }
            self.postSystemKeyEvent(keyType, down: true)
            Thread.sleep(forTimeInterval: 0.025)
            self.postSystemKeyEvent(keyType, down: false)
        }
    }

    private func postSystemKeyEvent(_ keyType: Int, down: Bool) {
        if isDryRun {
            logDryRun("SYSTEM_KEY keyType=\(keyType) down=\(down)")
            return
        }
        let state = down ? 0x0A : 0x0B
        let data1 = (keyType << 16) | (state << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        if let cgEvent = event.cgEvent {
            poster.post(cgEvent, tap: .cghidEventTap)
        }
    }

    private func performDockExposeAction(
        _ action: String,
        fallback: () -> Void
    ) {
        if isDryRun {
            logDryRun("AX_ACTION action=\(action)")
            return
        }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first else {
            fallback()
            return
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        let result = AXUIElementPerformAction(dockElement, action as CFString)
        if result != .success {
            NSLog("VPAD_EXPOSE_ACTION %@ failed %d", action, result.rawValue)
            fallback()
        }
    }

    private func postKeyCombo(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        macroQueue.async { [weak self] in
            guard let self else { return }
            // System hotkeys are handled above the HID tap; post the target
            // with Control flags at the session tap instead of synthesizing a
            // Control keyDown (which is not a modifier transition).
            self.postHotKey(keyCode, flags: flags, down: true)
            Thread.sleep(forTimeInterval: 0.030)
            self.postHotKey(keyCode, flags: flags, down: false)
        }
    }

    private func postHotKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags,
        down: Bool
    ) {
        if isDryRun {
            logDryRun("HOTKEY keyCode=\(keyCode) down=\(down) flags=\(flags.rawValue)")
            return
        }
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: down
        ) else {
            return
        }
        event.flags = flags
        poster.post(event, tap: .cgSessionEventTap)
    }

    // MARK: - Trackpad

    private func injectTrackpadMove(_ packet: VPadPacket, flags: CGEventFlags) {
        guard packet.x.isFinite, packet.y.isFinite else { return }
        wakeDisplayIfNeeded()
        let current = currentPointerLocation()
        let speed = hypot(Double(packet.x), Double(packet.y))
        let gain = min(max(speed * 0.15, 1.0), 2.8)
        let target = CGPoint(
            x: current.x + CGFloat(Double(packet.x) * gain),
            y: current.y + CGFloat(Double(packet.y) * gain)
        )
        let location = clampToMainDisplay(target)
        let eventType: CGEventType = isLeftMouseDown ? .leftMouseDragged : .mouseMoved
        postMouse(eventType, at: location, button: .left, flags: flags)
    }

    private func injectTrackpadScroll(_ packet: VPadPacket, flags: CGEventFlags) {
        guard packet.x.isFinite, packet.y.isFinite else { return }
        if isDryRun {
            logDryRun("SCROLL dx=\(packet.x) dy=\(packet.y) flags=\(flags.rawValue)")
            return
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: int32Clamped(packet.y),
            wheel2: int32Clamped(packet.x),
            wheel3: 0
        ) else {
            return
        }
        event.flags = flags
        poster.post(event, tap: .cghidEventTap)
    }

    private func injectTrackpadClick(_ packet: VPadPacket, flags: CGEventFlags) {
        wakeDisplayIfNeeded()
        let isRight = packet.pressure >= 1.5
        let location = currentPointerLocation()
        let phase = packet.phase

        if isRight {
            if phase == Phase.began.rawValue {
                isRightMouseDown = true
                postMouse(.rightMouseDown, at: location, button: .right, flags: flags)
            } else if phase == Phase.ended.rawValue || phase == Phase.cancelled.rawValue {
                isRightMouseDown = false
                postMouse(.rightMouseUp, at: location, button: .right, flags: flags)
            }
        } else {
            if phase == Phase.began.rawValue {
                isLeftMouseDown = true
                postMouse(.leftMouseDown, at: location, button: .left, flags: flags)
            } else if phase == Phase.ended.rawValue || phase == Phase.cancelled.rawValue {
                isLeftMouseDown = false
                postMouse(.leftMouseUp, at: location, button: .left, flags: flags)
            }
        }
    }

    // MARK: - Stylus

    private func injectProximity(_ packet: VPadPacket, flags: CGEventFlags) {
        let entering = packet.phase == Phase.began.rawValue
        if entering {
            guard !isStylusInProximity else { return }
            isStylusInProximity = true
            postProximity(entering: true, flags: flags)
        } else {
            guard isStylusInProximity else { return }
            if isStylusDown {
                isStylusDown = false
                postMouse(.leftMouseUp, at: currentPointerLocation(), button: .left, flags: flags)
            }
            isStylusInProximity = false
            postProximity(entering: false, flags: flags)
        }
    }

    private func postProximity(entering: Bool, flags: CGEventFlags) {
        if isDryRun {
            logDryRun("PROXIMITY entering=\(entering ? 1 : 0) flags=\(flags.rawValue)")
            return
        }
        guard let event = CGEvent(source: eventSource) else { return }
        event.type = .tabletProximity
        event.flags = flags
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: 1)   // pen tip
        event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056A) // Wacom emulation
        event.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 1)
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0FFF)
        poster.post(event, tap: .cghidEventTap)
    }

    private func injectStylus(_ packet: VPadPacket, isHover: Bool, flags: CGEventFlags) {
        guard let point = displayPoint(normalizedX: packet.x, normalizedY: packet.y) else { return }

        if !isStylusInProximity {
            isStylusInProximity = true
            postProximity(entering: true, flags: flags)
        }

        if isHover {
            postTabletMouse(.mouseMoved, at: point, button: .left, packet: packet, flags: flags)
            return
        }

        switch packet.phase {
        case Phase.began.rawValue:
            isStylusDown = true
            postTabletMouse(.leftMouseDown, at: point, button: .left, packet: packet, flags: flags)
        case Phase.moved.rawValue:
            if !isStylusDown {
                isStylusDown = true
                postTabletMouse(.leftMouseDown, at: point, button: .left, packet: packet, flags: flags)
            }
            postTabletMouse(.leftMouseDragged, at: point, button: .left, packet: packet, flags: flags)
        case Phase.ended.rawValue, Phase.cancelled.rawValue:
            guard isStylusDown else { return }
            isStylusDown = false
            postTabletMouse(.leftMouseUp, at: point, button: .left, packet: packet, flags: flags)
        default:
            break
        }
    }

    private func injectSqueeze(_ packet: VPadPacket, flags: CGEventFlags) {
        guard packet.phase == Phase.began.rawValue else { return }

        let point: CGPoint
        if let mapped = displayPoint(normalizedX: packet.x, normalizedY: packet.y),
           (0...1).contains(packet.x),
           (0...1).contains(packet.y) {
            point = mapped
            if isDryRun {
                logDryRun("WARP_CURSOR x=\(String(format: "%.2f", point.x)) y=\(String(format: "%.2f", point.y))")
            } else {
                warpCursorHandler(point)
            }
        } else {
            point = currentPointerLocation()
        }

        postMouse(.rightMouseDown, at: point, button: .right, flags: flags)
        macroQueue.asyncAfter(deadline: .now() + 0.010) { [weak self] in
            self?.postMouse(.rightMouseUp, at: point, button: .right, flags: flags)
        }
    }

    private func postTabletMouse(
        _ type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        packet: VPadPacket,
        flags: CGEventFlags
    ) {
        let degrees = packet.rollAngle.isFinite
            ? fmod((Double(packet.rollAngle) * 180.0 / .pi) + 360.0, 360.0)
            : 0
        let pressure = (type == .mouseMoved) ? 0.0 : safeUnit(packet.pressure)
        let tiltX = safeBipolar(packet.tiltX)
        let tiltY = safeBipolar(packet.tiltY)
        let buttons: Int64 = (type == .leftMouseDown || type == .leftMouseDragged) ? 1 : 0

        if isDryRun {
            logDryRun("TABLET_MOUSE type=\(type.rawValue) x=\(String(format: "%.2f", point.x)) y=\(String(format: "%.2f", point.y)) button=\(button.rawValue) flags=\(flags.rawValue) pressure=\(String(format: "%.3f", pressure)) tiltX=\(String(format: "%.3f", tiltX)) tiltY=\(String(format: "%.3f", tiltY)) rotation=\(String(format: "%.1f", degrees)) subtype=\(CGEventMouseSubtype.tabletPoint.rawValue)")
            return
        }
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(
            .mouseEventSubtype,
            value: Int64(CGEventMouseSubtype.tabletPoint.rawValue)
        )
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        event.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        event.setDoubleValueField(.tabletEventRotation, value: degrees)
        event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        event.setIntegerValueField(.tabletEventDeviceID, value: 1)
        poster.post(event, tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func injectKeyboard(_ packet: VPadPacket, flags: CGEventFlags) {
        guard let keyCode = keyCode(from: packet.rollAngle) else { return }

        switch packet.phase {
        case Phase.began.rawValue:
            keyboardDown[keyCode] = flags
            postKey(keyCode, flags: flags, down: true)
        case Phase.moved.rawValue:
            postKey(keyCode, flags: flags, down: true, autorepeat: true)
        case Phase.ended.rawValue:
            keyboardDown.removeValue(forKey: keyCode)
            postKey(keyCode, flags: flags, down: false)
        case Phase.cancelled.rawValue:
            releaseAllKeys()
        default:
            break
        }
    }

    private func releaseAllKeys() {
        let keys = keyboardDown
        keyboardDown.removeAll(keepingCapacity: true)
        for (keyCode, flags) in keys {
            postKey(keyCode, flags: flags, down: false)
        }
    }

    private func updateSpacebar(for modifiers: UInt16) {
        let wantsSpace = modifiers & ModifierMask.space.rawValue != 0
        guard wantsSpace != isSpacebarHeld else { return }
        isSpacebarHeld = wantsSpace
        postKey(
            CGKeyCode(VPadKeycode.space),
            flags: mapModifiers(modifiers),
            down: wantsSpace
        )
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags,
        down: Bool,
        autorepeat: Bool = false
    ) {
        if isDryRun {
            logDryRun("KEY keyCode=\(keyCode) down=\(down) autorepeat=\(autorepeat ? 1 : 0) flags=\(flags.rawValue)")
            return
        }
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: down
        ) else {
            return
        }
        event.flags = flags
        if autorepeat, down {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        poster.post(event, tap: .cghidEventTap)
    }

    private func postAtomicKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(keyCode, flags: flags, down: true)
        macroQueue.asyncAfter(deadline: .now() + 0.040) { [weak self] in
            self?.postKey(keyCode, flags: flags, down: false)
        }
    }

    // MARK: - Geometry / conversion helpers

    private func currentPointerLocation() -> CGPoint {
        if isDryRun {
            return CGPoint(x: 500, y: 500)
        }
        return pointerLocationProvider()
    }

    private func mainDisplayBounds() -> CGRect {
        return screenBoundsProvider()
    }

    private func clampToMainDisplay(_ point: CGPoint) -> CGPoint {
        let bounds = mainDisplayBounds()
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func displayPoint(normalizedX: Float32, normalizedY: Float32) -> CGPoint? {
        guard normalizedX.isFinite, normalizedY.isFinite else { return nil }
        let bounds = mainDisplayBounds()
        let nx = min(max(CGFloat(normalizedX), 0), 1)
        let ny = min(max(CGFloat(normalizedY), 0), 1)
        return CGPoint(
            x: bounds.minX + nx * max(bounds.width - 1, 1),
            y: bounds.minY + ny * max(bounds.height - 1, 1)
        )
    }

    private func keyCode(from rollAngle: Float32) -> CGKeyCode? {
        guard rollAngle.isFinite,
              rollAngle >= 0,
              rollAngle <= Float32(UInt16.max) else {
            return nil
        }
        return CGKeyCode(UInt16(rollAngle.rounded()))
    }

    private func int32Clamped(_ value: Float32) -> Int32 {
        guard value.isFinite else { return 0 }
        let clamped = min(max(Double(value), Double(Int32.min)), Double(Int32.max))
        return Int32(clamped.rounded())
    }

    private func safeUnit(_ value: Float32) -> Double {
        guard value.isFinite else { return 0 }
        return Double(min(max(value, 0), 1))
    }

    private func safeBipolar(_ value: Float32) -> Double {
        guard value.isFinite else { return 0 }
        return Double(min(max(value, -1), 1))
    }

    private func postMouse(
        _ type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags
    ) {
        if isDryRun {
            logDryRun("MOUSE type=\(type.rawValue) x=\(String(format: "%.2f", point.x)) y=\(String(format: "%.2f", point.y)) button=\(button.rawValue) flags=\(flags.rawValue)")
            return
        }
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            return
        }
        event.flags = flags
        poster.post(event, tap: .cghidEventTap)
    }
}
