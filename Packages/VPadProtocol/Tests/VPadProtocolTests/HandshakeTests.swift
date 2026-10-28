import CryptoKit
import XCTest
@testable import VPadProtocol

final class HandshakeTests: XCTestCase {
    func testSuccessfulMutualHandshake() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()
        let sessionID: UInt32 = 0x12345678

        // Client step 1
        let (clientHello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let clientHelloData = clientHello.encode()
        XCTAssertEqual(clientHelloData.count, ClientHelloPayload.expectedLength)

        // Server receives and parses
        let decodedClientHello = try ClientHelloPayload.decode(clientHelloData)
        let allowedClients: Set<Data> = [clientIdentity.publicKeyData]

        // Server step
        let (serverAck, serverSession) = try VPadHandshake.respondServer(
            clientPayload: decodedClientHello,
            serverIdentity: serverIdentity,
            allowedClientIdentities: allowedClients,
            sessionID: sessionID
        )
        let serverAckData = serverAck.encode()
        XCTAssertEqual(serverAckData.count, ServerHelloAckPayload.expectedLength)

        // Client step 2
        let decodedServerAck = try ServerHelloAckPayload.decode(serverAckData)
        let clientSession = try VPadHandshake.completeClient(
            state: clientState,
            ackPayload: decodedServerAck,
            pinnedServerIdentity: serverIdentity.publicKeyData
        )

        // Verify session equivalence
        XCTAssertEqual(clientSession.sessionID, sessionID)
        XCTAssertEqual(serverSession.sessionID, sessionID)
        XCTAssertEqual(clientSession.clientToHostKey, serverSession.clientToHostKey)
        XCTAssertEqual(clientSession.hostToClientKey, serverSession.hostToClientKey)
        XCTAssertNotEqual(clientSession.clientToHostKey, clientSession.hostToClientKey)
        XCTAssertEqual(clientSession.peerIdentityPublicKey, serverIdentity.publicKeyData)
        XCTAssertEqual(serverSession.peerIdentityPublicKey, clientIdentity.publicKeyData)
    }

    func testWrongPinnedServerKeyFails() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()
        let imposterIdentity = IdentityKey()

        let (clientHello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let (serverAck, _) = try VPadHandshake.respondServer(
            clientPayload: clientHello,
            serverIdentity: serverIdentity,
            allowedClientIdentities: nil,
            sessionID: 0xCAFEBABE
        )

        // Client pins imposterIdentity, but server presented serverIdentity
        XCTAssertThrowsError(
            try VPadHandshake.completeClient(
                state: clientState,
                ackPayload: serverAck,
                pinnedServerIdentity: imposterIdentity.publicKeyData
            )
        ) { error in
            XCTAssertEqual(error as? HandshakeError, .peerKeyNotAllowed)
        }
    }

    func testUnallowedClientFailsServerValidation() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()
        let allowedClientIdentity = IdentityKey()

        let (clientHello, _) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let allowedSet: Set<Data> = [allowedClientIdentity.publicKeyData]

        XCTAssertThrowsError(
            try VPadHandshake.respondServer(
                clientPayload: clientHello,
                serverIdentity: serverIdentity,
                allowedClientIdentities: allowedSet,
                sessionID: 100
            )
        ) { error in
            XCTAssertEqual(error as? HandshakeError, .peerKeyNotAllowed)
        }
    }

    func testTamperedClientSignatureFails() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()

        let (clientHello, _) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)

        var tamperedSignature = clientHello.signature
        tamperedSignature[0] ^= 0xAA

        let tamperedHello = ClientHelloPayload(
            version: clientHello.version,
            ephemeralPublicKey: clientHello.ephemeralPublicKey,
            identityPublicKey: clientHello.identityPublicKey,
            signature: tamperedSignature
        )

        XCTAssertThrowsError(
            try VPadHandshake.respondServer(
                clientPayload: tamperedHello,
                serverIdentity: serverIdentity,
                allowedClientIdentities: nil,
                sessionID: 1
            )
        ) { error in
            XCTAssertEqual(error as? HandshakeError, .invalidSignature)
        }
    }

    func testTamperedServerSignatureFails() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()

        let (clientHello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let (serverAck, _) = try VPadHandshake.respondServer(
            clientPayload: clientHello,
            serverIdentity: serverIdentity,
            allowedClientIdentities: nil,
            sessionID: 1
        )

        var tamperedSignature = serverAck.signature
        tamperedSignature[10] ^= 0xFF

        let tamperedAck = ServerHelloAckPayload(
            version: serverAck.version,
            ephemeralPublicKey: serverAck.ephemeralPublicKey,
            identityPublicKey: serverAck.identityPublicKey,
            signature: tamperedSignature,
            encryptedConfirmation: serverAck.encryptedConfirmation
        )

        XCTAssertThrowsError(
            try VPadHandshake.completeClient(
                state: clientState,
                ackPayload: tamperedAck,
                pinnedServerIdentity: serverIdentity.publicKeyData
            )
        ) { error in
            XCTAssertEqual(error as? HandshakeError, .invalidSignature)
        }
    }

    func testTamperedConfirmationFailsDecryption() throws {
        let clientIdentity = IdentityKey()
        let serverIdentity = IdentityKey()

        let (clientHello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let (serverAck, _) = try VPadHandshake.respondServer(
            clientPayload: clientHello,
            serverIdentity: serverIdentity,
            allowedClientIdentities: nil,
            sessionID: 1
        )

        var tamperedConfirmation = serverAck.encryptedConfirmation
        tamperedConfirmation[0] ^= 0x01

        let tamperedAck = ServerHelloAckPayload(
            version: serverAck.version,
            ephemeralPublicKey: serverAck.ephemeralPublicKey,
            identityPublicKey: serverAck.identityPublicKey,
            signature: serverAck.signature,
            encryptedConfirmation: tamperedConfirmation
        )

        XCTAssertThrowsError(
            try VPadHandshake.completeClient(
                state: clientState,
                ackPayload: tamperedAck,
                pinnedServerIdentity: serverIdentity.publicKeyData
            )
        ) { error in
            XCTAssertEqual(error as? HandshakeError, .decryptionFailed)
        }
    }

    func testKnownAnswerTestVector() throws {
        // Deterministic raw private key seeds
        let clientPrivData = Data(repeating: 0x11, count: 32)
        let serverPrivData = Data(repeating: 0x22, count: 32)

        let clientIdentity = try IdentityKey(rawRepresentation: clientPrivData)
        let serverIdentity = try IdentityKey(rawRepresentation: serverPrivData)

        let (hello, clientState) = try VPadHandshake.initiateClient(clientIdentity: clientIdentity)
        let (ack, serverSession) = try VPadHandshake.respondServer(
            clientPayload: hello,
            serverIdentity: serverIdentity,
            allowedClientIdentities: nil,
            sessionID: 0x99887766
        )

        let clientSession = try VPadHandshake.completeClient(
            state: clientState,
            ackPayload: ack,
            pinnedServerIdentity: serverIdentity.publicKeyData
        )

        XCTAssertEqual(clientSession.sessionID, 0x99887766)
        XCTAssertEqual(serverSession.sessionID, 0x99887766)
        XCTAssertEqual(clientSession.clientToHostKey, serverSession.clientToHostKey)
    }
}
