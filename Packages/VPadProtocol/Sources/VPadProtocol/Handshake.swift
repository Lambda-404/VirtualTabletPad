import CryptoKit
import Foundation

public enum HandshakeError: Error, Equatable {
    case invalidVersion
    case invalidLength
    case invalidPublicKey
    case invalidSignature
    case peerKeyNotAllowed
    case keyAgreementFailed
    case decryptionFailed
    case malformedTranscript
}

/// Established authenticated cryptographic session context.
public struct HandshakeSession: Sendable {
    public let sessionID: UInt32
    public let clientToHostKey: SymmetricKey
    public let hostToClientKey: SymmetricKey
    public let peerIdentityPublicKey: Data

    public init(
        sessionID: UInt32,
        clientToHostKey: SymmetricKey,
        hostToClientKey: SymmetricKey,
        peerIdentityPublicKey: Data
    ) {
        self.sessionID = sessionID
        self.clientToHostKey = clientToHostKey
        self.hostToClientKey = hostToClientKey
        self.peerIdentityPublicKey = peerIdentityPublicKey
    }
}

/// Client Hello message payload (129+ bytes).
public struct ClientHelloPayload: Equatable, Sendable {
    public static let expectedLength = 1 + 32 + 32 + 64

    public let version: UInt8
    public let ephemeralPublicKey: Data
    public let identityPublicKey: Data
    public let signature: Data
    public let pairingToken: Data?
    public let deviceName: String?

    public init(
        version: UInt8 = VPadConstants.protocolVersionV2,
        ephemeralPublicKey: Data,
        identityPublicKey: Data,
        signature: Data,
        pairingToken: Data? = nil,
        deviceName: String? = nil
    ) {
        self.version = version
        self.ephemeralPublicKey = ephemeralPublicKey
        self.identityPublicKey = identityPublicKey
        self.signature = signature
        self.pairingToken = pairingToken
        self.deviceName = deviceName
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.expectedLength + (pairingToken != nil ? 16 : 0))
        data.append(version)
        data.append(ephemeralPublicKey)
        data.append(identityPublicKey)
        data.append(signature)
        if let token = pairingToken {
            data.append(token.prefix(16))
            if let nameData = deviceName?.data(using: .utf8) {
                data.append(nameData)
            }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ClientHelloPayload {
        guard data.count >= expectedLength else {
            throw HandshakeError.invalidLength
        }
        let version = data[0]
        guard version == VPadConstants.protocolVersionV2 else {
            throw HandshakeError.invalidVersion
        }
        let ephemeral = Data(data[1..<33])
        let identity = Data(data[33..<65])
        let signature = Data(data[65..<129])

        var token: Data?
        var name: String?
        if data.count >= expectedLength + 16 {
            token = Data(data[129..<145])
            if data.count > 145 {
                name = String(data: data[145...], encoding: .utf8)
            }
        }

        return ClientHelloPayload(
            version: version,
            ephemeralPublicKey: ephemeral,
            identityPublicKey: identity,
            signature: signature,
            pairingToken: token,
            deviceName: name
        )
    }
}

/// Server Hello ACK message payload (149 bytes).
public struct ServerHelloAckPayload: Equatable, Sendable {
    public static let expectedLength = 1 + 32 + 32 + 64 + 20

    public let version: UInt8
    public let ephemeralPublicKey: Data
    public let identityPublicKey: Data
    public let signature: Data
    public let encryptedConfirmation: Data // 4 bytes sessionID + 16 bytes AES-GCM tag

    public init(
        version: UInt8 = VPadConstants.protocolVersionV2,
        ephemeralPublicKey: Data,
        identityPublicKey: Data,
        signature: Data,
        encryptedConfirmation: Data
    ) {
        self.version = version
        self.ephemeralPublicKey = ephemeralPublicKey
        self.identityPublicKey = identityPublicKey
        self.signature = signature
        self.encryptedConfirmation = encryptedConfirmation
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.expectedLength)
        data.append(version)
        data.append(ephemeralPublicKey)
        data.append(identityPublicKey)
        data.append(signature)
        data.append(encryptedConfirmation)
        return data
    }

    public static func decode(_ data: Data) throws -> ServerHelloAckPayload {
        guard data.count == expectedLength else {
            throw HandshakeError.invalidLength
        }
        let version = data[0]
        guard version == VPadConstants.protocolVersionV2 else {
            throw HandshakeError.invalidVersion
        }
        let ephemeral = Data(data[1..<33])
        let identity = Data(data[33..<65])
        let signature = Data(data[65..<129])
        let confirmation = Data(data[129..<149])
        return ServerHelloAckPayload(
            version: version,
            ephemeralPublicKey: ephemeral,
            identityPublicKey: identity,
            signature: signature,
            encryptedConfirmation: confirmation
        )
    }
}

/// State held by the client between sending ClientHello and receiving ServerHelloAck.
public struct ClientHandshakeState: Sendable {
    public let clientEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let clientIdentityKey: IdentityKey

    public init(
        clientEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        clientIdentityKey: IdentityKey
    ) {
        self.clientEphemeralPrivateKey = clientEphemeralPrivateKey
        self.clientIdentityKey = clientIdentityKey
    }
}

/// Orchestrates mutual authentication and key exchange (Task 1.3).
public enum VPadHandshake {
    private static let clientPrefix = Data("VPad-v2-Handshake-Client".utf8)
    private static let transcriptPrefix = Data("VPad-v2-Transcript".utf8)
    private static let confirmationNoncePrefix = Data("VPad-v2-Confirmation-Nonce".utf8)

    public static func clientTranscript(
        version: UInt8,
        ephemeralPublicKey: Data,
        identityPublicKey: Data,
        pairingToken: Data? = nil
    ) -> Data {
        var data = Data()
        data.append(clientPrefix)
        data.append(version)
        data.append(ephemeralPublicKey)
        data.append(identityPublicKey)
        if let token = pairingToken {
            data.append(token.prefix(16))
        }
        return data
    }

    public static func fullTranscriptHash(
        version: UInt8,
        clientEphemeral: Data,
        clientIdentity: Data,
        serverEphemeral: Data,
        serverIdentity: Data
    ) -> Data {
        var data = Data()
        data.append(transcriptPrefix)
        data.append(version)
        data.append(clientEphemeral)
        data.append(clientIdentity)
        data.append(serverEphemeral)
        data.append(serverIdentity)
        return Data(SHA256.hash(data: data))
    }

    public static func deriveDirectionalKeys(
        sharedSecret: SharedSecret,
        transcriptHash: Data
    ) -> (clientToHostKey: SymmetricKey, hostToClientKey: SymmetricKey) {
        let c2sKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data(VPadConstants.hkdfInfoV2C2S.utf8),
            outputByteCount: 32
        )
        let s2cKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data(VPadConstants.hkdfInfoV2S2C.utf8),
            outputByteCount: 32
        )
        return (c2sKey, s2cKey)
    }

    private static func confirmationNonce(transcriptHash: Data) -> AES.GCM.Nonce {
        var seed = Data()
        seed.append(confirmationNoncePrefix)
        seed.append(transcriptHash)
        let hash = SHA256.hash(data: seed)
        let nonceData = Data(hash.prefix(12))
        // Nonce initialization from 12 bytes cannot fail.
        return (try? AES.GCM.Nonce(data: nonceData)) ?? (try! AES.GCM.Nonce(data: Data(repeating: 0, count: 12)))
    }

    // MARK: - Client step 1

    public static func initiateClient(
        clientIdentity: IdentityKey,
        pairingToken: Data? = nil,
        deviceName: String? = nil
    ) throws -> (payload: ClientHelloPayload, state: ClientHandshakeState) {
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey.rawRepresentation
        let identityPublic = clientIdentity.publicKeyData

        let transcript = clientTranscript(
            version: VPadConstants.protocolVersionV2,
            ephemeralPublicKey: ephemeralPublic,
            identityPublicKey: identityPublic,
            pairingToken: pairingToken
        )
        let signature = try clientIdentity.sign(transcript)

        let payload = ClientHelloPayload(
            version: VPadConstants.protocolVersionV2,
            ephemeralPublicKey: ephemeralPublic,
            identityPublicKey: identityPublic,
            signature: signature,
            pairingToken: pairingToken,
            deviceName: deviceName
        )
        let state = ClientHandshakeState(
            clientEphemeralPrivateKey: ephemeralPrivate,
            clientIdentityKey: clientIdentity
        )
        return (payload, state)
    }

    // MARK: - Server step

    public static func respondServer(
        clientPayload: ClientHelloPayload,
        serverIdentity: IdentityKey,
        allowedClientIdentities: Set<Data>?,
        sessionID: UInt32
    ) throws -> (ackPayload: ServerHelloAckPayload, session: HandshakeSession) {
        guard clientPayload.version == VPadConstants.protocolVersionV2 else {
            throw HandshakeError.invalidVersion
        }

        // Validate client signature over client transcript
        let clientTranscriptData = clientTranscript(
            version: clientPayload.version,
            ephemeralPublicKey: clientPayload.ephemeralPublicKey,
            identityPublicKey: clientPayload.identityPublicKey,
            pairingToken: clientPayload.pairingToken
        )
        guard IdentityKey.verify(
            signature: clientPayload.signature,
            for: clientTranscriptData,
            publicKeyData: clientPayload.identityPublicKey
        ) else {
            throw HandshakeError.invalidSignature
        }

        // Validate allowlist if enforced
        if let allowed = allowedClientIdentities, !allowed.contains(clientPayload.identityPublicKey) {
            throw HandshakeError.peerKeyNotAllowed
        }

        guard let clientEphemeralKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPayload.ephemeralPublicKey) else {
            throw HandshakeError.invalidPublicKey
        }

        let serverEphemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let serverEphemeralPublic = serverEphemeralPrivate.publicKey.rawRepresentation
        let serverIdentityPublic = serverIdentity.publicKeyData

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try serverEphemeralPrivate.sharedSecretFromKeyAgreement(with: clientEphemeralKey)
        } catch {
            throw HandshakeError.keyAgreementFailed
        }

        let transcriptHash = fullTranscriptHash(
            version: clientPayload.version,
            clientEphemeral: clientPayload.ephemeralPublicKey,
            clientIdentity: clientPayload.identityPublicKey,
            serverEphemeral: serverEphemeralPublic,
            serverIdentity: serverIdentityPublic
        )

        let serverSignature = try serverIdentity.sign(transcriptHash)
        let (c2sKey, s2cKey) = deriveDirectionalKeys(sharedSecret: sharedSecret, transcriptHash: transcriptHash)

        // Encrypt sessionID confirmation
        var sessionIDBytes = Data(capacity: 4)
        sessionIDBytes.appendUInt32BE(sessionID)
        let nonce = confirmationNonce(transcriptHash: transcriptHash)

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(sessionIDBytes, using: s2cKey, nonce: nonce)
        } catch {
            throw HandshakeError.decryptionFailed
        }

        var encryptedConfirmation = Data()
        encryptedConfirmation.append(sealedBox.ciphertext)
        encryptedConfirmation.append(sealedBox.tag)

        let ackPayload = ServerHelloAckPayload(
            version: clientPayload.version,
            ephemeralPublicKey: serverEphemeralPublic,
            identityPublicKey: serverIdentityPublic,
            signature: serverSignature,
            encryptedConfirmation: encryptedConfirmation
        )

        let session = HandshakeSession(
            sessionID: sessionID,
            clientToHostKey: c2sKey,
            hostToClientKey: s2cKey,
            peerIdentityPublicKey: clientPayload.identityPublicKey
        )

        return (ackPayload, session)
    }

    // MARK: - Client step 2

    public static func completeClient(
        state: ClientHandshakeState,
        ackPayload: ServerHelloAckPayload,
        pinnedServerIdentity: Data?
    ) throws -> HandshakeSession {
        guard ackPayload.version == VPadConstants.protocolVersionV2 else {
            throw HandshakeError.invalidVersion
        }

        if let pinned = pinnedServerIdentity, pinned != ackPayload.identityPublicKey {
            throw HandshakeError.peerKeyNotAllowed
        }

        let transcriptHash = fullTranscriptHash(
            version: ackPayload.version,
            clientEphemeral: state.clientEphemeralPrivateKey.publicKey.rawRepresentation,
            clientIdentity: state.clientIdentityKey.publicKeyData,
            serverEphemeral: ackPayload.ephemeralPublicKey,
            serverIdentity: ackPayload.identityPublicKey
        )

        guard IdentityKey.verify(
            signature: ackPayload.signature,
            for: transcriptHash,
            publicKeyData: ackPayload.identityPublicKey
        ) else {
            throw HandshakeError.invalidSignature
        }

        guard let serverEphemeralKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ackPayload.ephemeralPublicKey) else {
            throw HandshakeError.invalidPublicKey
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try state.clientEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: serverEphemeralKey)
        } catch {
            throw HandshakeError.keyAgreementFailed
        }

        let (c2sKey, s2cKey) = deriveDirectionalKeys(sharedSecret: sharedSecret, transcriptHash: transcriptHash)

        // Decrypt confirmation to recover sessionID
        guard ackPayload.encryptedConfirmation.count == 20 else {
            throw HandshakeError.invalidLength
        }
        let ciphertext = Data(ackPayload.encryptedConfirmation.prefix(4))
        let tag = Data(ackPayload.encryptedConfirmation.suffix(16))
        let nonce = confirmationNonce(transcriptHash: transcriptHash)

        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: s2cKey)
            guard plaintext.count == 4, let sessionID = plaintext.readUInt32BE(at: 0) else {
                throw HandshakeError.decryptionFailed
            }
            return HandshakeSession(
                sessionID: sessionID,
                clientToHostKey: c2sKey,
                hostToClientKey: s2cKey,
                peerIdentityPublicKey: ackPayload.identityPublicKey
            )
        } catch {
            throw HandshakeError.decryptionFailed
        }
    }
}
