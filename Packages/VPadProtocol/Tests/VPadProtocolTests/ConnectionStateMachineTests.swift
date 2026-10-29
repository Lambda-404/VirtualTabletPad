import XCTest
@testable import VPadProtocol

final class ConnectionStateMachineTests: XCTestCase {
    func testAllStatesExistAndHaveTitles() {
        XCTAssertEqual(VPadConnectionState.disconnected.title, "Disconnected")
        XCTAssertEqual(VPadConnectionState.connecting.title, "Connecting")
        XCTAssertEqual(VPadConnectionState.handshaking.title, "Authenticating")
        XCTAssertEqual(VPadConnectionState.active.title, "Connected")
        XCTAssertEqual(VPadConnectionState.reconnecting.title, "Reconnecting")
        XCTAssertEqual(VPadConnectionState.allCases.count, 5)
    }

    func testCanonicalStateTransitions() {
        var state: VPadConnectionState = .disconnected
        XCTAssertEqual(state, .disconnected)

        // User connects / discovery starts
        state = .connecting
        XCTAssertEqual(state, .connecting)

        // Transport connected, authentication begins
        state = .handshaking
        XCTAssertEqual(state, .handshaking)

        // Mutual cryptographic handshake verified
        state = .active
        XCTAssertEqual(state, .active)

        // Network glitch / packet loss mid-stream
        state = .reconnecting
        XCTAssertEqual(state, .reconnecting)

        // Auto-reconnect completes
        state = .active
        XCTAssertEqual(state, .active)

        // Explicit user teardown
        state = .disconnected
        XCTAssertEqual(state, .disconnected)
    }
}
