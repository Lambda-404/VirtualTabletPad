import Foundation
import Network
import os
import VPadProtocol

/// Bonjour-discovered encrypted UDP sender. Packets are dropped until the TCP
/// handshake installs a client-role `SessionCrypto`.
final class UDPClient: @unchecked Sendable {
    static let shared = UDPClient()

    private let queue = DispatchQueue(label: "com.vpad.client.udp", qos: .userInteractive)
    private let log = Logger(subsystem: "com.vpad.iPadClient", category: "udp")
    private let sessionLock = NSLock()

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var isStarted = false
    private var transportMode: TransportMode = .automatic
    private var manualHost = ""
    private var browserGeneration = 0
    private var session: SessionCrypto?
    private var usbSender: (@Sendable (VPadPacket) -> Void)?
    private var pendingSends = 0
    private let resendEngine = StateResendEngine()
    private var resendTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?

    // Peripheral state tracking for reconciliation (§3.2)
    private var isPenDown = false
    private var isStylusInProximity = false
    private var buttonMask: UInt8 = 0
    private var lastX: Float32 = 0
    private var lastY: Float32 = 0
    private var lastPressure: Float32 = 0

    var onPongReceived: ((_ clientTimestamp: UInt64, _ hostTimestamp: UInt64, _ pingId: UInt16) -> Void)?

    private init() {}

    // MARK: - Lifecycle

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

    func stop() {
        sessionLock.lock()
        session = nil
        usbSender = nil
        pendingSends = 0
        resetClientStateLocked()
        sessionLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.browserGeneration += 1
            self.resendTimer?.cancel()
            self.resendTimer = nil
            self.resendEngine.reset()
            self.stopHeartbeatTimer()
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func setSession(_ session: SessionCrypto?) {
        sessionLock.lock()
        self.session = session
        let hasSession = session != nil
        sessionLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            if hasSession {
                self.startHeartbeatTimer()
            } else {
                self.stopHeartbeatTimer()
            }
        }
    }

    /// When the session runs over the USB cable, input packets bypass UDP and
    /// are carried by the TCP control tunnel instead.
    func setUSBSender(_ sender: (@Sendable (VPadPacket) -> Void)?) {
        sessionLock.lock()
        usbSender = sender
        let hasSender = sender != nil
        sessionLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            if hasSender {
                self.startHeartbeatTimer()
            } else if self.session == nil {
                self.stopHeartbeatTimer()
            }
        }
    }

    // MARK: - Sending

    func send(_ packet: VPadPacket) {
        sessionLock.lock()
        updateClientStateLocked(for: packet)
        if let usbSender {
            sessionLock.unlock()
            usbSender(packet)
            return
        }
        guard let session else {
            sessionLock.unlock()
            return
        }
        guard pendingSends < Self.pendingLimit(for: packet) else {
            sessionLock.unlock()
            return
        }
        pendingSends += 1
        sessionLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connection else {
                self.finishSend()
                return
            }
            guard let (envelope, seq) = session.sealUDPWithSeq(packet) else {
                self.finishSend()
                return
            }
            if packet.isStateEvent {
                self.resendEngine.onPacketSent(packet, seq: seq)
                self.ensureResendTimerRunning()
            }
            connection.send(content: envelope, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.log.debug("UDP send failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.finishSend()
            })
        }
    }

    /// Sends a diagnostic ping packet carrying a high-resolution timestamp (§3.5).
    @discardableResult
    func sendPing(id: UInt16 = 0) -> UInt64? {
        let ts = mach_absolute_time()
        let packet = VPadPacket.ping(timestamp: ts, id: id)
        send(packet)
        return ts
    }

    /// High-rate stylus/trackpad packets stay capped at two in flight. Keyboard,
    /// shortcut and system events are low-rate but must not be silently dropped
    /// behind a busy drawing stream, so they get a small independent budget.
    private static func pendingLimit(for packet: VPadPacket) -> Int {
        guard let type = EventType(rawValue: packet.type) else { return 2 }
        switch type {
        case .keyboardPress, .keyShortcut, .customGesture, .systemAction:
            return 8
        default:
            return 2
        }
    }

    private func finishSend() {
        sessionLock.lock()
        if pendingSends > 0 {
            pendingSends -= 1
        }
        sessionLock.unlock()
    }

    // MARK: - Browser / connection

    private func startLocked() {
        guard !isStarted else { return }
        isStarted = true
        if transportMode == .automatic {
            startBrowserLocked()
        } else {
            connectDirectLocked()
        }
    }

    private func makeUDPParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    private func connectDirectLocked() {
        guard isStarted else { return }
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            log.error("UDP direct mode has no host")
            return
        }
        browser?.cancel()
        browser = nil
        guard let port = NWEndpoint.Port(rawValue: VPadConstants.udpPort) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        connectLocked(to: endpoint, parameters: makeUDPParameters())
    }

    private func startBrowserLocked() {
        guard isStarted, transportMode == .automatic, browser == nil else { return }
        browserGeneration += 1
        let generation = browserGeneration

        let parameters = makeUDPParameters()
        let browser = NWBrowser(
            for: .bonjour(type: VPadConstants.udpService, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.log.error("UDP browser failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleBrowserRestart(generation: generation)
            case .cancelled:
                break
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self,
                  generation == self.browserGeneration,
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
            self.browser?.cancel()
            self.browser = nil
            self.startBrowserLocked()
        }
    }

    private func connectLocked(to endpoint: NWEndpoint, parameters: NWParameters) {
        guard isStarted else { return }
        if let connection {
            switch connection.state {
            case .ready, .preparing, .setup:
                return
            default:
                connection.cancel()
                self.connection = nil
            }
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.log.info("UDP ready to \(String(describing: endpoint), privacy: .public)")
                self.receiveNext(on: connection)
            case .failed(let error):
                self.log.error("UDP connection failed: \(error.localizedDescription, privacy: .public)")
                self.connection = nil
                connection.cancel()
                self.scheduleReconnect()
            case .cancelled:
                self.connection = nil
                self.scheduleReconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func scheduleReconnect() {
        guard isStarted else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isStarted, self.connection == nil else { return }
            self.browser?.cancel()
            self.browser = nil
            if self.transportMode == .automatic {
                self.startBrowserLocked()
            } else {
                self.connectDirectLocked()
            }
        }
    }

    // MARK: - Reliable State Resends & ACKs (§3.1)

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === connection else { return }
            if let data {
                self.sessionLock.lock()
                let currentSession = self.session
                self.sessionLock.unlock()

                if let currentSession, let packet = currentSession.openUDP(data) {
                    if packet.type == EventType.hostAck.rawValue, let ackSeq = packet.ackSequenceNumber {
                        self.resendEngine.onAckReceived(ackSeq)
                    } else if packet.type == EventType.pong.rawValue, let clientTs = packet.pingTimestamp {
                        let hostTs = packet.pongHostTimestamp ?? 0
                        let pingId = packet.pingId
                        self.onPongReceived?(clientTs, hostTs, pingId)
                    }
                }
            }
            if error == nil {
                self.receiveNext(on: connection)
            }
        }
    }

    private func ensureResendTimerRunning() {
        guard resendTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.015, repeating: 0.015)
        timer.setEventHandler { [weak self] in
            self?.checkPendingResends()
        }
        timer.resume()
        resendTimer = timer
    }

    private func checkPendingResends() {
        guard let connection else { return }
        sessionLock.lock()
        let currentSession = session
        sessionLock.unlock()
        guard let currentSession else { return }

        if let resend = resendEngine.nextResendPacket() {
            if let (envelope, _) = currentSession.sealUDPWithSeq(resend) {
                connection.send(content: envelope, completion: .idempotent)
            }
        }
        if resendEngine.pendingCount == 0 {
            resendTimer?.cancel()
            resendTimer = nil
        }
    }

    // MARK: - Heartbeat & State Tracking (§3.2)

    private func updateClientStateLocked(for packet: VPadPacket) {
        guard let type = EventType(rawValue: packet.type) else { return }
        switch type {
        case .stylusStroke:
            lastX = packet.x
            lastY = packet.y
            lastPressure = packet.pressure
            isStylusInProximity = true
            if packet.phase == Phase.began.rawValue || packet.phase == Phase.moved.rawValue {
                isPenDown = true
            } else if packet.phase == Phase.ended.rawValue || packet.phase == Phase.cancelled.rawValue {
                isPenDown = false
                lastPressure = 0
            }
        case .stylusHover:
            lastX = packet.x
            lastY = packet.y
            isStylusInProximity = true
            isPenDown = false
        case .stylusProximity:
            if packet.phase == Phase.began.rawValue {
                isStylusInProximity = true
            } else {
                isStylusInProximity = false
                isPenDown = false
            }
        case .trackpadClick:
            let isRight = packet.pressure >= 1.5
            let mask = isRight ? HeartbeatButtonMask.rightButton : HeartbeatButtonMask.leftButton
            if packet.phase == Phase.began.rawValue {
                buttonMask |= mask
            } else {
                buttonMask &= ~mask
            }
        default:
            break
        }
    }

    private func resetClientStateLocked() {
        isPenDown = false
        isStylusInProximity = false
        buttonMask = 0
        lastPressure = 0
    }

    private func startHeartbeatTimer() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func sendHeartbeat() {
        sessionLock.lock()
        let sender = usbSender
        let currentSession = session
        let packet = VPadPacket.heartbeat(
            penDown: isPenDown,
            inProximity: isStylusInProximity,
            buttonMask: buttonMask,
            modifiers: ModifierState.shared.snapshot(),
            x: lastX,
            y: lastY,
            pressure: lastPressure
        )
        sessionLock.unlock()

        if let sender {
            sender(packet)
            return
        }

        guard let currentSession, let connection else { return }
        guard let (envelope, _) = currentSession.sealUDPWithSeq(packet) else { return }
        connection.send(content: envelope, completion: .idempotent)
    }
}
