import UIKit
import VPadProtocol

private enum ScrubEdge {
    case left
    case right
    case top
    case bottom
}

/// Full-screen 240 Hz Pencil + finger canvas. The visible 16:10 `activeRect` is
/// the same coordinate box used for normalization sent to the Mac.
@MainActor
final class HybridCanvasView: UIView {
    var onPacket: ((VPadPacket) -> Void)?
    var ambientColor: UIColor = UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 1.0) {
        didSet { setNeedsDisplay() }
    }
    var onPencilDrawingChanged: ((Bool) -> Void)?

    private(set) var activeRect: CGRect = .zero
    private let inkLayer = TransientInkLayer()
    private let inkMask = CAShapeLayer()
    private var hoverRecognizer: UIHoverGestureRecognizer?
    private var proximityLeaveTask: Task<Void, Never>?
    private var isProximityActive = false
    private var pencilActiveUntil: TimeInterval = 0

    private var fingerTouches: [UITouch] = []
    private var ignoredTouches = Set<ObjectIdentifier>()
    private var gestureActive = false

    private var oneFingerStart: (time: TimeInterval, point: CGPoint)?
    private var oneFingerMoved = false
    private var lastOneFingerPoint: CGPoint?

    private var twoFingerStart: (time: TimeInterval, centroid: CGPoint)?
    private var twoFingerMoved = false
    private var twoFingerMaxCount = 0
    private var lastTwoFingerCentroid: CGPoint?

    private var motionFilter = TouchpadMotionFilter()
    private var strokeFilter = PencilStrokeFilter()
    private var stopMotionTask: Task<Void, Never>?
    private var holdDragTask: Task<Void, Never>?
    private var forceTouchTask: Task<Void, Never>?
    private var twoFingerLongPressTask: Task<Void, Never>?
    private var isHoldDragging = false
    private var forceTouchFired = false
    private var twoFingerLongPressFired = false
    private var twoFingerLastSpread: CGFloat = 0
    private var fnActionTriggered = false
    private let touchIndicator = CAShapeLayer()

    private var isGuidedAccessEnabled = GuidedAccessMonitor.shared.isEnabled
    private var guidedAccessObserver: NSObjectProtocol?
    private var gestureModeObserver: NSObjectProtocol?
    private let safetyZone = SafetyZoneView()
    private var scrubTouch: UITouch?
    private var scrubEdge: ScrubEdge?
    private var scrubLastPoint: CGPoint = .zero
    private var scrubAccumulated: CGFloat = 0
    private var dragTouch: UITouch?
    private var dragLastPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true

        touchIndicator.fillColor = UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.18).cgColor
        touchIndicator.strokeColor = UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.60).cgColor
        touchIndicator.lineWidth = 1
        touchIndicator.isHidden = true
        layer.addSublayer(inkLayer)
        inkLayer.mask = inkMask
        layer.addSublayer(touchIndicator)

        safetyZone.isHidden = isGuidedAccessEnabled
        safetyZone.onFnChanged = { held in
            SafetyGestureState.shared.setFnHeld(held)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        safetyZone.onDragChanged = { [weak self] held in
            SafetyGestureState.shared.setDragHeld(held)
            if !held {
                self?.endSafetyDrag()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        safetyZone.onShowDesktop = { [weak self] in
            self?.sendShowDesktop()
        }
        safetyZone.onLaunchpad = { [weak self] in
            self?.sendSystemAction(.launchpad)
        }
        addSubview(safetyZone)

        guidedAccessObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                GuidedAccessMonitor.shared.refresh()
                self?.refreshGuidedAccessMode()
            }
        }

        gestureModeObserver = NotificationCenter.default.addObserver(
            forName: .gestureModePreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGuidedAccessMode()
            }
        }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        hoverRecognizer = hover
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Layout / drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding: CGFloat = 0
        let available = bounds.insetBy(dx: padding, dy: padding)
        let ratio: CGFloat = 16.0 / 10.0
        var width = max(available.width, 1)
        var height = width / ratio
        if height > available.height {
            height = max(available.height, 1)
            width = height * ratio
        }
        activeRect = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        let radius: CGFloat = 24
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.frame = bounds
        inkLayer.contentsScale = traitCollection.displayScale
        inkMask.frame = bounds
        inkMask.path = UIBezierPath(
            roundedRect: activeRect,
            cornerRadius: radius
        ).cgPath
        touchIndicator.frame = bounds
        touchIndicator.contentsScale = traitCollection.displayScale
        CATransaction.commit()
        safetyZone.frame = bounds
        safetyZone.setNeedsLayout()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let radius: CGFloat = 32
        let canvasPath = UIBezierPath(
            roundedRect: activeRect,
            cornerRadius: radius
        )
        let focused = isGuidedAccessEnabled

        context.saveGState()
        context.addPath(canvasPath.cgPath)
        let fill = focused
            ? UIColor(red: 0.018, green: 0.018, blue: 0.022, alpha: 1.0)
            : UIColor(red: 0.071, green: 0.071, blue: 0.078, alpha: 1.0)
        context.setFillColor(fill.cgColor)
        context.fillPath()

        if !focused {
            context.addPath(canvasPath.cgPath)
            context.clip()
            context.setFillColor(UIColor.white.withAlphaComponent(0.075).cgColor)
            let step: CGFloat = 48
            var x = activeRect.minX + step / 2
            while x < activeRect.maxX {
                var y = activeRect.minY + step / 2
                while y < activeRect.maxY {
                    context.fillEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    y += step
                }
                x += step
            }
            context.restoreGState()
        } else {
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(canvasPath.cgPath)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.13).cgColor)
        context.setLineWidth(1.2)
        context.strokePath()
        context.restoreGState()

        if !focused {
            context.saveGState()
            context.addPath(canvasPath.cgPath)
            context.setStrokeColor(ambientColor.withAlphaComponent(0.10).cgColor)
            context.setLineWidth(2)
            context.strokePath()
            context.restoreGState()
            drawSafetyChrome(in: context)
        }
    }

    private func drawSafetyChrome(in context: CGContext) {
        let inset: CGFloat = 35
        let safeRect = bounds.insetBy(dx: inset, dy: inset)
        guard safeRect.width > 40, safeRect.height > 40 else { return }

        context.saveGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.09).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 7])
        context.addPath(UIBezierPath(roundedRect: safeRect, cornerRadius: 24).cgPath)
        context.strokePath()
        context.restoreGState()

        let trackLength: CGFloat = 120
        let edgeInset: CGFloat = 60
        let tracks = [
            CGRect(
                x: bounds.minX + edgeInset - 2,
                y: bounds.midY - trackLength / 2,
                width: 4,
                height: trackLength
            ),
            CGRect(
                x: bounds.maxX - edgeInset - 2,
                y: bounds.midY - trackLength / 2,
                width: 4,
                height: trackLength
            ),
            CGRect(
                x: bounds.midX - trackLength / 2,
                y: bounds.minY + edgeInset - 2,
                width: trackLength,
                height: 4
            ),
            CGRect(
                x: bounds.midX - trackLength / 2,
                y: bounds.maxY - edgeInset - 2,
                width: trackLength,
                height: 4
            )
        ]

        context.saveGState()
        context.setFillColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        for track in tracks {
            context.addPath(UIBezierPath(roundedRect: track, cornerRadius: 2).cgPath)
            context.fillPath()
        }
        context.restoreGState()
    }

    func normalizedPoint(_ point: CGPoint) -> (Float32, Float32)? {
        guard activeRect.width > 0, activeRect.height > 0 else { return nil }
        let x = (point.x - activeRect.minX) / activeRect.width
        let y = (point.y - activeRect.minY) / activeRect.height
        return (
            Float32(min(max(x, 0), 1)),
            Float32(min(max(y, 0), 1))
        )
    }

    var centerPoint: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: - Guided Access / safety mode

    private func refreshGuidedAccessMode() {
        let enabled = GuidedAccessMonitor.shared.isEnabled
        guard enabled != isGuidedAccessEnabled else { return }
        isGuidedAccessEnabled = enabled

        if let dragTouch {
            ignoredTouches.insert(ObjectIdentifier(dragTouch))
        }
        endSafetyDrag()
        if let scrubTouch {
            ignoredTouches.insert(ObjectIdentifier(scrubTouch))
        }
        cancelScrub()
        cancelForceTouch()
        cancelTwoFingerLongPress()
        releaseHoldDrag()
        if gestureActive {
            GestureEngine.shared.cancel()
            gestureActive = false
        }
        SafetyGestureState.shared.clear()
        forceTouchFired = false
        twoFingerLongPressFired = false
        fnActionTriggered = false
        safetyZone.isHidden = enabled
        safetyZone.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func beginSafetyDrag(_ touch: UITouch) {
        dragTouch = touch
        dragLastPoint = touch.location(in: self)
        sendClick(button: .left, phase: .began)
    }

    private func updateSafetyDrag(_ touch: UITouch) {
        guard dragTouch === touch else { return }
        let point = touch.location(in: self)
        let dx = point.x - dragLastPoint.x
        let dy = point.y - dragLastPoint.y
        dragLastPoint = point
        guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
        send(VPadPacket.trackpadMove(
            dx: Float32(dx),
            dy: Float32(dy),
            modifiers: ModifierState.shared.snapshot()
        ))
    }

    private func endSafetyDrag() {
        guard dragTouch != nil else { return }
        dragTouch = nil
        sendClick(button: .left, phase: .ended)
    }

    private func beginScrub(edge: ScrubEdge, touch: UITouch) {
        scrubTouch = touch
        scrubEdge = edge
        scrubLastPoint = touch.location(in: self)
        scrubAccumulated = 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateScrub(_ touch: UITouch) {
        guard scrubTouch === touch, let edge = scrubEdge else { return }
        let point = touch.location(in: self)
        let delta: CGFloat
        switch edge {
        case .left, .right:
            delta = scrubLastPoint.y - point.y
        case .top, .bottom:
            delta = point.x - scrubLastPoint.x
        }
        scrubLastPoint = point
        scrubAccumulated += delta

        let step: CGFloat = isGuidedAccessEnabled ? 28 : 32
        while abs(scrubAccumulated) >= step {
            let direction: CGFloat = scrubAccumulated > 0 ? 1 : -1
            scrubAccumulated -= direction * step
            performScrubStep(edge: edge, direction: direction)
        }
    }

    private func performScrubStep(edge: ScrubEdge, direction: CGFloat) {
        switch edge {
        case .left:
            sendSystemAction(direction > 0 ? .brightnessUp : .brightnessDown)
        case .right:
            sendSystemAction(direction > 0 ? .volumeUp : .volumeDown)
        case .top, .bottom:
            let previous = direction < 0
            sendShortcut(
                keyCode: previous ? 33 : 30,
                modifiers: ModifierMask.command.rawValue | ModifierMask.shift.rawValue
            )
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func cancelScrub() {
        scrubTouch = nil
        scrubEdge = nil
        scrubAccumulated = 0
    }

    private func scrubberEdge(at point: CGPoint) -> ScrubEdge? {
        let inner: CGFloat = isGuidedAccessEnabled ? 0 : 40
        let outer: CGFloat = isGuidedAccessEnabled ? 30 : 80
        let distances: [(ScrubEdge, CGFloat)] = [
            (.left, point.x - bounds.minX),
            (.right, bounds.maxX - point.x),
            (.top, point.y - bounds.minY),
            (.bottom, bounds.maxY - point.y)
        ]
        guard let best = distances
            .filter({ $0.1 >= inner && $0.1 <= outer })
            .min(by: { $0.1 < $1.1 }) else {
            return nil
        }
        return best.0
    }

    private func isInEdgeDeadZone(_ point: CGPoint) -> Bool {
        guard !isGuidedAccessEnabled else { return false }
        let margin: CGFloat = 25
        return point.x < bounds.minX + margin
            || point.x > bounds.maxX - margin
            || point.y < bounds.minY + margin
            || point.y > bounds.maxY - margin
    }

    private func scheduleForceTouch() {
        forceTouchTask?.cancel()
        forceTouchFired = false
        guard isGuidedAccessEnabled, fingerTouches.count == 1 else { return }
        forceTouchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self,
                  !Task.isCancelled,
                  self.fingerTouches.count == 1,
                  !self.oneFingerMoved,
                  !self.gestureActive,
                  !self.isHoldDragging else {
                return
            }
            self.forceTouchFired = true
            self.sendLookUp()
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    private func cancelForceTouch() {
        forceTouchTask?.cancel()
        forceTouchTask = nil
    }

    private func scheduleTwoFingerLongPress() {
        twoFingerLongPressTask?.cancel()
        twoFingerLongPressFired = false
        guard !isGuidedAccessEnabled, !SafetyGestureState.shared.isFnHeld else { return }
        twoFingerLongPressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self,
                  !Task.isCancelled,
                  self.fingerTouches.count == 2,
                  !self.twoFingerMoved,
                  !self.gestureActive,
                  !SafetyGestureState.shared.isFnHeld else {
                return
            }
            self.twoFingerLongPressFired = true
            self.sendQuickLook()
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    private func cancelTwoFingerLongPress() {
        twoFingerLongPressTask?.cancel()
        twoFingerLongPressTask = nil
    }

    private func sendSystemAction(_ action: SystemAction) {
        send(VPadPacket.systemAction(action))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendShortcut(keyCode: UInt16, modifiers: UInt16) {
        send(VPadPacket.keyShortcut(keyCode: keyCode, modifiers: modifiers))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendLookUp() {
        sendShortcut(
            keyCode: 2,
            modifiers: ModifierMask.command.rawValue | ModifierMask.control.rawValue
        )
    }

    private func sendQuickLook() {
        sendShortcut(keyCode: 49, modifiers: 0)
    }

    private func sendShowDesktop() {
        // F11 is the default macOS Show Desktop shortcut.
        sendShortcut(keyCode: 103, modifiers: 0)
    }

    private func suppressUnsafeMultiTouch() {
        if let dragTouch {
            ignoredTouches.insert(ObjectIdentifier(dragTouch))
        }
        endSafetyDrag()
        if let scrubTouch {
            ignoredTouches.insert(ObjectIdentifier(scrubTouch))
        }
        cancelScrub()
        releaseHoldDrag()
        if gestureActive {
            GestureEngine.shared.cancel()
            gestureActive = false
        }
        for touch in fingerTouches {
            ignoredTouches.insert(ObjectIdentifier(touch))
        }
        fingerTouches.removeAll()
        resetFingerState()
        cancelStopMotion()
        hideTouchIndicator()
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

    // MARK: - Hover / proximity

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            cancelProximityLeave()
            pencilActiveUntil = CACurrentMediaTime() + 0.6
            if !isProximityActive {
                sendProximity(.began)
                isProximityActive = true
            }
            sendHover(recognizer)
        case .ended, .cancelled, .failed:
            if isProximityActive {
                sendProximity(.ended)
                isProximityActive = false
            }
            pencilActiveUntil = CACurrentMediaTime() + 0.6
        default:
            break
        }
    }

    private func sendHover(_ recognizer: UIHoverGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let (nx, ny) = normalizedPoint(point) else { return }
        let altitude = recognizer.altitudeAngle
        let azimuth = recognizer.azimuthAngle(in: self)
        let tiltX = Float32(cos(azimuth) * cos(altitude))
        let tiltY = Float32(sin(azimuth) * cos(altitude))
        let roll: Float32
        if #available(iOS 17.5, *) {
            roll = Float32(recognizer.rollAngle)
        } else {
            roll = 0
        }
        send(VPadPacket.stylusHover(
            x: nx,
            y: ny,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: roll,
            phase: .moved,
            modifiers: ModifierState.shared.snapshot()
        ))
    }

    private func sendProximity(_ phase: Phase) {
        send(VPadPacket.stylusProximity(phase: phase))
    }

    private func scheduleProximityLeave() {
        proximityLeaveTask?.cancel()
        proximityLeaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.isProximityActive else { return }
            self.sendProximity(.ended)
            self.isProximityActive = false
        }
    }

    private func cancelProximityLeave() {
        proximityLeaveTask?.cancel()
        proximityLeaveTask = nil
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { $0.type == .pencil }
        if !pencilTouches.isEmpty {
            // A pencil-down immediately ends any finger trackpad/gesture path,
            // so a resting palm cannot keep generating input while drawing.
            if gestureActive {
                GestureEngine.shared.cancel()
                gestureActive = false
            }
            endSafetyDrag()
            cancelScrub()
            cancelForceTouch()
            cancelTwoFingerLongPress()
            fingerTouches.removeAll()
            ignoredTouches.removeAll()
            resetFingerState()
            cancelStopMotion()
            releaseHoldDrag()
            hideTouchIndicator()

            pencilActiveUntil = CACurrentMediaTime() + 0.8
            cancelProximityLeave()
            if !isProximityActive {
                sendProximity(.began)
                isProximityActive = true
            }
            onPencilDrawingChanged?(true)
            for touch in pencilTouches {
                inkLayer.beginStroke()
                if let point = sendStroke(touch, phase: .began, event: event) {
                    inkLayer.append(point)
                }
            }
            return
        }

        let directTouches = touches.filter { $0.type == .direct }
        guard !directTouches.isEmpty else { return }
        guard !PencilSettingsStore.shared.settings.penOnly else { return }
        if CACurrentMediaTime() < pencilActiveUntil {
            for touch in directTouches {
                ignoredTouches.insert(ObjectIdentifier(touch))
            }
            return
        }

        // Without Guided Access, four fingers (or more) hand the app to iPadOS
        // multitasking. Drop the whole gesture and release any mouse button.
        if !isGuidedAccessEnabled, fingerTouches.count + directTouches.count >= 4 {
            suppressUnsafeMultiTouch()
            for touch in directTouches {
                ignoredTouches.insert(ObjectIdentifier(touch))
            }
            return
        }

        if dragTouch != nil {
            for touch in directTouches {
                ignoredTouches.insert(ObjectIdentifier(touch))
            }
            return
        }

        if let touch = directTouches.first,
           directTouches.count == 1,
           fingerTouches.isEmpty,
           SafetyGestureState.shared.isDragHeld {
            beginSafetyDrag(touch)
            return
        }

        if scrubTouch != nil {
            if let scrubTouch {
                ignoredTouches.insert(ObjectIdentifier(scrubTouch))
            }
            cancelScrub()
            for touch in directTouches {
                ignoredTouches.insert(ObjectIdentifier(touch))
            }
            return
        }

        if let touch = directTouches.first,
           directTouches.count == 1,
           fingerTouches.isEmpty {
            let point = touch.location(in: self)
            if isInEdgeDeadZone(point) {
                ignoredTouches.insert(ObjectIdentifier(touch))
                return
            }
            if let edge = scrubberEdge(at: point) {
                beginScrub(edge: edge, touch: touch)
                return
            }
        }

        for touch in directTouches where !fingerTouches.contains(where: { $0 === touch }) {
            fingerTouches.append(touch)
        }
        cancelStopMotion()
        handleFingerCountChange()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { $0.type == .pencil }
        if !pencilTouches.isEmpty {
            pencilActiveUntil = CACurrentMediaTime() + 0.8
            cancelProximityLeave()
            for touch in pencilTouches {
                sendCoalescedStroke(touch, event: event)
            }
            return
        }

        if let dragTouch, touches.contains(where: { $0 === dragTouch }) {
            updateSafetyDrag(dragTouch)
            return
        }
        if dragTouch != nil {
            return
        }

        if let scrubTouch, touches.contains(where: { $0 === scrubTouch }) {
            updateScrub(scrubTouch)
            return
        }
        if scrubTouch != nil {
            return
        }

        let directTouches = touches.filter { $0.type == .direct && !ignoredTouches.contains(ObjectIdentifier($0)) }
        guard !directTouches.isEmpty else { return }
        for touch in directTouches where !fingerTouches.contains(where: { $0 === touch }) {
            fingerTouches.append(touch)
        }
        handleFingerMove()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { $0.type == .pencil }
        if !pencilTouches.isEmpty {
            for touch in pencilTouches {
                if let point = sendStroke(touch, phase: .ended, event: event) {
                    inkLayer.append(point)
                }
                inkLayer.endStroke()
            }
            pencilActiveUntil = CACurrentMediaTime() + 0.8
            scheduleProximityLeave()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.onPencilDrawingChanged?(false)
            }
            return
        }

        let directTouches = touches.filter { $0.type == .direct }
        guard !directTouches.isEmpty else { return }

        if let dragTouch, touches.contains(where: { $0 === dragTouch }) {
            endSafetyDrag()
            return
        }
        if let scrubTouch, touches.contains(where: { $0 === scrubTouch }) {
            cancelScrub()
            return
        }

        for touch in directTouches {
            ignoredTouches.remove(ObjectIdentifier(touch))
            fingerTouches.removeAll { $0 === touch }
        }

        if gestureActive {
            GestureEngine.shared.end(remainingTouches: fingerTouches.count)
            if !GestureEngine.shared.isActive {
                gestureActive = false
                for touch in fingerTouches {
                    ignoredTouches.insert(ObjectIdentifier(touch))
                }
                fingerTouches.removeAll()
            }
            return
        }

        let now = CACurrentMediaTime()
        if fingerTouches.isEmpty {
            finishFingerGesture(now: now)
        } else if fingerTouches.count == 1 {
            // A second finger lifted from a two-finger gesture; do not turn the
            // remaining finger into an accidental click.
            oneFingerStart = (now, fingerTouches[0].location(in: self))
            oneFingerMoved = true
            lastOneFingerPoint = fingerTouches[0].location(in: self)
        }
        resetFingerTrackingIfNeeded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { $0.type == .pencil }
        for touch in pencilTouches {
            _ = sendStroke(touch, phase: .cancelled, event: event)
            inkLayer.endStroke()
        }
        if !pencilTouches.isEmpty {
            scheduleProximityLeave()
            return
        }

        for touch in touches {
            ignoredTouches.remove(ObjectIdentifier(touch))
        }
        endSafetyDrag()
        cancelScrub()
        cancelForceTouch()
        cancelTwoFingerLongPress()
        forceTouchFired = false
        twoFingerLongPressFired = false
        fnActionTriggered = false
        if gestureActive {
            GestureEngine.shared.cancel()
            gestureActive = false
        }
        resetFingerTrackingIfNeeded()
        fingerTouches.removeAll()
        resetFingerState()
        cancelStopMotion()
        releaseHoldDrag()
        hideTouchIndicator()
    }

    // MARK: - Finger trackpad / gestures

    private func handleFingerCountChange() {
        cancelStopMotion()
        if fingerTouches.count != 1 {
            releaseHoldDrag()
            cancelForceTouch()
        }
        if fingerTouches.count != 2 {
            cancelTwoFingerLongPress()
        }
        if !isGuidedAccessEnabled, fingerTouches.count >= 4 {
            suppressUnsafeMultiTouch()
            return
        }
        motionFilter.reset()
        hideTouchIndicator()
        if fingerTouches.count >= 3 {
            beginGestureIfNeeded()
            return
        }
        if fingerTouches.count == 1 {
            let point = fingerTouches[0].location(in: self)
            oneFingerStart = (CACurrentMediaTime(), point)
            oneFingerMoved = false
            lastOneFingerPoint = point
            updateTouchIndicator(at: point)
            scheduleHoldDrag()
        } else if fingerTouches.count == 2 {
            let centroid = Self.centroid(of: fingerTouches, in: self)
            twoFingerStart = (CACurrentMediaTime(), centroid)
            twoFingerMoved = false
            twoFingerMaxCount = max(twoFingerMaxCount, 2)
            lastTwoFingerCentroid = centroid
            twoFingerLastSpread = Self.spread(of: fingerTouches, in: self)
            fnActionTriggered = false
            updateTouchIndicator(at: centroid)
            scheduleTwoFingerLongPress()
        }
    }

    private func handleFingerMove() {
        if gestureActive || fingerTouches.count >= 3 {
            beginGestureIfNeeded()
            GestureEngine.shared.move(touches: fingerTouches, in: self)
            return
        }

        if fingerTouches.count == 1, let touch = fingerTouches.first {
            if forceTouchFired {
                return
            }
            let point = touch.location(in: self)
            if let last = lastOneFingerPoint {
                let rawDx = Double(point.x - last.x)
                let rawDy = Double(point.y - last.y)
                let settings = TouchpadSettingsStore.shared.settings
                let output = motionFilter.process(
                    dx: rawDx,
                    dy: rawDy,
                    now: CACurrentMediaTime(),
                    settings: settings
                )
                if abs(output.0) > 0.01 || abs(output.1) > 0.01 {
                    send(VPadPacket.trackpadMove(
                        dx: output.0,
                        dy: output.1,
                        modifiers: ModifierState.shared.snapshot()
                    ))
                }
                if let start = oneFingerStart,
                   hypot(point.x - start.point.x, point.y - start.point.y) > 6 {
                    oneFingerMoved = true
                    cancelForceTouch()
                    if !isHoldDragging {
                        holdDragTask?.cancel()
                        holdDragTask = nil
                    }
                }
            }
            lastOneFingerPoint = point
            updateTouchIndicator(at: point)
            return
        }

        if fingerTouches.count == 2 {
            let centroid = Self.centroid(of: fingerTouches, in: self)
            let spread = Self.spread(of: fingerTouches, in: self)
            let previousCentroid = lastTwoFingerCentroid ?? centroid
            let centroidStep = hypot(
                centroid.x - previousCentroid.x,
                centroid.y - previousCentroid.y
            )

            if let start = twoFingerStart,
               hypot(centroid.x - start.centroid.x, centroid.y - start.centroid.y) > 6 {
                twoFingerMoved = true
                cancelTwoFingerLongPress()
            }

            if twoFingerLongPressFired {
                lastTwoFingerCentroid = centroid
                twoFingerLastSpread = spread
                return
            }

            if SafetyGestureState.shared.isFnHeld {
                if !fnActionTriggered, let start = twoFingerStart {
                    let dx = centroid.x - start.centroid.x
                    let dy = centroid.y - start.centroid.y
                    if hypot(dx, dy) > 60 {
                        if abs(dx) > abs(dy) * 1.2 {
                            sendSystemAction(dx < 0 ? .desktopLeft : .desktopRight)
                        } else {
                            sendSystemAction(dy < 0 ? .missionControl : .appExpose)
                        }
                        fnActionTriggered = true
                    }
                }
                lastTwoFingerCentroid = centroid
                twoFingerLastSpread = spread
                twoFingerMaxCount = max(twoFingerMaxCount, 2)
                updateTouchIndicator(at: centroid)
                return
            }

            let spreadDelta = spread - twoFingerLastSpread
            if abs(spreadDelta) > 2, centroidStep < 4 {
                cancelTwoFingerLongPress()
                send(VPadPacket.trackpadScroll(
                    dx: 0,
                    dy: Float32(spreadDelta * 6),
                    modifiers: ModifierMask.command.rawValue
                ))
                twoFingerLastSpread = spread
                lastTwoFingerCentroid = centroid
                twoFingerMaxCount = max(twoFingerMaxCount, 2)
                return
            }
            twoFingerLastSpread = spread

            if let last = lastTwoFingerCentroid {
                let rawDx = Double(centroid.x - last.x)
                let rawDy = Double(centroid.y - last.y)
                let settings = TouchpadSettingsStore.shared.settings
                let direction = settings.naturalScrolling ? 1.0 : -1.0
                let dx = Float32(rawDx * settings.scrollSensitivity * direction)
                let dy = Float32(rawDy * settings.scrollSensitivity * direction)
                if abs(dx) > 0.01 || abs(dy) > 0.01 {
                    send(VPadPacket.trackpadScroll(
                        dx: dx,
                        dy: dy,
                        modifiers: ModifierState.shared.snapshot()
                    ))
                }
            }
            lastTwoFingerCentroid = centroid
            twoFingerMaxCount = max(twoFingerMaxCount, 2)
            updateTouchIndicator(at: centroid)
        }
    }

    private func beginGestureIfNeeded() {
        guard !gestureActive else { return }
        gestureActive = true
        cancelStopMotion()
        cancelForceTouch()
        cancelTwoFingerLongPress()
        motionFilter.reset()
        hideTouchIndicator()
        oneFingerStart = nil
        lastOneFingerPoint = nil
        twoFingerStart = nil
        lastTwoFingerCentroid = nil
        twoFingerLastSpread = 0
        fnActionTriggered = false
        GestureEngine.shared.begin(touches: fingerTouches, in: self)
    }

    private func finishFingerGesture(now: TimeInterval) {
        if isHoldDragging {
            sendClick(button: .left, phase: .ended)
            isHoldDragging = false
            holdDragTask?.cancel()
            holdDragTask = nil
            hideTouchIndicator()
            resetFingerState()
            return
        }
        if forceTouchFired || twoFingerLongPressFired || fnActionTriggered {
            hideTouchIndicator()
            resetFingerState()
            return
        }
        let shouldMomentum = oneFingerMoved && twoFingerMaxCount < 2
        if let start = oneFingerStart, twoFingerMaxCount < 2 {
            let duration = now - start.time
            let point = lastOneFingerPoint ?? start.point
            let movement = hypot(point.x - start.point.x, point.y - start.point.y)
            if duration < 0.18, !oneFingerMoved, movement < 6 {
                sendClick(button: .left)
            }
        } else if let start = twoFingerStart, twoFingerMaxCount == 2 {
            let duration = now - start.time
            if duration < 0.20, !twoFingerMoved {
                sendClick(button: .right)
            }
        }
        if shouldMomentum {
            startStopMomentum()
        }
        hideTouchIndicator()
        resetFingerState()
    }

    private func resetFingerTrackingIfNeeded() {
        if fingerTouches.isEmpty, !gestureActive {
            resetFingerState()
        }
    }

    private func resetFingerState() {
        oneFingerStart = nil
        oneFingerMoved = false
        lastOneFingerPoint = nil
        twoFingerStart = nil
        twoFingerMoved = false
        twoFingerMaxCount = 0
        lastTwoFingerCentroid = nil
        twoFingerLastSpread = 0
        forceTouchFired = false
        twoFingerLongPressFired = false
        fnActionTriggered = false
        motionFilter.reset()
        holdDragTask?.cancel()
        holdDragTask = nil
        cancelForceTouch()
        cancelTwoFingerLongPress()
    }

    private func sendClick(button: TrackpadButton) {
        sendClick(button: button, phase: .began)
        sendClick(button: button, phase: .ended)
    }

    private func sendClick(button: TrackpadButton, phase: Phase) {
        send(VPadPacket.trackpadClick(
            button: button,
            phase: phase,
            modifiers: ModifierState.shared.snapshot()
        ))
        if phase == .began, TouchpadSettingsStore.shared.settings.hapticFeedback {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func scheduleHoldDrag() {
        holdDragTask?.cancel()
        holdDragTask = nil
        cancelForceTouch()
        if isGuidedAccessEnabled {
            scheduleForceTouch()
            return
        }
        let settings = TouchpadSettingsStore.shared.settings
        guard settings.holdToDrag else { return }
        let delay = max(0.12, min(settings.dragDelay, 0.8))
        holdDragTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.fingerTouches.count == 1,
                  !self.oneFingerMoved,
                  !self.gestureActive,
                  !self.isHoldDragging else { return }
            self.isHoldDragging = true
            self.sendClick(button: .left, phase: .began)
            NSLog("VPAD_DRAG began")
        }
    }

    private func releaseHoldDrag() {
        holdDragTask?.cancel()
        holdDragTask = nil
        guard isHoldDragging else { return }
        isHoldDragging = false
        sendClick(button: .left, phase: .ended)
        NSLog("VPAD_DRAG ended")
    }

    // MARK: - Touchpad feel settings

    private func cancelStopMotion() {
        stopMotionTask?.cancel()
        stopMotionTask = nil
    }

    /// A short decaying tail after the finger lifts, scaled by Stop Smoothing.
    private func startStopMomentum() {
        cancelStopMotion()
        let settings = TouchpadSettingsStore.shared.settings
        guard settings.stopSmoothing > 0 else { return }
        let velocity = motionFilter.velocity
        guard hypot(velocity.dx, velocity.dy) > 30 else { return }

        stopMotionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var factor = 1.0
            for _ in 0..<8 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Task.isCancelled { return }
                let current = TouchpadSettingsStore.shared.settings
                guard current.stopSmoothing > 0 else { return }
                let scale = current.stopSmoothing * factor
                let dx = Float32(velocity.dx * 0.016 * scale)
                let dy = Float32(velocity.dy * 0.016 * scale)
                if abs(dx) > 0.01 || abs(dy) > 0.01 {
                    self.send(VPadPacket.trackpadMove(
                        dx: dx,
                        dy: dy,
                        modifiers: ModifierState.shared.snapshot()
                    ))
                }
                factor *= 0.72
            }
        }
    }

    private func updateTouchIndicator(at point: CGPoint?) {
        let settings = TouchpadSettingsStore.shared.settings
        guard settings.showTouchIndicator, let point else {
            touchIndicator.isHidden = true
            return
        }
        let radius: CGFloat = 18
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        touchIndicator.path = UIBezierPath(ovalIn: rect).cgPath
        touchIndicator.isHidden = false
        CATransaction.commit()
    }

    private func hideTouchIndicator() {
        touchIndicator.isHidden = true
    }

    // MARK: - Stylus packets

    private func sendCoalescedStroke(_ touch: UITouch, event: UIEvent?) {
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            if let point = sendStroke(sample, phase: .moved, event: nil) {
                inkLayer.append(point)
            }
        }
    }

    /// Filters and sends one stylus sample, returning the filtered view point so
    /// the local ink trail and the Mac receive the same stabilized position.
    @discardableResult
    private func sendStroke(_ touch: UITouch, phase: Phase, event: UIEvent?) -> CGPoint? {
        PencilStatusMonitor.shared.noteActivity()
        if phase == .began {
            strokeFilter.reset()
        }

        let settings = PencilSettingsStore.shared.settings
        let rawPoint = touch.preciseLocation(in: self)
        let point = strokeFilter.process(
            rawPoint,
            at: touch.timestamp,
            stabilization: settings.stabilization
        )
        guard let (nx, ny) = normalizedPoint(point) else { return nil }

        let rawPressure: Float32
        if touch.maximumPossibleForce > 0 {
            rawPressure = Float32(touch.force / touch.maximumPossibleForce)
        } else {
            rawPressure = 0.5
        }
        let pressure = settings.pressureCurveConfig.apply(rawPressure)
        let altitude = touch.altitudeAngle
        let azimuth = touch.azimuthAngle(in: self)
        let tiltX = Float32(cos(azimuth) * cos(altitude))
        let tiltY = Float32(sin(azimuth) * cos(altitude))
        let roll: Float32
        if #available(iOS 17.5, *) {
            roll = Float32(touch.rollAngle)
        } else {
            roll = 0
        }

        send(VPadPacket.stylusStroke(
            x: nx,
            y: ny,
            pressure: pressure,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: roll,
            phase: phase,
            modifiers: ModifierState.shared.snapshot()
        ))

        return point
    }

    // MARK: - Helpers

    private func send(_ packet: VPadPacket) {
        onPacket?(packet)
    }

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
}

// MARK: - Safe-mode hot zones

@MainActor
private final class SafetyZoneView: UIView {
    var onFnChanged: ((Bool) -> Void)?
    var onDragChanged: ((Bool) -> Void)?
    var onShowDesktop: (() -> Void)?
    var onLaunchpad: (() -> Void)?

    private let fnButton = SafetyHoldButton(title: "Fn")
    private let dragButton = SafetyHoldButton(title: "Drag")
    private let desktopButton = SafetyTapButton(
        symbol: "rectangle.on.rectangle",
        label: "Show Desktop"
    )
    private let launchpadButton = SafetyTapButton(
        symbol: "square.grid.3x3",
        label: "Launchpad"
    )
    private let modeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        modeLabel.text = "SAFE MODE"
        modeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        modeLabel.textColor = UIColor(red: 0.96, green: 0.70, blue: 0.28, alpha: 1)
        modeLabel.isUserInteractionEnabled = false
        addSubview(modeLabel)

        addSubview(fnButton)
        addSubview(dragButton)
        addSubview(desktopButton)
        addSubview(launchpadButton)

        fnButton.onPressChanged = { [weak self] held in
            self?.onFnChanged?(held)
        }
        dragButton.onPressChanged = { [weak self] held in
            self?.onDragChanged?(held)
        }
        desktopButton.addTarget(self, action: #selector(showDesktopTapped), for: .touchUpInside)
        launchpadButton.addTarget(self, action: #selector(launchpadTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 14
        let height: CGFloat = 44
        let bottom = bounds.maxY - inset

        fnButton.frame = CGRect(x: inset, y: bottom - height, width: 56, height: height)
        dragButton.frame = CGRect(
            x: fnButton.frame.maxX + 8,
            y: bottom - height,
            width: 66,
            height: height
        )
        modeLabel.frame = CGRect(
            x: inset + 2,
            y: bottom - height - 17,
            width: 120,
            height: 12
        )

        launchpadButton.frame = CGRect(
            x: bounds.maxX - inset - height,
            y: bottom - height,
            width: height,
            height: height
        )
        desktopButton.frame = CGRect(
            x: launchpadButton.frame.minX - 8 - height,
            y: bottom - height,
            width: height,
            height: height
        )
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    @objc private func showDesktopTapped() {
        onShowDesktop?()
    }

    @objc private func launchpadTapped() {
        onLaunchpad?()
    }
}

@MainActor
private final class SafetyHoldButton: UIButton {
    var onPressChanged: ((Bool) -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        setTitleColor(UIColor.white.withAlphaComponent(0.90), for: .normal)
        backgroundColor = UIColor.white.withAlphaComponent(0.09)
        layer.cornerRadius = 13
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        addTarget(self, action: #selector(pressedDown), for: [.touchDown, .touchDragEnter])
        addTarget(
            self,
            action: #selector(pressedUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressedDown() {
        onPressChanged?(true)
    }

    @objc private func pressedUp() {
        onPressChanged?(false)
    }
}

@MainActor
private final class SafetyTapButton: UIButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        setImage(UIImage(systemName: symbol), for: .normal)
        tintColor = UIColor.white.withAlphaComponent(0.86)
        backgroundColor = UIColor.white.withAlphaComponent(0.09)
        layer.cornerRadius = 13
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        accessibilityLabel = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
