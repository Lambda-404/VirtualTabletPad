import CryptoKit
import Foundation
import Network
import os
import UIKit
import VPadProtocol

/// Client half of the TCP control channel: discovery, ECDH handshake, PING/PONG,
/// and chunked file uploads. All frames share one persistent connection.
final class TCPFileClient: @unchecked Sendable {
    static let shared = TCPFileClient()

    enum Event: Sendable {
        case connecting
        case connected(peer: String)
        case remoteAddress(String)
        case disconnected(reason: String)
        case latency(milliseconds: Double)
        case stats(dropped: UInt64, lastNonce: UInt64)
        case fileProgress(name: String, progress: Double)
        case fileStatus(name: String, status: FileStatus)
        case error(String)
    }

    private enum State: Equatable {
        case idle
        case browsing
        case handshaking
        case ready
        case closed
    }

    private let queue = DispatchQueue(label: "com.vpad.client.tcp", qos: .utility)
    private let fileQueue = DispatchQueue(label: "com.vpad.client.file", qos: .utility)
    private let log = Logger(subsystem: "com.vpad.iPadClient", category: "tcp")
    private let eventLock = NSLock()
    private let uploadLock = NSLock()

    private var eventHandler: (@Sendable (Event) -> Void)?

    private var browser: NWBrowser?
    private var usbListener: NWListener?
    private var connection: NWConnection?
    private var decoder = VPadFrameDecoder()
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var handshakeState: ClientHandshakeState?
    private var session: SessionCrypto?
    private var state: State = .idle
    private var transportMode: TransportMode = .automatic
    private var manualHost = ""
    private var isStarted = false
    private var browserGeneration = 0
    private var peerDescription: String?
    private var handshakeWorkItem: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var lastPingTimestamp: UInt64?
    private var lastPingDate: Date?

    private var uploadName: String?
    private var uploadStatus: FileStatus?
    private var uploadSemaphore: DispatchSemaphore?

    private init() {}

    // MARK: - Public API

    func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        eventLock.lock()
        eventHandler = handler
        eventLock.unlock()
    }

    func start() {
        start(mode: .automatic, host: "")
    }

    func start(mode: TransportMode, host: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.transportMode = mode
            self.manualHost = host
            self.startLocked()
        }
    }

    /// Raw USB-C mode: usbmuxd on the Mac connects to this listener on port 8890.
    func startUSB() {
        queue.async { [weak self] in
            guard let self else { return }
            self.transportMode = .usb
            self.manualHost = ""
            self.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.usbListener?.cancel()
            self.usbListener = nil
            self.closeLocked(reason: "stopped", reconnect: false)
        }
    }

    func uploadFile(at url: URL) {
        queue.async { [weak self] in
            guard let self, self.state == .ready else {
                self?.emit(.error("Cannot upload: Mac is not connected"))
                return
            }
            guard self.beginUpload() else {
                self.emit(.error("Another file upload is already running"))
                return
            }
            self.fileQueue.async { [weak self] in
                self?.performUpload(url)
            }
        }
    }

    // MARK: - Discovery

    private func startLocked() {
        guard !isStarted else { return }
        isStarted = true
        state = .browsing
        emit(.connecting)
        switch transportMode {
        case .automatic:
            startBrowserLocked()
        case .usb:
            startUSBListenerLocked()
        case .direct:
            connectManualLocked()
        }
    }

    private func makeTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func connectManualLocked() {
        guard isStarted else { return }
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            emit(.error("Enter the Mac IP for cable/direct mode"))
            return
        }
        browser?.cancel()
        browser = nil
        guard let port = NWEndpoint.Port(rawValue: VPadConstants.tcpPort) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        connectLocked(to: endpoint, parameters: makeTCPParameters())
    }

    private func startUSBListenerLocked() {
        guard isStarted, transportMode == .usb, usbListener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: 8890) else { return }
        do {
            let parameters = makeTCPParameters()
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.queue.async { [weak self] in
                    self?.adoptUSBConnectionLocked(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.log.error("USB listener failed: \(error.localizedDescription, privacy: .public)")
                    self?.scheduleUSBListenerRestart()
                }
            }
            listener.start(queue: queue)
            usbListener = listener
            log.info("USB listener ready on loopback tcp/8890")
        } catch {
            emit(.error("USB listener failed: \(error.localizedDescription)"))
            scheduleUSBListenerRestart()
        }
    }

    private func scheduleUSBListenerRestart() {
        guard isStarted, transportMode == .usb else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isStarted, self.transportMode == .usb,
                  self.usbListener == nil else { return }
            self.state = .browsing
            self.emit(.connecting)
            self.startUSBListenerLocked()
        }
    }

    private func adoptUSBConnectionLocked(_ accepted: NWConnection) {
        guard isStarted, transportMode == .usb else {
            accepted.cancel()
            return
        }
        usbListener?.cancel()
        usbListener = nil
        adoptConnectionLocked(accepted, description: "USB Cable")
    }

    private func startBrowserLocked() {
        guard isStarted, transportMode == .automatic else { return }
        browserGeneration += 1
        let generation = browserGeneration
        browser?.cancel()
        browser = nil

        let parameters = makeTCPParameters()
        let browser = NWBrowser(
            for: .bonjour(type: VPadConstants.tcpService, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.log.error("TCP browser failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleBrowserRestart(generation: generation)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self,
                  generation == self.browserGeneration,
                  self.state == .browsing,
                  let result = results.first else {
                return
            }
            self.connectLocked(to: result.endpoint, parameters: parameters)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func scheduleBrowserRestart(generation: Int) {
        guard isStarted, transportMode == .automatic else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isStarted, generation == self.browserGeneration,
                  self.transportMode == .automatic else { return }
            self.startBrowserLocked()
        }
    }

    private func connectLocked(to endpoint: NWEndpoint, parameters: NWParameters) {
        let connection = NWConnection(to: endpoint, using: parameters)
        adoptConnectionLocked(connection, description: Self.describe(endpoint))
    }

    private func adoptConnectionLocked(_ connection: NWConnection, description: String) {
        self.connection?.cancel()
        self.connection = nil
        decoder.reset()
        privateKey = CryptoManager.shared.generateKeyPair()
        handshakeState = nil
        session = nil
        uploadLock.lock()
        uploadStatus = nil
        uploadSemaphore?.signal()
        uploadSemaphore = nil
        uploadName = nil
        uploadLock.unlock()

        peerDescription = description
        state = .handshaking

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.sendHelloLocked()
            case .failed(let error):
                self.closeLocked(
                    reason: "connection failed: \(error.localizedDescription)",
                    reconnect: true
                )
            case .cancelled:
                self.closeLocked(reason: "connection cancelled", reconnect: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receiveNext()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.state == .handshaking else { return }
            self.closeLocked(reason: "handshake timeout", reconnect: true)
        }
        handshakeWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 5, execute: workItem)
        log.info("connecting to \(description, privacy: .public)")
    }

    // MARK: - Handshake

    private func currentDeviceName() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIDevice.current.name }
        } else {
            return DispatchQueue.main.sync { UIDevice.current.name }
        }
    }

    private func currentProfile() -> PairedProfile? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { PairingProfileStore.shared.profile }
        } else {
            return DispatchQueue.main.sync { PairingProfileStore.shared.profile }
        }
    }

    private func sendHelloLocked() {
        let clientIdentity = ClientIdentity.current()
        let profile = currentProfile()
        let pairingToken = profile?.pairingToken
        let deviceName = currentDeviceName()

        do {
            let (payload, state) = try VPadHandshake.initiateClient(
                clientIdentity: clientIdentity,
                pairingToken: pairingToken,
                deviceName: deviceName
            )
            self.handshakeState = state
            sendFrame(type: .hello, body: payload.encode(), encrypted: false)
            log.info("sent v2 HELLO (hasToken: \(pairingToken != nil, privacy: .public))")
        } catch {
            log.error("failed to initiate client handshake: \(error.localizedDescription, privacy: .public)")
            closeLocked(reason: "handshake initiation failed", reconnect: true)
        }
    }

    func sendInputOverUSB(_ packet: VPadPacket) {
        queue.async { [weak self] in
            guard let self, self.state == .ready else { return }
            self.sendFrame(type: .inputPacket, body: packet.toData(), encrypted: true)
        }
    }

    private func handleHandshakePayload(_ payload: Data) {
        let frame: VPadFrame
        do {
            frame = try VPadFrameCodec.parse(payload: payload)
        } catch {
            closeLocked(reason: "invalid handshake frame", reconnect: true)
            return
        }

        switch frame.type {
        case .helloAck:
            handleHelloAck(frame)
        case .ready:
            guard let session else {
                closeLocked(reason: "READY before HELLO_ACK", reconnect: true)
                return
            }
            state = .ready
            handshakeWorkItem?.cancel()
            handshakeWorkItem = nil
            UDPClient.shared.setSession(session)
            let peer = peerDescription ?? "Mac"
            Task {
                await ClientSessionState.shared.arm(session: session, peer: peer)
            }
            emit(.connected(peer: peer))
            if transportMode == .usb {
                UDPClient.shared.setUSBSender { [weak self] packet in
                    self?.sendInputOverUSB(packet)
                }
            } else {
                UDPClient.shared.setUSBSender(nil)
            }
            if let endpoint = self.connection?.currentPath?.remoteEndpoint,
               case let .hostPort(host, _) = endpoint {
                emit(.remoteAddress("\(host)"))
            }
            startPingTimerLocked()
            log.info("session ready with \(peer, privacy: .public)")
        case .error:
            closeLocked(reason: "Mac rejected handshake", reconnect: true)
        default:
            closeLocked(reason: "unexpected handshake frame", reconnect: true)
        }
    }

    private func handleHelloAck(_ frame: VPadFrame) {
        if frame.body.first == VPadConstants.protocolVersionV2 {
            guard let handshakeState else {
                closeLocked(reason: "missing client handshake state", reconnect: true)
                return
            }
            do {
                let ackPayload = try ServerHelloAckPayload.decode(frame.body)
                let pinnedHostKey = currentProfile()?.hostIdentityPublicKey

                let handshakeSession = try VPadHandshake.completeClient(
                    state: handshakeState,
                    ackPayload: ackPayload,
                    pinnedServerIdentity: pinnedHostKey
                )

                DispatchQueue.main.async {
                    if var profile = PairingProfileStore.shared.profile {
                        if profile.hostIdentityPublicKey == nil {
                            profile.hostIdentityPublicKey = ackPayload.identityPublicKey
                        }
                        profile.pairingToken = nil
                        PairingProfileStore.shared.save(profile)
                    }
                }

                session = SessionCrypto(session: handshakeSession, role: .client)
                self.handshakeState = nil
                log.info("v2 handshake completed (sessionID: \(handshakeSession.sessionID))")
            } catch {
                log.error("v2 handshake failed: \(error.localizedDescription, privacy: .public)")
                closeLocked(reason: "handshake verification failed: \(error.localizedDescription)", reconnect: true)
            }
            return
        }

        #if DEBUG
        if frame.body.count == 1 + VPadConstants.publicKeySize,
           frame.body.first == VPadConstants.protocolVersion,
           let privateKey {
            do {
                let remoteKey = Data(frame.body.dropFirst())
                let key = try CryptoManager.shared.deriveSessionKey(
                    privateKey: privateKey,
                    remotePublicKeyData: remoteKey
                )
                session = SessionCrypto(key: key, role: .client)
                log.info("v1 debug handshake completed")
            } catch {
                closeLocked(reason: "key agreement failed", reconnect: true)
            }
            return
        }
        #endif

        closeLocked(reason: "unsupported HELLO_ACK version", reconnect: true)
    }

    // MARK: - Receive

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let payloads = try self.decoder.append(data)
                    for payload in payloads {
                        self.handlePayload(payload)
                        if self.state == .closed {
                            return
                        }
                    }
                } catch {
                    self.closeLocked(reason: "invalid frame", reconnect: true)
                    return
                }
            }
            if let error {
                self.closeLocked(reason: "receive failed: \(error.localizedDescription)", reconnect: true)
                return
            }
            if isComplete {
                self.closeLocked(reason: "Mac closed the connection", reconnect: true)
                return
            }
            self.receiveNext()
        }
    }

    private func handlePayload(_ payload: Data) {
        switch state {
        case .handshaking:
            handleHandshakePayload(payload)
        case .ready:
            guard let session, let plaintext = session.openTCP(payload) else {
                closeLocked(reason: "decryption failed", reconnect: true)
                return
            }
            do {
                let frame = try VPadFrameCodec.parse(payload: plaintext)
                handleReadyFrame(frame)
            } catch {
                closeLocked(reason: "malformed encrypted frame", reconnect: true)
            }
        case .idle, .browsing, .closed:
            break
        }
    }

    private func handleReadyFrame(_ frame: VPadFrame) {
        switch frame.type {
        case .pong:
            handlePong(frame.body)
        case .ping:
            sendFrame(type: .pong, body: frame.body, encrypted: true)
        case .stats:
            handleStats(frame.body)
        case .fileStatus:
            handleFileStatus(frame.body)
        case .error:
            emit(.error("Mac reported an error"))
        default:
            break
        }
    }

    // MARK: - PING

    private func startPingTimerLocked() {
        guard pingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.sendPingLocked()
        }
        timer.resume()
        pingTimer = timer
    }

    private func sendPingLocked() {
        guard state == .ready else { return }
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        lastPingTimestamp = timestamp
        lastPingDate = Date()
        sendFrame(type: .ping, body: be64(timestamp), encrypted: true)
    }

    private func handlePong(_ body: Data) {
        guard body.count == 8,
              let sentAt = lastPingDate,
              let expected = lastPingTimestamp else {
            return
        }
        let echoed = body.withUnsafeBytes { buffer in
            UInt64(bigEndian: buffer.loadUnaligned(as: UInt64.self))
        }
        guard echoed == expected else { return }

        let milliseconds = Date().timeIntervalSince(sentAt) * 1000
        lastPingTimestamp = nil
        lastPingDate = nil
        emit(.latency(milliseconds: milliseconds))
        Task {
            await ClientSessionState.shared.setRTT(milliseconds)
        }
    }

    private func handleStats(_ body: Data) {
        guard body.count == 16 else { return }
        let (dropped, lastNonce) = body.withUnsafeBytes { buffer -> (UInt64, UInt64) in
            let dropped = UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
            let last = UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            return (dropped, last)
        }
        emit(.stats(dropped: dropped, lastNonce: lastNonce))
    }

    // MARK: - Sending

    private func sendFrame(
        type: FrameType,
        body: Data = Data(),
        encrypted: Bool,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else {
                completion?(false)
                return
            }
            let payload: Data
            var frame = Data([type.rawValue])
            frame.append(body)
            payload = frame

            let wrapped: Data
            if encrypted {
                guard self.state == .ready, let session = self.session,
                      let encryptedPayload = session.sealTCP(payload) else {
                    completion?(false)
                    return
                }
                wrapped = VPadFrameCodec.wrap(payload: encryptedPayload)
            } else {
                wrapped = VPadFrameCodec.wrap(payload: payload)
            }

            connection.send(content: wrapped, completion: .contentProcessed { error in
                if let error {
                    self.log.debug("send failed: \(error.localizedDescription, privacy: .public)")
                }
                completion?(error == nil)
            })
        }
    }

    private func be64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    // MARK: - Files

    private func beginUpload() -> Bool {
        uploadLock.lock()
        defer { uploadLock.unlock() }
        guard uploadSemaphore == nil else { return false }
        uploadSemaphore = DispatchSemaphore(value: 0)
        uploadStatus = nil
        uploadName = nil
        return true
    }

    private func performUpload(_ url: URL) {
        let name = url.lastPathComponent
        uploadLock.lock()
        uploadName = name
        uploadLock.unlock()

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let size = UInt64(values.fileSize ?? 0)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw NSError(domain: "VPad", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open file"])
            }
            defer { try? handle.close() }

            guard let headerBody = FileHeaderPayload(fileName: name, fileSize: size).encoded() else {
                throw NSError(domain: "VPad", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid file name"])
            }

            let inFlight = DispatchSemaphore(value: 4)
            inFlight.wait()
            sendFileFrame(type: .fileHeader, body: headerBody) {
                inFlight.signal()
            }

            var hasher = SHA256()
            var sent: UInt64 = 0
            emit(.fileProgress(name: name, progress: 0))

            while true {
                let data = try handle.read(upToCount: VPadConstants.fileChunkSize) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
                guard let chunkBody = FileChunkPayload(data: data).encoded() else {
                    throw NSError(domain: "VPad", code: 3, userInfo: [NSLocalizedDescriptionKey: "Chunk too large"])
                }
                inFlight.wait()
                sendFileFrame(type: .fileChunk, body: chunkBody) {
                    inFlight.signal()
                }
                sent += UInt64(data.count)
                let progress = size == 0 ? 1 : Double(sent) / Double(size)
                emit(.fileProgress(name: name, progress: progress))
            }

            guard sent == size else {
                throw NSError(domain: "VPad", code: 4, userInfo: [NSLocalizedDescriptionKey: "File size changed while uploading"])
            }
            guard let trailerBody = FileTrailerPayload(sha256: Data(hasher.finalize())).encoded() else {
                throw NSError(domain: "VPad", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid trailer"])
            }
            inFlight.wait()
            sendFileFrame(type: .fileTrailer, body: trailerBody) {
                inFlight.signal()
            }

            uploadLock.lock()
            let semaphore = uploadSemaphore
            uploadLock.unlock()

            guard let semaphore else {
                emit(.error("Upload state was lost"))
                return
            }
            if semaphore.wait(timeout: .now() + 30) == .timedOut {
                uploadLock.lock()
                uploadSemaphore = nil
                uploadStatus = nil
                uploadName = nil
                uploadLock.unlock()
                emit(.error("Timed out waiting for the Mac to accept \(name)"))
                return
            }

            uploadLock.lock()
            let status = uploadStatus
            uploadSemaphore = nil
            uploadStatus = nil
            uploadName = nil
            uploadLock.unlock()

            if let status {
                emit(.fileStatus(name: name, status: status))
            } else {
                emit(.error("Missing FILE_STATUS for \(name)"))
            }
        } catch {
            uploadLock.lock()
            uploadSemaphore = nil
            uploadStatus = nil
            uploadName = nil
            uploadLock.unlock()
            emit(.error("Upload failed: \(error.localizedDescription)"))
        }
    }

    private func sendFileFrame(
        type: FrameType,
        body: Data,
        completion: @escaping @Sendable () -> Void
    ) {
        sendFrame(type: type, body: body, encrypted: true) { _ in
            completion()
        }
    }

    private func handleFileStatus(_ body: Data) {
        guard let payload = FileStatusPayload.decode(body) else { return }
        uploadLock.lock()
        let semaphore = uploadSemaphore
        if semaphore != nil {
            uploadStatus = payload.status
        }
        let name = uploadName
        uploadLock.unlock()
        semaphore?.signal()
        if let name {
            emit(.fileProgress(name: name, progress: 1))
        }
    }

    // MARK: - Cleanup

    private func closeLocked(reason: String, reconnect: Bool) {
        guard state != .closed else { return }
        let wasReady = state == .ready
        state = .closed
        handshakeWorkItem?.cancel()
        handshakeWorkItem = nil
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        decoder.reset()
        session = nil
        privateKey = nil
        lastPingTimestamp = nil
        lastPingDate = nil

        uploadLock.lock()
        uploadStatus = .cancelled
        uploadSemaphore?.signal()
        uploadSemaphore = nil
        uploadName = nil
        uploadLock.unlock()

        UDPClient.shared.setSession(nil)
        UDPClient.shared.setUSBSender(nil)
        Task {
            await ClientSessionState.shared.disarm()
        }
        if wasReady {
            emit(.disconnected(reason: reason))
        }
        log.info("TCP client closed: \(reason, privacy: .public)")

        guard reconnect, isStarted else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isStarted, self.state == .closed else { return }
            self.state = .browsing
            self.emit(.connecting)
            switch self.transportMode {
            case .automatic:
                self.startBrowserLocked()
            case .usb:
                self.startUSBListenerLocked()
            case .direct:
                self.connectManualLocked()
            }
        }
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint {
            return name
        }
        return String(describing: endpoint)
    }

    private func emit(_ event: Event) {
        eventLock.lock()
        let handler = eventHandler
        eventLock.unlock()
        handler?(event)
    }
}
