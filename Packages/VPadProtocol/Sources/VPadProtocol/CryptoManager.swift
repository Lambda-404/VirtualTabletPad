import CryptoKit
import Foundation

public enum VPadCryptoError: Error, Equatable {
    case invalidPublicKey
    case keyAgreementFailed
    case invalidEnvelope
    case invalidNonce
    case authenticationFailed
    case invalidPacket
    case sealFailed
}

/// Stateless cryptographic primitives shared by both ends.
public final class CryptoManager: @unchecked Sendable {
    public static let shared = CryptoManager()

    public init() {}

    public func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    public func publicKeyData(for privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data {
        privateKey.publicKey.rawRepresentation
    }

    public func deriveSessionKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKeyData: Data
    ) throws -> SymmetricKey {
        guard remotePublicKeyData.count == VPadConstants.publicKeySize else {
            throw VPadCryptoError.invalidPublicKey
        }
        let remoteKey: Curve25519.KeyAgreement.PublicKey
        do {
            remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyData)
        } catch {
            throw VPadCryptoError.invalidPublicKey
        }
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        } catch {
            throw VPadCryptoError.keyAgreementFailed
        }
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: VPadConstants.hkdfSalt,
            sharedInfo: VPadConstants.hkdfInfo,
            outputByteCount: 32
        )
    }

    /// 12-byte nonce: 4-byte big-endian direction + 8-byte big-endian counter.
    public func nonce(direction: CryptoDirection, counter: UInt64) -> Data {
        var data = Data(capacity: VPadConstants.nonceSize)
        data.appendUInt32BE(direction.rawValue)
        data.appendUInt64BE(counter)
        return data
    }

    /// 12-byte v2 nonce: 4-byte big-endian sessionID + 8-byte big-endian sequence number (§1.4).
    public func nonceV2(sessionID: UInt32, seq: UInt64) -> Data {
        var data = Data(capacity: VPadConstants.nonceSize)
        data.appendUInt32BE(sessionID)
        data.appendUInt64BE(seq)
        return data
    }

    public func parseNonce(_ envelope: Data) -> (direction: CryptoDirection, counter: UInt64)? {
        guard envelope.count >= VPadConstants.nonceSize,
              let rawDirection = envelope.readUInt32BE(at: 0),
              let counter = envelope.readUInt64BE(at: 4),
              let direction = CryptoDirection(rawValue: rawDirection) else {
            return nil
        }
        return (direction, counter)
    }

    /// Returns the fixed 56-byte UDP datagram (§3.2 / v1).
    public func sealPacket(
        _ packet: VPadPacket,
        using key: SymmetricKey,
        direction: CryptoDirection,
        counter: UInt64
    ) throws -> Data {
        let nonceData = nonce(direction: direction, counter: counter)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.seal(packet.toData(), using: key, nonce: nonce)
            var envelope = Data(capacity: VPadConstants.udpEnvelopeSize)
            envelope.append(nonceData)
            envelope.append(sealed.ciphertext)
            envelope.append(sealed.tag)
            return envelope
        } catch {
            throw VPadCryptoError.sealFailed
        }
    }

    /// Returns the fixed 56-byte v2 UDP datagram: `sessionID (4B) | seq (8B) | ciphertext (28B) | tag (16B)`.
    public func sealPacketV2(
        _ packet: VPadPacket,
        sessionID: UInt32,
        seq: UInt64,
        using key: SymmetricKey
    ) throws -> Data {
        let nonceData = nonceV2(sessionID: sessionID, seq: seq)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.seal(packet.toData(), using: key, nonce: nonce)
            var envelope = Data(capacity: VPadConstants.udpEnvelopeSize)
            envelope.append(nonceData)
            envelope.append(sealed.ciphertext)
            envelope.append(sealed.tag)
            return envelope
        } catch {
            throw VPadCryptoError.sealFailed
        }
    }

    public func openPacket(
        _ envelope: Data,
        using key: SymmetricKey,
        direction: CryptoDirection,
        counter: UInt64
    ) throws -> VPadPacket {
        guard envelope.count == VPadConstants.udpEnvelopeSize else {
            throw VPadCryptoError.invalidEnvelope
        }
        let nonceData = nonce(direction: direction, counter: counter)
        guard envelope.prefix(VPadConstants.nonceSize).elementsEqual(nonceData) else {
            throw VPadCryptoError.invalidNonce
        }
        let ciphertext = Data(envelope[12..<40])
        let tag = Data(envelope[40..<56])
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let packet = VPadPacket.fromData(plaintext) else {
                throw VPadCryptoError.invalidPacket
            }
            return packet
        } catch let error as VPadCryptoError {
            throw error
        } catch {
            throw VPadCryptoError.authenticationFailed
        }
    }

    public func openPacketV2(
        _ envelope: Data,
        expectedSessionID: UInt32,
        using key: SymmetricKey
    ) throws -> (seq: UInt64, packet: VPadPacket) {
        guard envelope.count == VPadConstants.udpEnvelopeSize else {
            throw VPadCryptoError.invalidEnvelope
        }
        guard let sessionID = envelope.readUInt32BE(at: 0),
              sessionID == expectedSessionID,
              let seq = envelope.readUInt64BE(at: 4) else {
            throw VPadCryptoError.invalidEnvelope
        }
        let nonceData = Data(envelope.prefix(VPadConstants.nonceSize))
        let ciphertext = Data(envelope[12..<40])
        let tag = Data(envelope[40..<56])
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let packet = VPadPacket.fromData(plaintext) else {
                throw VPadCryptoError.invalidPacket
            }
            return (seq, packet)
        } catch let error as VPadCryptoError {
            throw error
        } catch {
            throw VPadCryptoError.authenticationFailed
        }
    }

    /// Encrypts a TCP payload. The nonce is not transmitted: both ends derive
    /// it from the session direction and an ordered counter.
    public func sealTCPPayload(
        _ payload: Data,
        using key: SymmetricKey,
        direction: CryptoDirection,
        counter: UInt64
    ) throws -> Data {
        let nonceData = nonce(direction: direction, counter: counter)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.seal(payload, using: key, nonce: nonce)
            var output = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
            output.append(sealed.ciphertext)
            output.append(sealed.tag)
            return output
        } catch {
            throw VPadCryptoError.sealFailed
        }
    }

    public func openTCPPayload(
        _ payload: Data,
        using key: SymmetricKey,
        direction: CryptoDirection,
        counter: UInt64
    ) throws -> Data {
        guard payload.count >= VPadConstants.tagSize else {
            throw VPadCryptoError.invalidEnvelope
        }
        let ciphertext = Data(payload.prefix(payload.count - VPadConstants.tagSize))
        let tag = Data(payload.suffix(VPadConstants.tagSize))
        let nonceData = nonce(direction: direction, counter: counter)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VPadCryptoError.authenticationFailed
        }
    }
}

public struct SessionStats: Equatable, Sendable {
    public var received: UInt64
    public var dropped: UInt64
    public var lastUDPCounter: UInt64?

    public init(received: UInt64 = 0, dropped: UInt64 = 0, lastUDPCounter: UInt64? = nil) {
        self.received = received
        self.dropped = dropped
        self.lastUDPCounter = lastUDPCounter
    }
}

/// Which side of the session owns this `SessionCrypto`; determines the nonce
/// direction discriminators used for sealing and opening.
public enum SessionRole: Sendable, Equatable {
    case host
    case client
}

/// Per-session hot-path state: key, direction counters and anti-replay state.
/// Synchronous by design so the UDP receive loop never needs an actor hop.
public final class SessionCrypto: @unchecked Sendable {
    public let sessionID: UInt32?
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let role: SessionRole
    private let lock = NSLock()
    private let crypto = CryptoManager.shared
    private var replayWindow = ReplayWindow()

    private var udpSendCounter: UInt64 = 0
    private var tcpSendCounter: UInt64 = 0
    private var tcpReceiveCounter: UInt64 = 0
    private var lastUDPCounter: UInt64?
    private var received: UInt64 = 0
    private var dropped: UInt64 = 0

    /// V1 legacy constructor (symmetric shared key).
    public init(key: SymmetricKey, role: SessionRole = .host) {
        self.sessionID = nil
        self.sendKey = key
        self.receiveKey = key
        self.role = role
    }

    /// V2 constructor (HandshakeSession with directional keys, sessionID, and ReplayWindow).
    public init(session: HandshakeSession, role: SessionRole) {
        self.sessionID = session.sessionID
        self.role = role
        if role == .client {
            self.sendKey = session.clientToHostKey
            self.receiveKey = session.hostToClientKey
        } else {
            self.sendKey = session.hostToClientKey
            self.receiveKey = session.clientToHostKey
        }
    }

    public var isV2: Bool {
        sessionID != nil
    }

    public var isNearRekeyThreshold: Bool {
        lock.lock()
        defer { lock.unlock() }
        return replayWindow.isNearOverflow || udpSendCounter >= ReplayWindow.rekeyThreshold
    }

    public var highestSequenceNumber: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return replayWindow.highestSequenceNumber ?? lastUDPCounter
    }

    private var udpSendDirection: CryptoDirection {
        role == .host ? .udpHostToClient : .udpClientToHost
    }

    private var udpReceiveDirection: CryptoDirection {
        role == .host ? .udpClientToHost : .udpHostToClient
    }

    private var tcpSendDirection: CryptoDirection {
        role == .host ? .tcpHostToClient : .tcpClientToHost
    }

    private var tcpReceiveDirection: CryptoDirection {
        role == .host ? .tcpClientToHost : .tcpHostToClient
    }

    // MARK: UDP

    public func sealUDP(_ packet: VPadPacket) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let counter = udpSendCounter
        if let sessionID {
            guard let envelope = try? crypto.sealPacketV2(
                packet,
                sessionID: sessionID,
                seq: counter,
                using: sendKey
            ) else {
                return nil
            }
            udpSendCounter += 1
            return envelope
        } else {
            guard let envelope = try? crypto.sealPacket(
                packet,
                using: sendKey,
                direction: udpSendDirection,
                counter: counter
            ) else {
                return nil
            }
            udpSendCounter += 1
            return envelope
        }
    }

    public func openUDP(_ envelope: Data) -> VPadPacket? {
        lock.lock()
        defer { lock.unlock() }

        if let sessionID {
            guard envelope.count == VPadConstants.udpEnvelopeSize,
                  let id = envelope.readUInt32BE(at: 0),
                  id == sessionID,
                  let seq = envelope.readUInt64BE(at: 4) else {
                dropped += 1
                return nil
            }

            guard replayWindow.checkAndAdvance(seq) else {
                dropped += 1
                return nil
            }

            guard let (_, packet) = try? crypto.openPacketV2(
                envelope,
                expectedSessionID: sessionID,
                using: receiveKey
            ) else {
                dropped += 1
                return nil
            }

            lastUDPCounter = seq
            received += 1
            return packet
        } else {
            guard envelope.count == VPadConstants.udpEnvelopeSize,
                  let metadata = crypto.parseNonce(envelope),
                  metadata.direction == udpReceiveDirection else {
                dropped += 1
                return nil
            }

            if let last = lastUDPCounter, metadata.counter <= last {
                dropped += 1
                return nil
            }

            guard let packet = try? crypto.openPacket(
                envelope,
                using: receiveKey,
                direction: udpReceiveDirection,
                counter: metadata.counter
            ) else {
                dropped += 1
                return nil
            }

            if let last = lastUDPCounter, metadata.counter > last + 1 {
                dropped += metadata.counter - last - 1
            }
            lastUDPCounter = metadata.counter
            received += 1
            return packet
        }
    }

    // MARK: TCP

    public func sealTCP(_ payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let counter = tcpSendCounter
        guard let encrypted = try? crypto.sealTCPPayload(
            payload,
            using: sendKey,
            direction: tcpSendDirection,
            counter: counter
        ) else {
            return nil
        }
        tcpSendCounter += 1
        return encrypted
    }

    public func openTCP(_ payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let counter = tcpReceiveCounter
        guard let plaintext = try? crypto.openTCPPayload(
            payload,
            using: receiveKey,
            direction: tcpReceiveDirection,
            counter: counter
        ) else {
            dropped += 1
            return nil
        }
        tcpReceiveCounter += 1
        received += 1
        return plaintext
    }

    public func stats() -> SessionStats {
        lock.lock()
        defer { lock.unlock() }
        return SessionStats(received: received, dropped: dropped, lastUDPCounter: lastUDPCounter)
    }
}
