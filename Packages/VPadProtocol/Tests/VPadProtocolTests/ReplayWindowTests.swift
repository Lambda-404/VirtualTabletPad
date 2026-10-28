import CryptoKit
import XCTest
@testable import VPadProtocol

final class ReplayWindowTests: XCTestCase {
    func testReplayWindowInOrder() {
        var window = ReplayWindow()
        for seq in 0..<200 {
            XCTAssertTrue(window.checkAndAdvance(UInt64(seq)))
        }
        XCTAssertEqual(window.highestSequenceNumber, 199)
    }

    func testReplayWindowReorderedWithinWindow() {
        var window = ReplayWindow()
        // Send: 0, 2, 1, 4, 3
        XCTAssertTrue(window.checkAndAdvance(0))
        XCTAssertTrue(window.checkAndAdvance(2))
        XCTAssertTrue(window.checkAndAdvance(1)) // In-window out-of-order accepted
        XCTAssertTrue(window.checkAndAdvance(4))
        XCTAssertTrue(window.checkAndAdvance(3)) // In-window out-of-order accepted
    }

    func testReplayWindowRejectsDuplicates() {
        var window = ReplayWindow()
        XCTAssertTrue(window.checkAndAdvance(10))
        XCTAssertFalse(window.checkAndAdvance(10)) // Duplicate rejected

        XCTAssertTrue(window.checkAndAdvance(12))
        XCTAssertTrue(window.checkAndAdvance(11))
        XCTAssertFalse(window.checkAndAdvance(11)) // Duplicate rejected
        XCTAssertFalse(window.checkAndAdvance(12)) // Duplicate rejected
    }

    func testReplayWindowRejectsTooOldPackets() {
        var window = ReplayWindow()
        XCTAssertTrue(window.checkAndAdvance(200))
        // Window size is 128 (offsets 0..127), so sequence 73 is diff 127 (last accepted).
        // Sequence <= 72 is diff >= 128 (too old).
        XCTAssertTrue(window.checkAndAdvance(73)) // Boundary accepted (diff = 127)
        XCTAssertFalse(window.checkAndAdvance(72)) // Too old rejected (diff = 128 >= 128)
        XCTAssertFalse(window.checkAndAdvance(0))  // Stale packet rejected
    }

    func testLargeJumpClearsOldState() {
        var window = ReplayWindow()
        XCTAssertTrue(window.checkAndAdvance(10))
        XCTAssertTrue(window.checkAndAdvance(500)) // Jump >= 128
        XCTAssertEqual(window.highestSequenceNumber, 500)
        XCTAssertFalse(window.checkAndAdvance(10)) // Stale
        XCTAssertFalse(window.checkAndAdvance(500)) // Duplicate
        XCTAssertTrue(window.checkAndAdvance(499))  // In-window accepted
    }

    func testCounterNearOverflowRekeyFlag() {
        var window = ReplayWindow()
        XCTAssertFalse(window.isNearOverflow)
        XCTAssertTrue(window.checkAndAdvance(ReplayWindow.rekeyThreshold + 1))
        XCTAssertTrue(window.isNearOverflow)
    }

    func testV2SessionRoundTripAndProtection() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()
        let sessionID: UInt32 = 0xA1B2C3D4

        let (hello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let (ack, serverHandshake) = try VPadHandshake.respondServer(
            clientPayload: hello,
            serverIdentity: serverIdentity,
            allowedClientIdentities: nil,
            sessionID: sessionID
        )
        let clientHandshake = try VPadHandshake.completeClient(
            state: clientState,
            ackPayload: ack,
            pinnedServerIdentity: serverIdentity.publicKeyData
        )

        let clientSession = SessionCrypto(session: clientHandshake, role: .client)
        let serverSession = SessionCrypto(session: serverHandshake, role: .host)

        XCTAssertTrue(clientSession.isV2)
        XCTAssertTrue(serverSession.isV2)

        // 1. In-order packet round-trip
        let packet1 = VPadPacket.trackpadMove(dx: 12.5, dy: -4.0)
        guard let envelope1 = clientSession.sealUDP(packet1) else {
            return XCTFail("Failed to seal packet")
        }
        XCTAssertEqual(envelope1.count, 56)
        XCTAssertEqual(envelope1.readUInt32BE(at: 0), sessionID)
        XCTAssertEqual(envelope1.readUInt64BE(at: 4), 0) // seq 0

        guard let opened1 = serverSession.openUDP(envelope1) else {
            return XCTFail("Failed to open packet")
        }
        XCTAssertEqual(opened1.type, packet1.type)
        XCTAssertEqual(opened1.x, packet1.x)
        XCTAssertEqual(opened1.y, packet1.y)

        // 2. Duplicate rejection
        XCTAssertNil(serverSession.openUDP(envelope1))

        // 3. Reordered packet within window
        let packet2 = VPadPacket.trackpadMove(dx: 1.0, dy: 1.0)
        let packet3 = VPadPacket.trackpadMove(dx: 2.0, dy: 2.0)
        guard let envelope2 = clientSession.sealUDP(packet2),
              let envelope3 = clientSession.sealUDP(packet3) else {
            return XCTFail("Failed to seal packets")
        }
        // Receive packet 3 before packet 2
        XCTAssertNotNil(serverSession.openUDP(envelope3))
        XCTAssertNotNil(serverSession.openUDP(envelope2)) // Accepted in-window out-of-order!

        // 4. Mismatched session ID rejected immediately
        var wrongSessionEnv = envelope1
        wrongSessionEnv[0] ^= 0xFF
        XCTAssertNil(serverSession.openUDP(wrongSessionEnv))

        // 5. Tampered ciphertext or tag fails
        var tamperedEnv = envelope3
        tamperedEnv[45] ^= 0x55
        XCTAssertNil(serverSession.openUDP(tamperedEnv))
    }
}
