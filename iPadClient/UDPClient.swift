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
        sessionLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.browserGeneration += 1
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func setSession(_ session: SessionCrypto?) {
        sessionLock.lock()
        self.session = session
        sessionLock.unlock()
    }

    /// When the session runs over the USB cable, input packets bypass UDP and
    /// are carried by the TCP control tunnel instead.
    func setUSBSender(_ sender: (@Sendable (VPadPacket) -> Void)?) {
        sessionLock.lock()
        usbSender = sender
        sessionLock.unlock()
    }

    // MARK: - Sending

    func send(_ packet: VPadPacket) {
        sessionLock.lock()
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
            guard let envelope = session.sealUDP(packet) else {
                self.finishSend()
                return
            }
            connection.send(content: envelope, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.log.debug("UDP send failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.finishSend()
            })
        }
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
}
