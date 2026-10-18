import Foundation
import Network
import os
import VPadProtocol

/// Encrypted UDP input listener. The receive loop runs on the dedicated
/// user-interactive queue; a session is armed only after the TCP handshake.
final class UDPServer: @unchecked Sendable {
    static let shared = UDPServer()

    private let queue = DispatchQueue(label: "com.vpad.network", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let log = Logger(subsystem: "com.vpad.MacHost", category: "udp")
    private let sessionLock = NSLock()

    private var listener: NWListener?
    private var isStarted = false
    private var session: SessionCrypto?
    private var activeToken: UUID?
    private var connections: [NWConnection] = []
    private var statsTimer: DispatchSourceTimer?
    private let maxConnections = 8

    private init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    /// Synchronous so application termination releases held keys/buttons before
    /// the process exits.
    func stop() {
        sessionLock.lock()
        session = nil
        activeToken = nil
        sessionLock.unlock()

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    private func stopLocked() {
        isStarted = false
        statsTimer?.cancel()
        statsTimer = nil
        listener?.cancel()
        listener = nil
        cancelAllConnections()
        EventInjector.shared.releaseAll()
        Task { @MainActor in HostStatus.shared.isUDPListening = false }
    }

    // MARK: - Session

    /// Synchronous so READY can be sent after the session is already usable.
    func arm(token: UUID, session: SessionCrypto) {
        sessionLock.lock()
        self.session = session
        self.activeToken = token
        sessionLock.unlock()
    }

    func endSession(token: UUID) {
        sessionLock.lock()
        guard activeToken == token else {
            sessionLock.unlock()
            return
        }
        session = nil
        activeToken = nil
        sessionLock.unlock()

        queue.async { [weak self] in
            EventInjector.shared.releaseAll()
            self?.cancelAllConnections()
        }
    }

    // MARK: - Listener

    private func startLocked() {
        guard !isStarted else { return }

        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo

        guard let port = NWEndpoint.Port(rawValue: VPadConstants.udpPort) else { return }
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(type: VPadConstants.udpService)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log.info("UDP listener ready on \(VPadConstants.udpPort, privacy: .public)")
                    Task { @MainActor in HostStatus.shared.isUDPListening = true }
                case .failed(let error):
                    let message = "UDP listener: \(error.localizedDescription)"
                    self.log.error("\(message, privacy: .public)")
                    Task { @MainActor in
                        HostStatus.shared.isUDPListening = false
                        HostStatus.shared.recordError(message)
                    }
                case .cancelled:
                    Task { @MainActor in HostStatus.shared.isUDPListening = false }
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
            startStatsTimer()
        } catch {
            let message = "UDP listener failed: \(error.localizedDescription)"
            log.error("\(message, privacy: .public)")
            Task { @MainActor in
                HostStatus.shared.isUDPListening = false
                HostStatus.shared.recordError(message)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        if connections.count >= maxConnections {
            let oldest = connections.removeFirst()
            oldest.cancel()
        }
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                self.handleDatagram(data)
            }
            if let error {
                self.log.debug("UDP receive ended: \(error.localizedDescription, privacy: .public)")
                self.removeConnection(connection)
                return
            }
            self.receiveNext(on: connection)
        }
    }

    private func handleDatagram(_ data: Data) {
        sessionLock.lock()
        let currentSession = session
        sessionLock.unlock()

        guard let currentSession else { return }
        guard data.count == VPadConstants.udpEnvelopeSize,
              let packet = currentSession.openUDP(data) else {
            return
        }
        EventInjector.shared.inject(packet)
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connection.cancel()
    }

    private func cancelAllConnections() {
        let current = connections
        connections.removeAll()
        for connection in current {
            connection.cancel()
        }
    }

    // MARK: - Statistics

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.pushStats()
        }
        timer.resume()
        statsTimer = timer
    }

    private func pushStats() {
        sessionLock.lock()
        let currentSession = session
        sessionLock.unlock()
        guard let currentSession else { return }
        let stats = currentSession.stats()
        Task { @MainActor in
            HostStatus.shared.update(stats: stats)
        }
    }
}
