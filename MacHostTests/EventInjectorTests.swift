import XCTest
import CoreGraphics
import VPadProtocol
@testable import VirtualTabletPad

private final class TestDisplayState: @unchecked Sendable {
    var bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    var pointer = CGPoint(x: 500, y: 500)
    var warped: CGPoint?
}

final class EventInjectorTests: XCTestCase {
    var poster: MockEventPoster!
    var injector: EventInjector!
    private var state: TestDisplayState!

    override func setUp() {
        super.setUp()
        poster = MockEventPoster()
        state = TestDisplayState()
        let localState = state!
        injector = EventInjector(
            poster: poster,
            screenBoundsProvider: { localState.bounds },
            pointerLocationProvider: { localState.pointer },
            warpCursorHandler: { localState.warped = $0 },
            isDryRun: false
        )
    }

    // MARK: - Trackpad Tests

    func testTrackpadMovePostsMouseMoved() {
        let packet = VPadPacket.trackpadMove(dx: 10.0, dy: 5.0)
        injector.inject(packet)

        XCTAssertEqual(poster.count, 1)
        guard let event = poster.events.first else { return }
        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertEqual(event.tap, .cghidEventTap)
        XCTAssertGreaterThan(event.location.x, 500)
        XCTAssertGreaterThan(event.location.y, 500)
    }

    func testTrackpadLeftClickLifecycle() {
        let began = VPadPacket.trackpadClick(button: .left, phase: .began)
        injector.inject(began)

        XCTAssertEqual(poster.count, 1)
        XCTAssertEqual(poster.events.last?.type, .leftMouseDown)
        XCTAssertEqual(poster.events.last?.location, state.pointer)

        let ended = VPadPacket.trackpadClick(button: .left, phase: .ended)
        injector.inject(ended)

        XCTAssertEqual(poster.count, 2)
        XCTAssertEqual(poster.events.last?.type, .leftMouseUp)
    }

    func testTrackpadRightClickPressureSentinel() {
        let began = VPadPacket.trackpadClick(button: .right, phase: .began)
        injector.inject(began)

        XCTAssertEqual(poster.count, 1)
        XCTAssertEqual(poster.events.last?.type, .rightMouseDown)

        let ended = VPadPacket.trackpadClick(button: .right, phase: .ended)
        injector.inject(ended)

        XCTAssertEqual(poster.count, 2)
        XCTAssertEqual(poster.events.last?.type, .rightMouseUp)
    }

    // MARK: - Stylus & Proximity State Machine Tests

    func testStylusHoverEntersProximityAndPostsTabletPointMouseMoved() {
        let hover = VPadPacket.stylusHover(
            x: 0.5,
            y: 0.5,
            tiltX: 0.25,
            tiltY: -0.15,
            rollAngle: Float32(Double.pi / 2),
            phase: .moved
        )
        injector.inject(hover)

        // Proximity state machine automatically emits enterProximity before first hover
        XCTAssertEqual(poster.count, 2)
        let enterEvent = poster.events[0]
        XCTAssertEqual(enterEvent.type, .tabletProximity)
        XCTAssertEqual(enterEvent.rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 1)

        let hoverEvent = poster.events[1]
        XCTAssertEqual(hoverEvent.type, .mouseMoved)
        XCTAssertEqual(hoverEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(hoverEvent.pressure, 0.0, accuracy: 0.001)
        XCTAssertEqual(hoverEvent.rawEvent.getDoubleValueField(.tabletEventPointPressure), 0.0, accuracy: 0.001)
        XCTAssertEqual(hoverEvent.tiltX, 0.25, accuracy: 0.001)
        XCTAssertEqual(hoverEvent.tiltY, -0.15, accuracy: 0.001)
        XCTAssertEqual(hoverEvent.rotation, 90.0, accuracy: 0.5)

        // Coordinates mapped to display
        let expectedX = CGFloat(0.5) * (1920.0 - 1.0)
        let expectedY = CGFloat(0.5) * (1080.0 - 1080.0 < 0 ? 0 : 1080.0 - 1.0)
        XCTAssertEqual(hoverEvent.location.x, expectedX, accuracy: 0.5)
        XCTAssertEqual(hoverEvent.location.y, expectedY, accuracy: 0.5)

        // Subsequent hover within proximity does not re-emit enterProximity
        let hover2 = VPadPacket.stylusHover(
            x: 0.6,
            y: 0.6,
            tiltX: 0.1,
            tiltY: 0.1,
            rollAngle: 0.0,
            phase: .moved
        )
        injector.inject(hover2)
        XCTAssertEqual(poster.count, 3)
        XCTAssertEqual(poster.events[2].type, .mouseMoved)
    }

    func testStylusStrokeLifecycleSequence() {
        // Task 2.2: Event sequence for a stroke = enter proximity, down, drags, up

        // 1. Stroke Began (starts stroke from outside proximity)
        let began = VPadPacket.stylusStroke(
            x: 0.2,
            y: 0.3,
            pressure: 0.65,
            tiltX: 0.1,
            tiltY: 0.2,
            rollAngle: 0.0,
            phase: .began
        )
        injector.inject(began)

        // Must emit: [0] tabletProximity(enter=1), [1] leftMouseDown(tabletPoint)
        XCTAssertEqual(poster.count, 2)
        let enterEvent = poster.events[0]
        XCTAssertEqual(enterEvent.type, .tabletProximity)
        XCTAssertEqual(enterEvent.rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 1)

        let downEvent = poster.events[1]
        XCTAssertEqual(downEvent.type, .leftMouseDown)
        XCTAssertEqual(downEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(downEvent.pressure, 0.65, accuracy: 0.01)
        XCTAssertEqual(downEvent.rawEvent.getDoubleValueField(.tabletEventPointPressure), 0.65, accuracy: 0.01)
        XCTAssertEqual(downEvent.rawEvent.getIntegerValueField(.tabletEventPointButtons), 1)

        // 2. Stroke Moved (drag)
        let moved = VPadPacket.stylusStroke(
            x: 0.25,
            y: 0.35,
            pressure: 0.85,
            tiltX: 0.15,
            tiltY: 0.25,
            rollAngle: 0.0,
            phase: .moved
        )
        injector.inject(moved)

        XCTAssertEqual(poster.count, 3)
        let dragEvent = poster.events[2]
        XCTAssertEqual(dragEvent.type, .leftMouseDragged)
        XCTAssertEqual(dragEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(dragEvent.pressure, 0.85, accuracy: 0.01)
        XCTAssertEqual(dragEvent.rawEvent.getDoubleValueField(.tabletEventPointPressure), 0.85, accuracy: 0.01)
        XCTAssertEqual(dragEvent.rawEvent.getIntegerValueField(.tabletEventPointButtons), 1)

        // 3. Stroke Ended (up)
        let ended = VPadPacket.stylusStroke(
            x: 0.3,
            y: 0.4,
            pressure: 0.0,
            tiltX: 0.0,
            tiltY: 0.0,
            rollAngle: 0.0,
            phase: .ended
        )
        injector.inject(ended)

        XCTAssertEqual(poster.count, 4)
        let upEvent = poster.events[3]
        XCTAssertEqual(upEvent.type, .leftMouseUp)
        XCTAssertEqual(upEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(upEvent.rawEvent.getIntegerValueField(.tabletEventPointButtons), 0)

        // Pen is still in proximity after stroke up
        let exit = VPadPacket.stylusProximity(phase: .ended)
        injector.inject(exit)

        XCTAssertEqual(poster.count, 5)
        let exitEvent = poster.events[4]
        XCTAssertEqual(exitEvent.type, .tabletProximity)
        XCTAssertEqual(exitEvent.rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    func testDisconnectMidStrokeEmitsUpAndLeaveProximity() {
        // Task 2.2: disconnect mid-stroke emits up + leave
        let strokeBegan = VPadPacket.stylusStroke(
            x: 0.5,
            y: 0.5,
            pressure: 0.5,
            tiltX: 0.0,
            tiltY: 0.0,
            rollAngle: 0.0,
            phase: .began
        )
        injector.inject(strokeBegan)

        XCTAssertEqual(poster.count, 2) // enterProximity + leftMouseDown

        // Disconnect triggers releaseAll()
        injector.releaseAll()

        // Must emit leftMouseUp followed by leave proximity
        XCTAssertEqual(poster.count, 4)
        XCTAssertEqual(poster.events[2].type, .leftMouseUp)
        XCTAssertEqual(poster.events[3].type, .tabletProximity)
        XCTAssertEqual(poster.events[3].rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    func testPressureAndTiltClamping() {
        // Task 2.2: pressure is clamped to 0...1, tilt to -1...1
        // Create packet and overwrite float fields to simulate out-of-bounds wire values
        let base = VPadPacket.stylusStroke(
            x: 0.5,
            y: 0.5,
            pressure: 0.5,
            tiltX: 0.0,
            tiltY: 0.0,
            rollAngle: 0.0,
            phase: .began
        )
        var data = base.toData()
        var rawPressure: Float32 = 2.5
        var rawTiltX: Float32 = 3.0
        var rawTiltY: Float32 = -4.0
        withUnsafeBytes(of: &rawPressure) { data.replaceSubrange(12..<16, with: $0) }
        withUnsafeBytes(of: &rawTiltX) { data.replaceSubrange(16..<20, with: $0) }
        withUnsafeBytes(of: &rawTiltY) { data.replaceSubrange(20..<24, with: $0) }
        guard let wirePacket = VPadPacket.fromData(data) else {
            XCTFail("Failed to decode wire packet")
            return
        }

        injector.inject(wirePacket)

        guard let downEvent = poster.events.last else {
            XCTFail("Expected posted event")
            return
        }
        XCTAssertEqual(downEvent.type, .leftMouseDown)
        XCTAssertEqual(downEvent.pressure, 1.0, accuracy: 0.01)
        XCTAssertEqual(downEvent.rawEvent.getDoubleValueField(.tabletEventPointPressure), 1.0, accuracy: 0.01)
        XCTAssertEqual(downEvent.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(downEvent.tiltY, -1.0, accuracy: 0.001)
    }

    func testProximityExitMidStrokeReleasesMouse() {
        let strokeBegan = VPadPacket.stylusStroke(
            x: 0.5,
            y: 0.5,
            pressure: 0.5,
            tiltX: 0.0,
            tiltY: 0.0,
            rollAngle: 0.0,
            phase: .began
        )
        injector.inject(strokeBegan)
        XCTAssertEqual(poster.events.last?.type, .leftMouseDown)

        // Exit proximity packet mid-stroke
        let exit = VPadPacket.stylusProximity(phase: .ended)
        injector.inject(exit)

        // Must emit leftMouseUp before tabletProximity exit
        XCTAssertEqual(poster.count, 4)
        XCTAssertEqual(poster.events[2].type, .leftMouseUp)
        XCTAssertEqual(poster.events[3].type, .tabletProximity)
        XCTAssertEqual(poster.events[3].rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    // MARK: - Heartbeat & Reconciliation Tests (§3.2)

    func testHeartbeatReconcilesMissedPenUp() {
        let began = VPadPacket.stylusStroke(x: 0.3, y: 0.4, pressure: 0.6, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .began)
        injector.inject(began)
        XCTAssertTrue(injector.stylusDown)
        let countBefore = poster.count

        // Heartbeat arrives stating pen is UP (client lifted pen, packet was lost)
        let heartbeat = VPadPacket.heartbeat(penDown: false, inProximity: true, buttonMask: 0, modifiers: 0, x: 0.3, y: 0.4)
        injector.inject(heartbeat)

        XCTAssertFalse(injector.stylusDown)
        XCTAssertEqual(poster.count, countBefore + 1)
        XCTAssertEqual(poster.events.last?.type, .leftMouseUp)
    }

    func testHeartbeatReconcilesMissedPenDown() {
        XCTAssertFalse(injector.stylusDown)

        // Heartbeat arrives stating pen is DOWN mid-stroke
        let heartbeat = VPadPacket.heartbeat(penDown: true, inProximity: true, buttonMask: 0, modifiers: 0, x: 0.5, y: 0.5, pressure: 0.7)
        injector.inject(heartbeat)

        XCTAssertTrue(injector.stylusDown)
        XCTAssertTrue(injector.stylusInProximity)
        XCTAssertEqual(poster.events.last?.type, .leftMouseDown)
    }

    func testHeartbeatReconcilesMissedProximityExit() {
        let enter = VPadPacket.stylusProximity(phase: .began)
        injector.inject(enter)
        XCTAssertTrue(injector.stylusInProximity)

        // Heartbeat arrives stating stylus is out of proximity
        let heartbeat = VPadPacket.heartbeat(penDown: false, inProximity: false, buttonMask: 0, modifiers: 0)
        injector.inject(heartbeat)

        XCTAssertFalse(injector.stylusInProximity)
        XCTAssertEqual(poster.events.last?.type, .tabletProximity)
        XCTAssertEqual(poster.events.last?.rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    func testHeartbeatReconcilesMissedMouseClickRelease() {
        let clickDown = VPadPacket.trackpadClick(button: .left, phase: .began)
        injector.inject(clickDown)
        XCTAssertTrue(injector.leftMouseDown)

        // Heartbeat arrives stating no buttons are down
        let heartbeat = VPadPacket.heartbeat(penDown: false, inProximity: false, buttonMask: 0, modifiers: 0)
        injector.inject(heartbeat)

        XCTAssertFalse(injector.leftMouseDown)
        XCTAssertEqual(poster.events.last?.type, .leftMouseUp)
    }

    func testHeartbeatReconcilesMissedSpacebarRelease() {
        let spaceDown = VPadPacket.trackpadMove(dx: 1, dy: 1, modifiers: ModifierMask.space.rawValue)
        injector.inject(spaceDown)
        XCTAssertTrue(injector.spacebarHeld)

        // Heartbeat arrives without Spacebar modifier
        let heartbeat = VPadPacket.heartbeat(penDown: false, inProximity: false, buttonMask: 0, modifiers: 0)
        injector.inject(heartbeat)

        XCTAssertFalse(injector.spacebarHeld)
        XCTAssertEqual(poster.events.last?.type, .keyUp)
    }

    func testHeartbeatNoOpWhenInSync() {
        poster.clear()
        let heartbeat = VPadPacket.heartbeat(penDown: false, inProximity: false, buttonMask: 0, modifiers: 0)
        injector.inject(heartbeat)

        XCTAssertEqual(poster.count, 0)
    }
}
