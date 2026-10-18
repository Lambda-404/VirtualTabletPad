import CryptoKit
import XCTest
@testable import VPadProtocol

final class CryptoManagerTests: XCTestCase {
    private let crypto = CryptoManager.shared

    func testHKDFDerivationIsSymmetricAndDeterministic() throws {
        let clientPrivate = crypto.generateKeyPair()
        let hostPrivate = crypto.generateKeyPair()
        let clientPublic = crypto.publicKeyData(for: clientPrivate)
        let hostPublic = crypto.publicKeyData(for: hostPrivate)
        XCTAssertEqual(clientPublic.count, 32)
        XCTAssertEqual(hostPublic.count, 32)

        let clientKey = try crypto.deriveSessionKey(
            privateKey: clientPrivate,
            remotePublicKeyData: hostPublic
        )
        let hostKey = try crypto.deriveSessionKey(
            privateKey: hostPrivate,
            remotePublicKeyData: clientPublic
        )
        XCTAssertEqual(rawBytes(clientKey), rawBytes(hostKey))

        let again = try crypto.deriveSessionKey(
            privateKey: clientPrivate,
            remotePublicKeyData: hostPublic
        )
        XCTAssertEqual(rawBytes(clientKey), rawBytes(again))
    }

    func testDeriveRejectsBadPublicKey() {
        let privateKey = crypto.generateKeyPair()
        XCTAssertThrowsError(try crypto.deriveSessionKey(
            privateKey: privateKey,
            remotePublicKeyData: Data(repeating: 0, count: 31)
        )) { error in
            XCTAssertEqual(error as? VPadCryptoError, .invalidPublicKey)
        }
    }

    func testUDPEnvelopeRoundTripAndLayout() throws {
        let key = SymmetricKey(size: .bits256)
        let packet = VPadPacket.stylusStroke(
            x: 0.5,
            y: 0.25,
            pressure: 0.8,
            tiltX: 0.1,
            tiltY: -0.2,
            rollAngle: 0.3,
            phase: .moved,
            modifiers: 0x0005
        )
        let envelope = try crypto.sealPacket(
            packet,
            using: key,
            direction: .udpClientToHost,
            counter: 42
        )
        XCTAssertEqual(envelope.count, VPadConstants.udpEnvelopeSize)
        let metadata = try XCTUnwrap(crypto.parseNonce(envelope))
        XCTAssertEqual(metadata.direction, .udpClientToHost)
        XCTAssertEqual(metadata.counter, 42)

        let opened = try crypto.openPacket(
            envelope,
            using: key,
            direction: .udpClientToHost,
            counter: 42
        )
        XCTAssertEqual(opened, packet)
    }

    func testUDPEnvelopeTamperAndDirectionMismatchFail() throws {
        let key = SymmetricKey(size: .bits256)
        let envelope = try crypto.sealPacket(
            VPadPacket.trackpadMove(dx: 1, dy: 2),
            using: key,
            direction: .udpClientToHost,
            counter: 0
        )

        var tampered = envelope
        tampered[20] ^= 0xFF
        XCTAssertThrowsError(try crypto.openPacket(
            tampered,
            using: key,
            direction: .udpClientToHost,
            counter: 0
        )) { error in
            XCTAssertEqual(error as? VPadCryptoError, .authenticationFailed)
        }

        XCTAssertThrowsError(try crypto.openPacket(
            envelope,
            using: key,
            direction: .udpHostToClient,
            counter: 0
        )) { error in
            XCTAssertEqual(error as? VPadCryptoError, .invalidNonce)
        }
    }

    func testSessionAcceptsRejectsReplayAndCountsGaps() throws {
        let key = SymmetricKey(size: .bits256)
        let session = SessionCrypto(key: key)
        let packet = VPadPacket.trackpadMove(dx: 2, dy: 3)

        let first = try crypto.sealPacket(
            packet,
            using: key,
            direction: .udpClientToHost,
            counter: 0
        )
        XCTAssertEqual(session.openUDP(first), packet)

        // Replay of counter 0.
        XCTAssertNil(session.openUDP(first))

        // A gap from 0 to 3 accepts but records two dropped datagrams.
        let gap = try crypto.sealPacket(
            packet,
            using: key,
            direction: .udpClientToHost,
            counter: 3
        )
        XCTAssertEqual(session.openUDP(gap), packet)

        var stats = session.stats()
        XCTAssertEqual(stats.received, 2)
        XCTAssertEqual(stats.dropped, 3) // 1 replay + 2 gap
        XCTAssertEqual(stats.lastUDPCounter, 3)

        // Tampered but higher counter must not advance lastUDPCounter.
        let tampered = try crypto.sealPacket(
            packet,
            using: key,
            direction: .udpClientToHost,
            counter: 4
        )
        var corrupted = tampered
        corrupted[30] ^= 0x01
        XCTAssertNil(session.openUDP(corrupted))

        stats = session.stats()
        XCTAssertEqual(stats.received, 2)
        XCTAssertEqual(stats.dropped, 4)
        XCTAssertEqual(stats.lastUDPCounter, 3)
    }

    func testTCPSessionPayloadRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let session = SessionCrypto(key: key)
        let payload = Data("hello-vpad".utf8)

        let fromClient = try crypto.sealTCPPayload(
            payload,
            using: key,
            direction: .tcpClientToHost,
            counter: 0
        )
        XCTAssertEqual(session.openTCP(fromClient), payload)
        XCTAssertNil(session.openTCP(fromClient)) // second frame uses counter 1

        let toClient = try XCTUnwrap(session.sealTCP(payload))
        let decrypted = try crypto.openTCPPayload(
            toClient,
            using: key,
            direction: .tcpHostToClient,
            counter: 0
        )
        XCTAssertEqual(decrypted, payload)
        XCTAssertEqual(session.stats().received, 1)
    }

    func testClientRoleUsesInverseDirections() throws {
        let key = SymmetricKey(size: .bits256)
        let host = SessionCrypto(key: key)
        let client = SessionCrypto(key: key, role: .client)
        let packet = VPadPacket.trackpadMove(dx: 4, dy: -2)

        let clientUDP = try XCTUnwrap(client.sealUDP(packet))
        XCTAssertEqual(crypto.parseNonce(clientUDP)?.direction, .udpClientToHost)
        XCTAssertEqual(host.openUDP(clientUDP), packet)

        let hostUDP = try XCTUnwrap(host.sealUDP(packet))
        XCTAssertEqual(crypto.parseNonce(hostUDP)?.direction, .udpHostToClient)
        XCTAssertEqual(client.openUDP(hostUDP), packet)

        let clientTCP = try XCTUnwrap(client.sealTCP(Data("client".utf8)))
        XCTAssertEqual(host.openTCP(clientTCP), Data("client".utf8))

        let hostTCP = try XCTUnwrap(host.sealTCP(Data("host".utf8)))
        XCTAssertEqual(client.openTCP(hostTCP), Data("host".utf8))
    }

    // MARK: - Helpers

    private func rawBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
