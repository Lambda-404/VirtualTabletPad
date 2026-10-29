import AppKit
import Combine
import Darwin
import SwiftUI
import VPadProtocol

private struct LocalIPv4Address: Identifiable {
    let id = UUID()
    let interface: String
    let address: String
}

private func localIPv4Addresses() -> [LocalIPv4Address] {
    var result: [LocalIPv4Address] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
    defer { freeifaddrs(ifaddr) }

    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let interface = current.pointee
        if let address = interface.ifa_addr,
           address.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name != "lo0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    result.append(
                        LocalIPv4Address(
                            interface: name,
                            address: String(decoding: bytes, as: UTF8.self)
                        )
                    )
                }
            }
        }
        pointer = interface.ifa_next
    }
    return result
}

private func appVersionText() -> String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "VirtualTabletPad \(version) · Build \(build)"
}

// MARK: - UI state

@MainActor
final class HostStatus: ObservableObject {
    @MainActor static let shared = HostStatus()

    @Published var accessibilityGranted = false
    @Published var isTCPListening = false
    @Published var isUDPListening = false
    @Published var connectionState: VPadConnectionState = .disconnected
    @Published var peerDescription: String?
    @Published var receivedPackets: UInt64 = 0
    @Published var droppedPackets: UInt64 = 0
    @Published var lastUDPCounter: UInt64?
    @Published var lastUploadName: String?
    @Published var lastUploadStatus: FileStatus?
    @Published var lastError: String?
    @Published var pairedDevices: [PairedDevice] = []

    var isConnected: Bool {
        connectionState == .active
    }

    private init() {
        refreshPairedDevices()
    }

    func refreshPairedDevices() {
        pairedDevices = PersistentDeviceAllowlistStore.shared.allDevices()
    }

    func update(stats: SessionStats) {
        receivedPackets = stats.received
        droppedPackets = stats.dropped
        lastUDPCounter = stats.lastUDPCounter
    }

    func setConnectionState(_ state: VPadConnectionState, peer: String? = nil) {
        connectionState = state
        if state == .active {
            peerDescription = peer
            lastError = nil
        } else if state == .disconnected {
            peerDescription = nil
        }
    }

    func markConnected(peer: String?) {
        setConnectionState(.active, peer: peer)
    }

    func markDisconnected() {
        setConnectionState(.disconnected)
    }

    func recordUpload(name: String, status: FileStatus) {
        lastUploadName = name
        lastUploadStatus = status
    }

    func recordError(_ message: String) {
        lastError = message
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

// MARK: - App

@main
struct MacHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var status = HostStatus.shared
    @StateObject private var accessibility = AccessibilityManager.shared

    var body: some Scene {
        MenuBarExtra {
            HostMenuView(status: status, accessibility: accessibility)
        } label: {
            MenuBarLabel(status: status, accessibility: accessibility)
        }
        .menuBarExtraStyle(.menu)

        Window("Gesture Map", id: GestureMapView.windowID) {
            GestureMapView()
        }
        .defaultSize(width: 720, height: 520)

        Window("Pair iPad", id: "pairing") {
            PairingView()
        }
        .defaultSize(width: 400, height: 600)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["VPAD_DRY_RUN_INJECT"] == "1" {
            let line = "[DRY_RUN] MacHost started with VPAD_DRY_RUN_INJECT=1\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
                try? FileHandle.standardOutput.synchronize()
            }
        }
        NSApp.setActivationPolicy(.accessory)
        AccessibilityManager.shared.start()
        UDPServer.shared.start()
        TCPServer.shared.start()
        HostBeacon.shared.start()
        USBProxy.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        HostBeacon.shared.stop()
        USBProxy.shared.stop()
        TCPServer.shared.stop()
        UDPServer.shared.stop()
    }
}

// MARK: - Menu bar UI

private struct MenuBarLabel: View {
    @ObservedObject var status: HostStatus
    @ObservedObject var accessibility: AccessibilityManager

    var body: some View {
        Image(systemName: "ipad.and.iphone")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(indicatorColor)
    }

    private var indicatorColor: Color {
        guard accessibility.isTrusted else { return .red }
        switch status.connectionState {
        case .active: return .green
        case .handshaking: return .blue
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        }
    }
}

private struct HostMenuView: View {
    @ObservedObject var status: HostStatus
    @ObservedObject var accessibility: AccessibilityManager
    @Environment(\.openWindow) private var openWindow

    private var indicatorColor: Color {
        guard accessibility.isTrusted else { return .red }
        switch status.connectionState {
        case .active: return .green
        case .handshaking: return .blue
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(status.connectionState.title)
                .font(.headline)
            if let peer = status.peerDescription {
                Text("(\(peer))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        if status.isConnected {
            Text("Packets: \(status.receivedPackets) · Dropped: \(status.droppedPackets)")
                .font(.caption)
            if let nonce = status.lastUDPCounter {
                Text("Last UDP nonce: \(nonce)")
                    .font(.caption)
            }
        }

        Text("TCP \(status.isTCPListening ? "listening :8889" : "offline") · UDP \(status.isUDPListening ? "listening :8888" : "offline")")
            .font(.caption2)
            .foregroundStyle(.secondary)

        let addresses = localIPv4Addresses()
        if !addresses.isEmpty {
            Text("Cable / direct IP")
                .font(.caption)
                .fontWeight(.semibold)
            ForEach(addresses) { entry in
                Button("Copy \(entry.address) · \(entry.interface)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.address, forType: .string)
                }
                .font(.caption)
            }
        }

        Divider()

        if accessibility.isTrusted {
            Label("Accessibility granted", systemImage: "checkmark.circle")
                .font(.caption)
        } else {
            Label("Accessibility permission required", systemImage: "exclamationmark.triangle")
                .font(.caption)
            Button("Request Accessibility Access") {
                accessibility.requestAccess()
            }
            Button("Open Accessibility Settings") {
                accessibility.openSettings()
            }
        }

        if let upload = status.lastUploadName {
            Text("Last upload: \(upload) (\(status.lastUploadStatus?.displayName ?? "unknown"))")
                .font(.caption)
        }

        if let error = status.lastError {
            Text("Error: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
        }

        Text(appVersionText())
            .font(.caption2)
            .foregroundStyle(.secondary)

        if !status.pairedDevices.isEmpty {
            Divider()
            Text("Paired Devices")
                .font(.caption)
                .fontWeight(.semibold)
            ForEach(status.pairedDevices) { device in
                HStack {
                    Text(device.name)
                        .font(.caption)
                    Spacer()
                    Button("Forget") {
                        PersistentDeviceAllowlistStore.shared.forget(identity: device.identityPublicKey)
                        status.refreshPairedDevices()
                    }
                    .font(.caption2)
                }
            }
        }

        Divider()

        Button("Gesture Map…") {
            openWindow(id: GestureMapView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Pair iPad…") {
            openWindow(id: "pairing")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit VirtualTabletPad") {
            NSApp.terminate(nil)
        }
    }
}
