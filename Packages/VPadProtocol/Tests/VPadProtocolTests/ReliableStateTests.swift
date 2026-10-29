import XCTest
@testable import VPadProtocol

final class ReliableStateTests: XCTestCase {

    // MARK: - Event Classification Tests

    func testStateEventClassification() {
        // Continuous events (loss is fine, rate is 120-240Hz)
        XCTAssertFalse(VPadPacket.trackpadMove(dx: 1.0, dy: 2.0).isStateEvent)
        XCTAssertFalse(VPadPacket.trackpadScroll(dx: 0, dy: 5.0).isStateEvent)
        XCTAssertFalse(VPadPacket.stylusHover(x: 0.5, y: 0.5, tiltX: 0, tiltY: 0, rollAngle: 0).isStateEvent)
        XCTAssertFalse(VPadPacket.stylusStroke(x: 0.5, y: 0.5, pressure: 0.5, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .moved).isStateEvent)

        // State events (critical lifecycle, must not be lost)
        XCTAssertTrue(VPadPacket.stylusStroke(x: 0.5, y: 0.5, pressure: 0.5, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .began).isStateEvent)
        XCTAssertTrue(VPadPacket.stylusStroke(x: 0.5, y: 0.5, pressure: 0.0, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .ended).isStateEvent)
        XCTAssertTrue(VPadPacket.stylusStroke(x: 0.5, y: 0.5, pressure: 0.0, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .cancelled).isStateEvent)

        XCTAssertTrue(VPadPacket.trackpadClick(button: .left, phase: .began).isStateEvent)
        XCTAssertTrue(VPadPacket.trackpadClick(button: .left, phase: .ended).isStateEvent)
        XCTAssertTrue(VPadPacket.trackpadClick(button: .right, phase: .began).isStateEvent)
        XCTAssertTrue(VPadPacket.trackpadClick(button: .right, phase: .ended).isStateEvent)

        XCTAssertTrue(VPadPacket.stylusProximity(phase: .began).isStateEvent)
        XCTAssertTrue(VPadPacket.stylusProximity(phase: .ended).isStateEvent)
        XCTAssertTrue(VPadPacket.stylusSqueeze(x: 0.5, y: 0.5, rollAngle: 0).isStateEvent)
        XCTAssertTrue(VPadPacket.stylusDoubleTap().isStateEvent)

        XCTAssertTrue(VPadPacket.keyShortcut(keyCode: 53).isStateEvent)
        XCTAssertTrue(VPadPacket.keyboardPress(keyCode: 49, phase: .began).isStateEvent)
        XCTAssertTrue(VPadPacket.keyboardPress(keyCode: 49, phase: .ended).isStateEvent)
        XCTAssertTrue(VPadPacket.customGesture(id: 101).isStateEvent)
        XCTAssertTrue(VPadPacket.systemAction(.playPause).isStateEvent)
    }

    // MARK: - Cumulative ACK Encoding Tests

    func testHostAckBitPatternRoundTrip() {
        let testVectors: [UInt64] = [
            0,
            1,
            42,
            0xFFFF,
            0xFFFF_FFFF,
            0x1_0000_0000,
            0x1234_5678_9ABC_DEF0,
            0xDEAD_BEEF_CAFE_BABE,
            UInt64.max - 1,
            UInt64.max
        ]

        for seq in testVectors {
            let ackPacket = VPadPacket.hostAck(cumulativeSeq: seq)
            XCTAssertEqual(ackPacket.type, EventType.hostAck.rawValue)
            XCTAssertFalse(ackPacket.isStateEvent)

            // Verify serialization to raw 28-byte data and deserialization
            let data = ackPacket.toData()
            XCTAssertEqual(data.count, 28)
            guard let roundTrip = VPadPacket.fromData(data) else {
                XCTFail("Failed to deserialize hostAck packet")
                continue
            }
            XCTAssertEqual(roundTrip.ackSequenceNumber, seq)
        }
    }

    // MARK: - StateResendEngine Tests

    func testStateResendEngineRetransmissionAndAck() {
        let engine = StateResendEngine(config: .init(maxResends: 3, resendInterval: 0.015))

        // 1. Continuous packet sent -> not tracked
        let continuous = VPadPacket.stylusStroke(x: 0.1, y: 0.1, pressure: 0.5, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .moved)
        engine.onPacketSent(continuous, seq: 10, now: 1.0)
        XCTAssertEqual(engine.pendingCount, 0)

        // 2. State packet sent -> tracked
        let penDown = VPadPacket.stylusStroke(x: 0.1, y: 0.1, pressure: 0.5, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .began)
        engine.onPacketSent(penDown, seq: 11, now: 1.0)
        XCTAssertEqual(engine.pendingCount, 1)

        // 3. Before resend interval elapses -> nil
        XCTAssertNil(engine.nextResendPacket(now: 1.010))

        // 4. At resend interval -> returns packet, decrements remaining
        let resend1 = engine.nextResendPacket(now: 1.016)
        XCTAssertNotNil(resend1)
        XCTAssertEqual(resend1?.phase, Phase.began.rawValue)

        // 5. Host acknowledges seq 11 -> removed from pending
        engine.onAckReceived(11)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertNil(engine.nextResendPacket(now: 1.050))
    }

    func testStateResendEngineExhaustsMaxAttempts() {
        let engine = StateResendEngine(config: .init(maxResends: 2, resendInterval: 0.010))

        let penUp = VPadPacket.stylusStroke(x: 0.1, y: 0.1, pressure: 0.0, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .ended)
        engine.onPacketSent(penUp, seq: 50, now: 0.0)
        XCTAssertEqual(engine.pendingCount, 1)

        // First resend attempt
        let r1 = engine.nextResendPacket(now: 0.011)
        XCTAssertNotNil(r1)

        // Second resend attempt
        let r2 = engine.nextResendPacket(now: 0.022)
        XCTAssertNotNil(r2)

        // Exhausted after 2 resends -> returns nil and cleans up
        let r3 = engine.nextResendPacket(now: 0.033)
        XCTAssertNil(r3)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    // MARK: - End-to-End Simulated Loss Test

    func testSimulatedLossPenUpStillResultsInPenUpOnHost() throws {
        // Setup authenticated session between client and host
        let hostIdentity = IdentityKey()
        let clientIdentity = IdentityKey()
        let sessionID: UInt32 = 0x12345678

        let (clientHello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let (serverAck, hostSession) = try VPadHandshake.respondServer(
            clientPayload: clientHello,
            serverIdentity: hostIdentity,
            allowedClientIdentities: [clientIdentity.publicKeyData],
            sessionID: sessionID
        )
        let clientSession = try VPadHandshake.completeClient(
            state: clientState,
            ackPayload: serverAck,
            pinnedServerIdentity: hostIdentity.publicKeyData
        )

        let clientCrypto = SessionCrypto(session: clientSession, role: .client)
        let hostCrypto = SessionCrypto(session: hostSession, role: .host)
        let clientResendEngine = StateResendEngine(config: .init(maxResends: 4, resendInterval: 0.015))

        var simulatedTime: TimeInterval = 100.0

        // 1. Client sends Pen Down
        let penDown = VPadPacket.stylusStroke(x: 0.2, y: 0.3, pressure: 0.5, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .began)
        let (downEnv, downSeq) = clientCrypto.sealUDPWithSeq(penDown)!
        clientResendEngine.onPacketSent(penDown, seq: downSeq, now: simulatedTime)

        // Host receives Pen Down
        guard let hostReceivedDown = hostCrypto.openUDP(downEnv) else {
            XCTFail("Host failed to decrypt down packet")
            return
        }
        XCTAssertEqual(hostReceivedDown.phase, Phase.began.rawValue)

        // Host acknowledges Pen Down
        let downAck = VPadPacket.hostAck(cumulativeSeq: downSeq)
        let downAckEnv = hostCrypto.sealUDP(downAck)!
        let clientReceivedDownAck = clientCrypto.openUDP(downAckEnv)!
        clientResendEngine.onAckReceived(clientReceivedDownAck.ackSequenceNumber!)
        XCTAssertEqual(clientResendEngine.pendingCount, 0)

        // 2. Client sends continuous Pen Moved samples
        simulatedTime += 0.008
        let penMove = VPadPacket.stylusStroke(x: 0.25, y: 0.35, pressure: 0.6, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .moved)
        let (moveEnv, moveSeq) = clientCrypto.sealUDPWithSeq(penMove)!
        clientResendEngine.onPacketSent(penMove, seq: moveSeq, now: simulatedTime)
        XCTAssertEqual(clientResendEngine.pendingCount, 0)

        guard let hostReceivedMove = hostCrypto.openUDP(moveEnv) else {
            XCTFail("Host failed to decrypt move packet")
            return
        }
        XCTAssertEqual(hostReceivedMove.phase, Phase.moved.rawValue)

        // 3. Client sends Pen Up
        simulatedTime += 0.008
        let penUp = VPadPacket.stylusStroke(x: 0.3, y: 0.4, pressure: 0.0, tiltX: 0, tiltY: 0, rollAngle: 0, phase: .ended)
        let (_, upSeq) = clientCrypto.sealUDPWithSeq(penUp)!
        clientResendEngine.onPacketSent(penUp, seq: upSeq, now: simulatedTime)
        XCTAssertEqual(clientResendEngine.pendingCount, 1)

        // >>> SIMULATED NETWORK DROP <<<
        // Packet with upSeq is completely dropped by lossy Wi-Fi.
        // Host has NOT received pen up yet!
        XCTAssertEqual(hostCrypto.highestSequenceNumber, moveSeq)

        // 4. Timer advances past resendInterval: Client triggers retransmission!
        simulatedTime += 0.016
        guard let retransmittedPenUp = clientResendEngine.nextResendPacket(now: simulatedTime) else {
            XCTFail("Resend engine should have provided penUp for retransmission")
            return
        }
        XCTAssertEqual(retransmittedPenUp.phase, Phase.ended.rawValue)

        // Retransmitted packet is sealed with a fresh sequence number
        let (retransmitEnv, retransmitSeq) = clientCrypto.sealUDPWithSeq(retransmittedPenUp)!
        XCTAssertGreaterThan(retransmitSeq, upSeq)

        // Retransmitted packet successfully reaches Host!
        guard let hostReceivedUp = hostCrypto.openUDP(retransmitEnv) else {
            XCTFail("Host failed to decrypt retransmitted penUp packet")
            return
        }
        XCTAssertEqual(hostReceivedUp.phase, Phase.ended.rawValue)
        XCTAssertEqual(hostCrypto.highestSequenceNumber, retransmitSeq)

        // Host generates cumulative ACK for retransmitSeq
        let upAck = VPadPacket.hostAck(cumulativeSeq: retransmitSeq)
        let upAckEnv = hostCrypto.sealUDP(upAck)!

        // Client receives ACK and clears pending queue
        guard let clientReceivedUpAck = clientCrypto.openUDP(upAckEnv) else {
            XCTFail("Client failed to decrypt upAck")
            return
        }
        clientResendEngine.onAckReceived(clientReceivedUpAck.ackSequenceNumber!)
        XCTAssertEqual(clientResendEngine.pendingCount, 0)

        // Stroke completed reliably despite initial packet loss
    }
}
