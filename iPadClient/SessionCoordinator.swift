import Combine
import Foundation
import VPadProtocol

enum TransportMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case usb
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic · Bonjour"
        case .usb: return "USB Cable"
        case .direct: return "Cable / Direct IP"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Discovers the Mac over Wi-Fi, AWDL or any shared network."
        case .usb:
            return "Raw USB-C tunnel through usbmuxd; no Wi-Fi, IP or network interface."
        case .direct:
            return "Auto-connects over a direct USB-C cable, or to a Mac IP over Ethernet/hotspot."
        }
    }
}

/// Main-actor UI state fed by the TCP client's background callbacks.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var connectionState: VPadConnectionState = .disconnected
    @Published private(set) var transportMode: TransportMode
    @Published private(set) var manualHost: String
    @Published private(set) var peerName: String?
    @Published private(set) var remoteHost: String?
    @Published private(set) var latencyMilliseconds: Double?
    @Published private(set) var droppedPackets: UInt64 = 0
    @Published private(set) var lastUDPNonce: UInt64?
    @Published private(set) var uploadName: String?
    @Published private(set) var uploadProgress: Double?
    @Published private(set) var lastFileStatus: FileStatus?
    @Published private(set) var lastError: String?
    @Published private(set) var activeAppBundleID: String?
    @Published private(set) var activeProfile: Profile = .default
    @Published var profileStore: ProfileStore = ProfileStore()

    private let defaults = UserDefaults.standard
    private var isStarted = false
    private var discoveryStarted = false
    private var directFallbackTask: Task<Void, Never>?
    #if DEBUG
    private var didAutoSmoke = false
    #endif

    init() {
        let defaults = UserDefaults.standard
        var mode = TransportMode(
            rawValue: defaults.string(forKey: "vpad.transportMode") ?? ""
        ) ?? .automatic
        var host = defaults.string(forKey: "vpad.manualHost") ?? ""
        #if DEBUG
        if ProcessInfo.processInfo.environment["VPAD_USB_MODE"] == "1" {
            mode = .usb
            host = ""
        }
        if let directHost = ProcessInfo.processInfo.environment["VPAD_DIRECT_HOST"],
           !directHost.isEmpty {
            mode = .direct
            host = directHost
        }
        #endif
        transportMode = mode
        manualHost = host

        TCPFileClient.shared.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    var isConnected: Bool {
        connectionState == .active
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionState = .connecting
        lastError = nil
        remoteHost = nil
        droppedPackets = 0
        lastUDPNonce = nil
        if transportMode == .usb {
            UDPClient.shared.stop()
            TCPFileClient.shared.startUSB()
        } else {
            TCPFileClient.shared.start(mode: transportMode, host: manualHost)
            UDPClient.shared.start(mode: transportMode, host: manualHost)
        }
        startCableDiscovery()
    }

    func applyConnection(mode: TransportMode, host: String, persist: Bool = true) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .direct, trimmed.isEmpty {
            lastError = "Enter the Mac IP address for cable/direct mode"
            return
        }
        transportMode = mode
        manualHost = trimmed
        if persist {
            defaults.set(mode.rawValue, forKey: "vpad.transportMode")
            defaults.set(trimmed, forKey: "vpad.manualHost")
        }

        guard isStarted else { return }
        connectionState = .connecting
        peerName = nil
        latencyMilliseconds = nil
        droppedPackets = 0
        lastUDPNonce = nil
        lastError = nil
        TCPFileClient.shared.stop()
        UDPClient.shared.stop()
        if mode == .usb {
            TCPFileClient.shared.startUSB()
        } else {
            TCPFileClient.shared.start(mode: mode, host: trimmed)
            UDPClient.shared.start(mode: mode, host: trimmed)
        }
    }

    private func startCableDiscovery() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        LinkDiscovery.shared.start { [weak self] host in
            Task { @MainActor [weak self] in
                self?.handleCableHost(host)
            }
        }
    }

    private func handleCableHost(_ host: String) {
        guard host.hasPrefix("169.254.") else { return }

        if transportMode == .usb {
            return
        }
        if transportMode == .direct {
            if manualHost.isEmpty {
                applyConnection(mode: .direct, host: host, persist: false)
            }
            return
        }

        // Automatic mode prefers the physical cable when the link-local beacon
        // is present. This is what makes a bare USB-C cable plug-and-play.
        NSLog("VPAD_CABLE_DISCOVERY switching to cable host=%@", host)
        applyConnection(mode: .direct, host: host, persist: false)
    }

    private func scheduleDirectFallback() {
        directFallbackTask?.cancel()
        directFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.transportMode == .direct,
               self.manualHost.hasPrefix("169.254."),
               !self.isConnected {
                NSLog("VPAD_CABLE_DISCOVERY link lost; falling back to Bonjour")
                self.applyConnection(mode: .automatic, host: "", persist: false)
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        directFallbackTask?.cancel()
        directFallbackTask = nil
        if discoveryStarted {
            LinkDiscovery.shared.stop()
            discoveryStarted = false
        }
        TCPFileClient.shared.stop()
        UDPClient.shared.stop()
        ModifierState.shared.clear()
        connectionState = .disconnected
        peerName = nil
        remoteHost = nil
        latencyMilliseconds = nil
    }

    func upload(_ url: URL) {
        uploadName = url.lastPathComponent
        uploadProgress = 0
        lastFileStatus = nil
        lastError = nil
        TCPFileClient.shared.uploadFile(at: url)
    }

    func sendShortcut(keyCode: UInt16, modifiers: UInt16) {
        UDPClient.shared.send(VPadPacket.keyShortcut(keyCode: keyCode, modifiers: modifiers))
    }

    func sendKeyboardPress(keyCode: UInt16, phase: Phase, modifiers: UInt16) {
        UDPClient.shared.send(VPadPacket.keyboardPress(keyCode: keyCode, phase: phase, modifiers: modifiers))
    }

    func sendFunctionKey(_ key: FunctionKey) {
        if let custom = actionForFunctionKey(key) {
            executeAction(custom)
        } else {
            sendShortcut(keyCode: key.virtualKeyCode, modifiers: UInt16(key.modifierMask.rawValue))
        }
    }

    func sendSystemAction(_ action: SystemAction) {
        UDPClient.shared.send(VPadPacket.systemAction(action))
    }

    func selectTool(_ tool: String) {
        switch tool.lowercased() {
        case "eraser":
            sendShortcut(keyCode: 14, modifiers: 0) // 'E'
        case "brush":
            sendShortcut(keyCode: 11, modifiers: 0) // 'B'
        default:
            break
        }
    }

    func executeAction(_ action: Action) {
        ActionRunner.execute(action, via: self)
    }

    func actionForFunctionKey(_ key: FunctionKey) -> Action? {
        activeProfile.functionKeyActions[key.rawValue]
    }

    private func handle(_ event: TCPFileClient.Event) {
        switch event {
        case .connecting:
            connectionState = .connecting
            peerName = nil
        case .handshaking:
            connectionState = .handshaking
        case .connected(let peer):
            connectionState = .active
            peerName = peer
            lastError = nil
            directFallbackTask?.cancel()
            directFallbackTask = nil
            #if DEBUG
            runAutoSmokeIfNeeded()
            #endif
        case .reconnecting(let reason):
            connectionState = .reconnecting
            peerName = nil
            latencyMilliseconds = nil
            lastError = reason
            if transportMode == .direct, manualHost.hasPrefix("169.254.") {
                scheduleDirectFallback()
            }
        case .remoteAddress(let host):
            remoteHost = host
        case .disconnected(let reason):
            connectionState = .disconnected
            peerName = nil
            latencyMilliseconds = nil
            droppedPackets = 0
            lastUDPNonce = nil
            lastError = reason
            if transportMode == .direct, manualHost.hasPrefix("169.254.") {
                scheduleDirectFallback()
            }
        case .latency(let milliseconds):
            latencyMilliseconds = milliseconds
        case .stats(let dropped, let lastNonce):
            droppedPackets = dropped
            lastUDPNonce = lastNonce
        case .fileProgress(let name, let progress):
            uploadName = name
            uploadProgress = progress
        case .fileStatus(let name, let status):
            uploadName = name
            uploadProgress = 1
            lastFileStatus = status
            #if DEBUG
            if ProcessInfo.processInfo.environment["VPAD_AUTO_SMOKE"] == "1" {
                NSLog("VPAD_AUTO_SMOKE file status %d", status.rawValue)
            }
            #endif
            if status != .success {
                lastError = "File transfer: \(status.displayName)"
            }
        case .activeApplication(let bundleID):
            onActiveApplicationChanged(bundleID)
        case .error(let message):
            lastError = message
        }
    }

    #if DEBUG
    private func runAutoSmokeIfNeeded() {
        guard !didAutoSmoke,
              ProcessInfo.processInfo.environment["VPAD_AUTO_SMOKE"] == "1" else {
            return
        }
        didAutoSmoke = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpad-ipad-smoke.bin")
        do {
            try Data(repeating: 0x42, count: 1_048_576).write(to: url)
        } catch {
            NSLog("VPAD_AUTO_SMOKE file write failed: %@", error.localizedDescription)
            return
        }
        UDPClient.shared.send(VPadPacket.trackpadMove(dx: 0, dy: 0))
        UDPClient.shared.send(VPadPacket.trackpadMove(dx: 0, dy: 0))
        NSLog("VPAD_AUTO_SMOKE uploading %@", url.path)
        upload(url)
    }
    #endif

    func onActiveApplicationChanged(_ bundleID: String) {
        self.activeAppBundleID = bundleID
        let matched = profileStore.profile(for: bundleID)
        self.activeProfile = matched

        var pencilSettings = PencilSettingsStore.shared.settings
        pencilSettings.pressureCurveConfig = matched.pressureCurve
        PencilSettingsStore.shared.update(pencilSettings)
    }
}

extension FileStatus {
    var displayName: String {
        switch self {
        case .success: return "success"
        case .checksumMismatch: return "checksum mismatch"
        case .diskError: return "disk error"
        case .cancelled: return "cancelled"
        }
    }
}

extension SessionCoordinator: ActionDispatcher {}
