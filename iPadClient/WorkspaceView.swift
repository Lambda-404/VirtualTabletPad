import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VPadProtocol

struct WorkspaceView: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            LiquidGlassWorkspaceView()
        } else {
            LegacyWorkspaceView()
        }
    }
}

struct LegacyWorkspaceView: View {
    @StateObject private var coordinator = SessionCoordinator()
    @StateObject private var pencil = PencilProManager()
    @ObservedObject private var guidedAccess = GuidedAccessMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardMode: KeyboardMode = .off
    @State private var isDropTargeted = false
    @State private var showFileImporter = false
    @State private var showConnectionSheet = false
    @State private var showTouchpadSettings = false
    @State private var radialSelection: RadialTool = .pen

    var body: some View {
        HStack(spacing: 0) {
            ModifierSidebar()
                .frame(width: 78)
            canvasArea
            ControlPanel(
                coordinator: coordinator,
                pencil: pencil,
                keyboardMode: $keyboardMode,
                showFileImporter: $showFileImporter
            )
            .frame(width: 236)
        }
        .background(Color.vpadBackground.ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .overlay(alignment: .topLeading) {
            KeyboardHost(mode: $keyboardMode)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .overlay {
            ScreenEdgeDeferringView(enabled: !guidedAccess.isEnabled)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let message = pencil.lastEventMessage {
                Text(message)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.vpadCyan))
                    .padding(.bottom, 26)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pencil.lastEventMessage)
        .onAppear { coordinator.start() }
        .onDisappear {
            ModifierState.shared.clear()
            SafetyGestureState.shared.clear()
            publishModifierState()
            coordinator.stop()
            keyboardMode = .off
            pencil.radialMenuCenter = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                ModifierState.shared.clear()
                SafetyGestureState.shared.clear()
                publishModifierState()
                keyboardMode = .off
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                copyAndUpload(url)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionSettingsView(coordinator: coordinator)
        }
        .sheet(isPresented: $showTouchpadSettings) {
            TouchpadSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(red: 0.055, green: 0.055, blue: 0.062))
        }
    }

    private var canvasArea: some View {
        VStack(spacing: 8) {
            statusBar
            GeometryReader { geometry in
                let ratio: CGFloat = 16.0 / 10.0
                let maxWidth = max(geometry.size.width - 24, 1)
                let maxHeight = max(geometry.size.height - 24, 1)
                let width = min(maxWidth, maxHeight * ratio)
                let height = width / ratio
                ZStack(alignment: .topLeading) {
                    CanvasRepresentable(pencil: pencil)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isDropTargeted ? Color.vpadCyan : Color.vpadBorder, lineWidth: 1.5)
                        )
                    if let center = pencil.radialMenuCenter {
                        RadialToolHUD(
                            selection: $radialSelection,
                            onSelect: { tool in
                                radialSelection = tool
                                pencil.radialMenuCenter = nil
                            },
                            onClose: { pencil.radialMenuCenter = nil }
                        )
                        .position(x: center.x, y: center.y)
                    }
                }
                .frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            if let peer = coordinator.peerName {
                Text(peer)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let latency = coordinator.latencyMilliseconds {
                Label(String(format: "%.1f ms", latency), systemImage: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                showConnectionSheet = true
            } label: {
                Label(
                    coordinator.transportMode == .usb
                        ? "USB"
                        : (coordinator.transportMode == .direct
                            ? (coordinator.manualHost.isEmpty ? "Direct" : coordinator.manualHost)
                            : "Auto"),
                    systemImage: "network"
                )
                .font(.caption)
                .lineLimit(1)
            }
            Button {
                showTouchpadSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .accessibilityLabel("Touchpad settings")
            Menu {
                ForEach(KeyboardMode.allCases) { mode in
                    Button(mode.title) { keyboardMode = mode }
                }
            } label: {
                Label("Keyboard", systemImage: "keyboard")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private var statusColor: Color {
        switch coordinator.connectionState {
        case .active: return .green
        case .handshaking: return .blue
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch coordinator.connectionState {
        case .active: return coordinator.peerName.map { "Connected to \($0)" } ?? "Connected"
        case .handshaking: return "Authenticating…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
            guard let url else { return }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                Task { @MainActor in
                    coordinator.upload(destination)
                }
            } catch {
                NSLog("VPad drop copy failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func copyAndUpload(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            coordinator.upload(destination)
        } catch {
            NSLog("VPad file copy failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Canvas wrapper

private struct CanvasRepresentable: UIViewRepresentable {
    let pencil: PencilProManager

    func makeUIView(context: Context) -> HybridCanvasView {
        let canvas = HybridCanvasView(frame: .zero)
        canvas.onPacket = { packet in
            UDPClient.shared.send(packet)
        }
        pencil.attach(to: canvas)
        return canvas
    }

    func updateUIView(_ uiView: HybridCanvasView, context: Context) {}
}

// MARK: - Modifier sidebar

private struct ModifierSidebar: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("MODS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            ModifierButton(title: "⌘", mask: .command)
            ModifierButton(title: "⇧", mask: .shift)
            ModifierButton(title: "⌥", mask: .option)
            ModifierButton(title: "⌃", mask: .control)
            ModifierButton(title: "Space", mask: .space, compact: true)
            Spacer()
            Text("Hold")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
        .background(Color.vpadSurface.opacity(0.75))
        .onDisappear {
            ModifierState.shared.clear()
            publishModifierState()
        }
    }
}

private struct ModifierButton: View {
    let title: String
    let mask: ModifierMask
    var compact = false

    @State private var pressed = false

    var body: some View {
        Text(title)
            .font(.system(size: compact ? 11 : 21, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed ? Color.black : Color.primary)
            .frame(width: compact ? 54 : 52, height: compact ? 34 : 52)
            .background(
                Circle().fill(pressed ? Color.vpadCyan : Color.vpadSurface)
            )
            .overlay(
                Circle().stroke(Color.vpadBorder, lineWidth: pressed ? 0 : 1)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in setPressed(true) }
                    .onEnded { _ in setPressed(false) }
            )
    }

    private func setPressed(_ value: Bool) {
        guard value != pressed else { return }
        pressed = value
        ModifierState.shared.set(mask, enabled: value)
        publishModifierState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// A zero-delta move packet makes the Mac observe Space/modifier transitions even
/// when the user is not moving a finger. In particular it releases a synthesized
/// Space-pan key when the sidebar button is lifted.
@MainActor
private func publishModifierState() {
    UDPClient.shared.send(VPadPacket.trackpadMove(
        dx: 0,
        dy: 0,
        modifiers: ModifierState.shared.snapshot()
    ))
}

// MARK: - Side panel

private struct ControlPanel: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var pencil: PencilProManager
    @ObservedObject private var guidedAccess = GuidedAccessMonitor.shared
    @Binding var keyboardMode: KeyboardMode
    @Binding var showFileImporter: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                connectionCard
                shortcutsCard
                transferCard
                gesturesCard
                squeezeCard
            }
            .padding(12)
        }
        .background(Color.vpadSurface.opacity(0.6))
    }

    private var connectionCard: some View {
        PanelCard(title: "Connection") {
            HStack(spacing: 6) {
                Text(coordinator.isConnected ? "Connected" : "Disconnected")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(coordinator.isConnected ? .green : .orange)
                Spacer()
                if let latency = coordinator.latencyMilliseconds {
                    Text(String(format: "%.1f ms", latency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let peer = coordinator.peerName {
                Text(peer)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(coordinator.lastUDPNonce.map { "UDP nonce \($0)" } ?? "UDP waiting")
                Text("dropped \(coordinator.droppedPackets)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var shortcutsCard: some View {
        PanelCard(title: "Shortcuts") {
            HStack(spacing: 6) {
                shortcut("Undo", key: 6, modifiers: ModifierMask.command.rawValue)
                shortcut("Redo", key: 6, modifiers: ModifierMask.command.rawValue | ModifierMask.shift.rawValue)
            }
            HStack(spacing: 6) {
                shortcut("Brush [", key: 33, modifiers: 0)
                shortcut("Brush ]", key: 30, modifiers: 0)
            }
        }
    }

    private func shortcut(_ title: String, key: UInt16, modifiers: UInt16) -> some View {
        Button(title) {
            coordinator.sendShortcut(keyCode: key, modifiers: modifiers)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private var transferCard: some View {
        PanelCard(title: "File Transfer") {
            Button {
                showFileImporter = true
            } label: {
                Label("Send File", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("or drop a file anywhere in the workspace")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let name = coordinator.uploadName, let progress = coordinator.uploadProgress {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let status = coordinator.lastFileStatus {
                Text("Last file: \(status.displayName)")
                    .font(.caption2)
                    .foregroundStyle(status == .success ? .green : .red)
            }
        }
    }

    private var gesturesCard: some View {
        PanelCard(title: "Gestures") {
            Text(guidedAccess.isEnabled ? "Full gestures · engines can be switched below" : "Safe gestures · engines can be switched below")
                .font(.caption2)
                .foregroundStyle(guidedAccess.isEnabled ? Color.green : Color.orange)
            Picker("Gesture engine", selection: Binding(
                get: { guidedAccess.preference },
                set: { guidedAccess.setPreference($0) }
            )) {
                ForEach(GestureModePreference.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            ForEach(GestureEngine.bindings) { binding in
                VStack(alignment: .leading, spacing: 1) {
                    Text(binding.title)
                        .font(.caption)
                    Text(binding.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !GestureEngine.shared.patternBindings.isEmpty {
                Divider()
                ForEach(GestureEngine.shared.patternBindings) { binding in
                    Text("\(binding.title): \(binding.detail)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Mac actions are edited in the Mac Gesture Map.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var squeezeCard: some View {
        PanelCard(title: "Pencil Pro") {
            Picker("Squeeze", selection: $pencil.squeezeMode) {
                ForEach(SqueezeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(pencil.lastEventMessage ?? "Last Pencil interaction: —")
                .font(.caption2)
                .foregroundStyle(pencil.lastEventMessage == nil ? .secondary : .primary)
            Text("Squeeze haptics are always active. Double-tap toggles the Mac eraser.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PanelCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.vpadBackground.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.vpadBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Radial HUD

private enum RadialTool: String, CaseIterable, Identifiable {
    case pen
    case eraser
    case undo

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .undo: return "arrow.uturn.backward"
        }
    }
}

private struct RadialToolHUD: View {
    @Binding var selection: RadialTool
    let onSelect: (RadialTool) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.vpadSurface)
                .overlay(Circle().stroke(Color.vpadCyan.opacity(0.6), lineWidth: 1))
                .frame(width: 154, height: 154)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

            HStack(spacing: 10) {
                ForEach(RadialTool.allCases) { tool in
                    Button {
                        onSelect(tool)
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(selection == tool ? Color.black : Color.primary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(selection == tool ? Color.vpadCyan : Color.vpadBackground))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .offset(y: -76)
        }
        .frame(width: 170, height: 170)
    }
}

// MARK: - Colors

private extension Color {
    static let vpadBackground = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let vpadSurface = Color(red: 0.118, green: 0.118, blue: 0.133)
    static let vpadBorder = Color(red: 0.173, green: 0.173, blue: 0.188)
    static let vpadCyan = Color(red: 0.0, green: 0.9, blue: 1.0)
}
