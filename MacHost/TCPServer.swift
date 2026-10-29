import AppKit
import Foundation
import Network
import os
import VPadProtocol

// MARK: - Control connection

private enum TCPConnectionState: Equatable {
    case awaitingHello
    case ready
    case closing
    case closed
}

private final class TCPControlConnection: @unchecked Sendable {
    private let server: TCPServer
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token = UUID()
    private let log = Logger(subsystem: "com.vpad.MacHost", category: "tcp")

    private let privateKey = CryptoManager.shared.generateKeyPair()
    private var session: SessionCrypto?
    private var decoder = VPadFrameDecoder()
    private var fileReceiver: FileReceiver
    private var state: TCPConnectionState = .awaitingHello
    private var handshakeWorkItem: DispatchWorkItem?
    private var lastSendError: String?
    private var inputPacketCount = 0

    init(server: TCPServer, connection: NWConnection, queue: DispatchQueue) {
        self.server = server
        self.connection = connection
        self.queue = queue
        self.fileReceiver = FileReceiver(confirmationHandler: { fileName, fileSize in
            #if DEBUG
            if ProcessInfo.processInfo.environment["VPAD_AUTO_ACCEPT_FILES"] == "1" ||
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return true
            }
            #endif
            return DispatchQueue.main.sync {
                let alert = NSAlert()
                alert.messageText = "Accept Incoming File?"
                let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                alert.informativeText = "The connected iPad wants to send “\(fileName)” (\(formattedSize)). Do you want to receive it?"
                alert.addButton(withTitle: "Accept")
                alert.addButton(withTitle: "Decline")
                alert.alertStyle = .informational
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            }
        })
    }

    private var peerDescription: String {
        String(describing: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.cleanup(reason: "connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.cleanup(reason: "connection cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()

        let workItem = DispatchWorkItem { [weak self] in
            self?.handshakeTimedOut()
        }
        handshakeWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 5, execute: workItem)
        log.info("accepted control connection from \(self.peerDescription, privacy: .public)")
        Task { @MainActor in
            HostStatus.shared.setConnectionState(.connecting)
        }
    }

    func cancel() {
        cleanup(reason: "cancelled")
    }

    // MARK: Receive

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let payloads = try self.decoder.append(data)
                    for payload in payloads {
                        self.handlePayload(payload)
                        if self.state == .closed || self.state == .closing {
                            return
                        }
                    }
                } catch {
                    self.failProtocol(.malformedFrame)
                    return
                }
            }
            if let error {
                self.cleanup(reason: "receive failed: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.cleanup(reason: "peer closed")
                return
            }
            self.receiveNext()
        }
    }

    private func handlePayload(_ payload: Data) {
        switch state {
        case .awaitingHello:
            do {
                let frame = try VPadFrameCodec.parse(payload: payload)
                guard frame.type == .hello else {
                    failProtocol(.malformedFrame)
                    return
                }
                handleHello(frame)
            } catch {
                failProtocol(.malformedFrame)
            }
        case .ready:
            guard let session,
                  let plaintext = session.openTCP(payload) else {
                failProtocol(.malformedFrame)
                return
            }
            do {
                let frame = try VPadFrameCodec.parse(payload: plaintext)
                handleReady(frame)
            } catch {
                failProtocol(.malformedFrame)
            }
        case .closing, .closed:
            break
        }
    }

    // MARK: Handshake

    private func handleHello(_ frame: VPadFrame) {
        Task { @MainActor in
            HostStatus.shared.setConnectionState(.handshaking)
        }
        guard let version = frame.body.first else {
            failProtocol(.malformedFrame)
            return
        }

        if version == VPadConstants.protocolVersionV2 {
            handleHelloV2(frame)
            return
        }

        #if DEBUG
        if version == VPadConstants.protocolVersion {
            handleHelloV1(frame)
            return
        }
        #endif

        log.error("protocol version mismatch: client \(version, privacy: .public)")
        failProtocol(.unsupportedVersion)
    }

    private func handleHelloV2(_ frame: VPadFrame) {
        let clientPayload: ClientHelloPayload
        do {
            clientPayload = try ClientHelloPayload.decode(frame.body)
        } catch {
            log.error("failed to decode client hello v2: \(error.localizedDescription, privacy: .public)")
            failProtocol(.malformedFrame)
            return
        }

        let clientIdentity = clientPayload.identityPublicKey
        let isAllowed = PersistentDeviceAllowlistStore.shared.isAllowed(identity: clientIdentity)

        if !isAllowed {
            guard let token = clientPayload.pairingToken,
                  PairingTokenManager.shared.validateAndConsume(token: token) else {
                log.error("client \(self.peerDescription, privacy: .public) is not paired and pairing token is missing or invalid")
                failProtocol(.unsupportedVersion)
                return
            }
            let deviceName = clientPayload.deviceName ?? "iPad"
            let newDevice = PairedDevice(name: deviceName, identityPublicKey: clientIdentity)
            PersistentDeviceAllowlistStore.shared.allow(device: newDevice)
            Task { @MainActor in
                HostStatus.shared.refreshPairedDevices()
            }
            log.info("approved and paired new device: \(deviceName, privacy: .public)")
        }

        let hostIdentity = HostIdentity.current()
        let sessionID = UInt32.random(in: 1...UInt32.max)

        do {
            let (ackPayload, handshakeSession) = try VPadHandshake.respondServer(
                clientPayload: clientPayload,
                serverIdentity: hostIdentity,
                allowedClientIdentities: nil,
                sessionID: sessionID
            )

            let newSession = SessionCrypto(session: handshakeSession, role: .host)
            session = newSession
            state = .ready
            handshakeWorkItem?.cancel()
            handshakeWorkItem = nil

            // Arm UDP before READY so the first encrypted datagram cannot race us.
            UDPServer.shared.arm(token: token, session: newSession)
            let peer = clientPayload.deviceName ?? peerDescription
            Task {
                await SessionState.shared.arm(token: token, session: newSession, peer: peer)
            }

            sendPlaintext(.helloAck, body: ackPayload.encode())
            sendPlaintext(.ready)

            Task { @MainActor in
                HostStatus.shared.markConnected(peer: peer)
            }
            log.info("v2 session ready with \(peer, privacy: .public) (sessionID: \(sessionID))")
        } catch {
            log.error("v2 handshake failed: \(error.localizedDescription, privacy: .public)")
            failProtocol(.malformedFrame)
        }
    }

    #if DEBUG
    private func handleHelloV1(_ frame: VPadFrame) {
        guard frame.body.count == 1 + VPadConstants.publicKeySize else {
            failProtocol(.malformedFrame)
            return
        }

        let remotePublicKey = Data(frame.body.dropFirst())
        do {
            let key = try CryptoManager.shared.deriveSessionKey(
                privateKey: privateKey,
                remotePublicKeyData: remotePublicKey
            )
            let newSession = SessionCrypto(key: key)
            session = newSession
            state = .ready
            handshakeWorkItem?.cancel()
            handshakeWorkItem = nil

            // Arm UDP before READY so the first encrypted datagram cannot race us.
            UDPServer.shared.arm(token: token, session: newSession)
            let peer = peerDescription
            Task {
                await SessionState.shared.arm(token: token, session: newSession, peer: peer)
            }

            var ackBody = Data([VPadConstants.protocolVersion])
            ackBody.append(CryptoManager.shared.publicKeyData(for: privateKey))
            sendPlaintext(.helloAck, body: ackBody)
            sendPlaintext(.ready)

            Task { @MainActor in
                HostStatus.shared.markConnected(peer: peer)
            }
            log.info("v1 debug session ready with \(peer, privacy: .public)")
        } catch {
            log.error("v1 key agreement failed")
            failProtocol(.malformedFrame)
        }
    }
    #endif

    private func handshakeTimedOut() {
        guard state == .awaitingHello else { return }
        log.error("handshake timed out")
        cleanup(reason: "handshake timeout")
    }

    // MARK: Ready frames

    private func handleReady(_ frame: VPadFrame) {
        switch frame.type {
        case .ping:
            guard frame.body.count == 8 else {
                failProtocol(.malformedFrame)
                return
            }
            sendEncrypted(.pong, body: frame.body)
            sendStats()
        case .pong:
            break
        case .stats:
            break
        case .inputPacket:
            guard let packet = VPadPacket.fromData(frame.body) else {
                failProtocol(.malformedFrame)
                return
            }
            inputPacketCount += 1
            EventInjector.shared.inject(packet)
        case .error:
            log.error("client reported error \(frame.body.first ?? 0, privacy: .public)")
            cleanup(reason: "client error")
        case .fileHeader, .fileChunk, .fileTrailer, .fileAbort:
            switch fileReceiver.handle(frame) {
            case .none:
                break
            case .status(let status, let fileName):
                sendEncrypted(.fileStatus, body: FileStatusPayload(status: status).encoded())
                if let fileName {
                    Task { @MainActor in
                        HostStatus.shared.recordUpload(name: fileName, status: status)
                    }
                }
            case .protocolError(let code):
                failProtocol(code)
            }
        case .hello, .helloAck, .ready, .fileStatus:
            failProtocol(.malformedFrame)
        }
    }

    private func sendStats() {
        guard let session else { return }
        let stats = session.stats()
        var body = Data(capacity: 16)
        body.append(be64(stats.dropped))
        body.append(be64(stats.lastUDPCounter ?? 0))
        sendEncrypted(.stats, body: body)
    }

    // MARK: Sending

    private func sendPlaintext(_ type: FrameType, body: Data = Data()) {
        send(VPadFrameCodec.encode(type: type, body: body))
    }

    private func sendEncrypted(_ type: FrameType, body: Data = Data()) {
        guard let session else { return }
        var payload = Data(capacity: 1 + body.count)
        payload.append(type.rawValue)
        payload.append(body)
        guard let encrypted = session.sealTCP(payload) else {
            log.error("failed to encrypt outbound frame \(type.rawValue, privacy: .public)")
            return
        }
        send(VPadFrameCodec.wrap(payload: encrypted))
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.lastSendError = error.localizedDescription
            self.cleanup(reason: "send failed: \(error.localizedDescription)")
        })
    }

    private func be64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    // MARK: Errors / cleanup

    private func failProtocol(_ code: ProtocolErrorCode) {
        guard state != .closed, state != .closing else { return }
        let wasReady = state == .ready
        state = .closing

        let body = Data([code.rawValue])
        let data: Data
        if wasReady, let session {
            var payload = Data([FrameType.error.rawValue])
            payload.append(body)
            guard let encrypted = session.sealTCP(payload) else {
                cleanup(reason: "protocol error \(code.rawValue) (encryption failed)")
                return
            }
            data = VPadFrameCodec.wrap(payload: encrypted)
        } else {
            data = VPadFrameCodec.encode(type: .error, body: body)
        }

        log.error("closing connection for protocol error \(code.rawValue, privacy: .public)")
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.cleanup(reason: "protocol error \(code.rawValue)")
        })
    }

    private func cleanup(reason: String) {
        guard state != .closed else { return }
        let wasCurrent = server.isCurrent(self)
        state = .closed
        handshakeWorkItem?.cancel()
        handshakeWorkItem = nil
        fileReceiver.abort()
        connection.cancel()
        server.clearActive(self)

        if wasCurrent {
            EventInjector.shared.releaseAll()
            UDPServer.shared.endSession(token: token)
            Task { await SessionState.shared.disarm(token: token) }
            Task { @MainActor in HostStatus.shared.markDisconnected() }
        }
        if let lastSendError {
            log.error("control session ended: \(reason, privacy: .public) (last send error: \(lastSendError, privacy: .public))")
        } else {
            log.info("control session ended: \(reason, privacy: .public)")
        }
        session = nil
    }
}

// MARK: - Listener

final class TCPServer: @unchecked Sendable {
    static let shared = TCPServer()

    private let queue = DispatchQueue(label: "com.vpad.tcp", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let log = Logger(subsystem: "com.vpad.MacHost", category: "tcp")
    private var listener: NWListener?
    private var isStarted = false
    fileprivate var activeConnection: TCPControlConnection?

    private init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    /// Synchronous so application termination flushes file cleanup and input
    /// release before the process exits.
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    fileprivate func isCurrent(_ connection: TCPControlConnection) -> Bool {
        activeConnection === connection
    }

    fileprivate func clearActive(_ connection: TCPControlConnection) {
        if activeConnection === connection {
            activeConnection = nil
        }
    }

    private func startLocked() {
        guard !isStarted else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        guard let port = NWEndpoint.Port(rawValue: VPadConstants.tcpPort) else { return }
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(type: VPadConstants.tcpService)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log.info("TCP listener ready on \(VPadConstants.tcpPort, privacy: .public)")
                    Task { @MainActor in HostStatus.shared.isTCPListening = true }
                case .failed(let error):
                    let message = "TCP listener: \(error.localizedDescription)"
                    self.log.error("\(message, privacy: .public)")
                    Task { @MainActor in
                        HostStatus.shared.isTCPListening = false
                        HostStatus.shared.recordError(message)
                    }
                case .cancelled:
                    Task { @MainActor in HostStatus.shared.isTCPListening = false }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            isStarted = true
        } catch {
            let message = "TCP listener failed: \(error.localizedDescription)"
            log.error("\(message, privacy: .public)")
            Task { @MainActor in
                HostStatus.shared.isTCPListening = false
                HostStatus.shared.recordError(message)
            }
        }
    }

    private func stopLocked() {
        guard isStarted else { return }
        isStarted = false
        listener?.cancel()
        listener = nil
        let active = activeConnection
        activeConnection = nil
        active?.cancel()
        Task { @MainActor in HostStatus.shared.isTCPListening = false }
    }

    private func accept(_ connection: NWConnection) {
        // The Mac has exactly one active tablet. A second client (for example a
        // simulator left running next to the physical iPad) must not evict the
        // active session — otherwise both clients reconnect every few seconds and
        // the user sees the connection "drop" whenever the other client retries.
        if activeConnection != nil {
            log.notice("rejecting additional control client; an iPad is already active")
            connection.cancel()
            return
        }
        let newConnection = TCPControlConnection(
            server: self,
            connection: connection,
            queue: queue
        )
        activeConnection = newConnection
        newConnection.start()
    }
}
