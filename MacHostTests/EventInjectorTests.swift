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

    // MARK: - Stylus Tests

    func testStylusHoverPostsTabletPointMouseMoved() {
        let hover = VPadPacket.stylusHover(
            x: 0.5,
            y: 0.5,
            tiltX: 0.25,
            tiltY: -0.15,
            rollAngle: Float32(Double.pi / 2),
            phase: .moved
        )
        injector.inject(hover)

        XCTAssertEqual(poster.count, 1)
        guard let event = poster.events.first else { return }
        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertEqual(event.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(event.pressure, 0.0, accuracy: 0.001)
        XCTAssertEqual(event.tiltX, 0.25, accuracy: 0.001)
        XCTAssertEqual(event.tiltY, -0.15, accuracy: 0.001)
        XCTAssertEqual(event.rotation, 90.0, accuracy: 0.5)

        // (0.5, 0.5) on 1920x1080 display
        let expectedX = CGFloat(0.5) * (1920.0 - 1.0)
        let expectedY = CGFloat(0.5) * (1080.0 - 1.0)
        XCTAssertEqual(event.location.x, expectedX, accuracy: 0.5)
        XCTAssertEqual(event.location.y, expectedY, accuracy: 0.5)
    }

    func testStylusStrokeLifecycle() {
        // 1. Began
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

        XCTAssertEqual(poster.count, 1)
        guard let beganEvent = poster.events.first else { return }
        XCTAssertEqual(beganEvent.type, .leftMouseDown)
        XCTAssertEqual(beganEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(beganEvent.pressure, 0.65, accuracy: 0.01)

        // 2. Moved (drag)
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

        XCTAssertEqual(poster.count, 2)
        guard let dragEvent = poster.events.last else { return }
        XCTAssertEqual(dragEvent.type, .leftMouseDragged)
        XCTAssertEqual(dragEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        XCTAssertEqual(dragEvent.pressure, 0.85, accuracy: 0.01)

        // 3. Ended (up)
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

        XCTAssertEqual(poster.count, 3)
        guard let upEvent = poster.events.last else { return }
        XCTAssertEqual(upEvent.type, .leftMouseUp)
        XCTAssertEqual(upEvent.subtype, Int64(CGEventMouseSubtype.tabletPoint.rawValue))
    }

    func testProximityEnteringAndExiting() {
        let enter = VPadPacket.stylusProximity(phase: .began)
        injector.inject(enter)

        XCTAssertEqual(poster.count, 1)
        guard let enterEvent = poster.events.first else { return }
        XCTAssertEqual(enterEvent.type, .tabletProximity)
        XCTAssertEqual(enterEvent.rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 1)

        // Exit proximity while pen was up
        let exit = VPadPacket.stylusProximity(phase: .ended)
        injector.inject(exit)

        XCTAssertEqual(poster.count, 2)
        guard let exitEvent = poster.events.last else { return }
        XCTAssertEqual(exitEvent.type, .tabletProximity)
        XCTAssertEqual(exitEvent.rawEvent.getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    func testProximityExitMidStrokeReleasesMouse() {
        // Start stroke
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

        // Exit proximity mid-stroke
        let exit = VPadPacket.stylusProximity(phase: .ended)
        injector.inject(exit)

        // Must emit leftMouseUp before tabletProximity exit
        XCTAssertEqual(poster.count, 3)
        XCTAssertEqual(poster.events[1].type, .leftMouseUp)
        XCTAssertEqual(poster.events[2].type, .tabletProximity)
    }

    func testReleaseAllReleasesActiveDragAndKeys() {
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

        injector.releaseAll()

        XCTAssertEqual(poster.events.last?.type, .leftMouseUp)
    }
}
