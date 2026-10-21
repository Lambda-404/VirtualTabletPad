import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VPadProtocol

// MARK: - Liquid Glass workspace (iPadOS 26+)

@available(iOS 26.0, *)
struct LiquidGlassWorkspaceView: View {
    @StateObject private var coordinator = SessionCoordinator()
    @StateObject private var pencil = PencilProManager()
    @ObservedObject private var guidedAccess = GuidedAccessMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    @Namespace private var glassNS

    @State private var keyboardMode: KeyboardMode = .off
    @State private var isDropTargeted = false
    @State private var showFileImporter = false
    @State private var showFunctionPad = false
    @State private var showSettings = false
    @State private var settingsSection: SettingsSection = .touchpad
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 6) {
                topTouchBar

                if keyboardHeight > 0 {
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        keyboardModePanel
                        keyboardAccessory
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                } else {
                    tabletCanvas
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, keyboardHeight + 4)

            KeyboardHost(mode: $keyboardMode)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)

            ScreenEdgeDeferringView(enabled: !guidedAccess.isEnabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            radialLayer
            toastLayer
            dropLayer
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: pencil.radialMenuCenter != nil)
        .animation(.spring(response: 0.30, dampingFraction: 0.86), value: keyboardHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: coordinator.uploadProgress)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardHeight = max(0, activeWindowHeight - frame.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onAppear {
            coordinator.start()
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["VPAD_SHOW_RADIAL"] == "1" {
                pencil.radialMenuCenter = CGPoint(x: 683, y: 512)
            }
            if environment["VPAD_SHOW_CONNECTION"] == "1" {
                settingsSection = .connection
                showSettings = true
            }
            if environment["VPAD_SHOW_TOUCHPAD_SETTINGS"] == "1" {
                settingsSection = .touchpad
                showSettings = true
            }
            if environment["VPAD_SHOW_PENCIL_SETTINGS"] == "1" {
                settingsSection = .pencil
                showSettings = true
            }
            if environment["VPAD_SHOW_FUNCTION_KEYS_SETTINGS"] == "1" {
                settingsSection = .functionKeys
                showSettings = true
            }
            if environment["VPAD_SHOW_ABOUT_SETTINGS"] == "1" {
                settingsSection = .about
                showSettings = true
            }
            if environment["VPAD_SHOW_FUNCTION_PAD"] == "1" {
                showFunctionPad = true
            }
            if environment["VPAD_SHOW_KEYBOARD"] == "1" {
                keyboardMode = .software
            }
            if let raw = environment["VPAD_FAKE_KEYBOARD_HEIGHT"],
               let value = Double(raw) {
                keyboardHeight = CGFloat(value)
            }
            #endif
        }
        .onDisappear {
            ModifierState.shared.clear()
            SafetyGestureState.shared.clear()
            liquidPublishModifierState()
            coordinator.stop()
            keyboardMode = .off
            pencil.radialMenuCenter = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                ModifierState.shared.clear()
                SafetyGestureState.shared.clear()
                liquidPublishModifierState()
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
        .sheet(isPresented: $showSettings) {
            WorkspaceSettingsView(
                coordinator: coordinator,
                pencil: pencil,
                keyboardMode: $keyboardMode,
                initialSection: settingsSection
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(red: 0.055, green: 0.055, blue: 0.062))
        }
        .sheet(isPresented: $showFunctionPad) {
            FunctionPadView(coordinator: coordinator)
                .presentationDetents([.height(400), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(red: 0.055, green: 0.055, blue: 0.062))
        }
    }

    // MARK: - Floating functional layer

    private var activeWindowHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .bounds.height ?? UIScreen.main.bounds.height
    }

    private var tabletCanvas: some View {
        GeometryReader { geo in
            let bezel: CGFloat = 12
            let maxActiveWidth = max(geo.size.width - bezel * 2, 1)
            let maxActiveHeight = max(geo.size.height - bezel * 2, 1)
            let widthLimitedHeight = maxActiveWidth / 1.6
            let activeWidth = widthLimitedHeight <= maxActiveHeight ? maxActiveWidth : maxActiveHeight * 1.6
            let activeHeight = activeWidth / 1.6
            let outerWidth = activeWidth + bezel * 2
            let outerHeight = activeHeight + bezel * 2

            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.14, blue: 0.16),
                                Color(red: 0.055, green: 0.06, blue: 0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )

                LiquidCanvasRepresentable(
                    pencil: pencil,
                    isConnected: coordinator.isConnected
                )
                .frame(width: activeWidth, height: activeHeight)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .frame(width: outerWidth, height: outerHeight)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var keyboardModePanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))

            VStack(alignment: .leading, spacing: 0) {
                Text("Keyboard Mode")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Tablet paused")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                keyboardPanelButton(
                    title: "Hide",
                    symbol: "chevron.down.circle",
                    prominent: true
                ) {
                    keyboardMode = .off
                }
                keyboardPanelButton(title: "Fn Pad", symbol: "function") {
                    showFunctionPad = true
                }
                keyboardPanelButton(title: "Settings", symbol: "slider.horizontal.3") {
                    settingsSection = .touchpad
                    showSettings = true
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func keyboardPanelButton(
        title: String,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.86))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(prominent ? Color.liquidCyan : Color.white.opacity(0.09))
                )
        }
        .buttonStyle(.plain)
    }

    private var topTouchBar: some View {
        ViewThatFits(in: .horizontal) {
            touchBarRow(compact: false)
            touchBarRow(compact: true)
            ScrollView(.horizontal, showsIndicators: false) {
                touchBarRow(compact: true)
                    .frame(minWidth: 900)
            }
        }
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(red: 0.035, green: 0.035, blue: 0.04).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func touchBarRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            connectionControl

            toolbarCluster {
                DockIconButton(symbol: "arrow.up.doc", label: "Send file") {
                    showFileImporter = true
                }
                keyboardMenu
                DockIconButton(symbol: "function", label: "Function keys") {
                    showFunctionPad = true
                }
                DockIconButton(symbol: "slider.horizontal.3", label: "Settings") {
                    settingsSection = .touchpad
                    showSettings = true
                }
            }

            if keyboardHeight == 0 {
                toolbarCluster {
                    ForEach(LiquidModifier.allCases) { modifier in
                        LiquidModifierButton(modifier: modifier)
                    }
                }
            }

            if compact {
                toolbarCluster {
                    editOverflowMenu
                }
            } else {
                toolbarCluster {
                    DockIconButton(symbol: "arrow.uturn.backward", label: "Undo") {
                        sendUndo()
                    }
                    DockIconButton(symbol: "arrow.uturn.forward", label: "Redo") {
                        sendRedo()
                    }
                    DockIconButton(symbol: "minus.circle", label: "Brush smaller") {
                        sendBrushSmaller()
                    }
                    DockIconButton(symbol: "plus.circle", label: "Brush larger") {
                        sendBrushLarger()
                    }
                }
            }

            Spacer(minLength: 8)

            PencilStatusBadge {
                settingsSection = .pencil
                showSettings = true
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }

    private var connectionControl: some View {
        Button {
            settingsSection = .connection
            showSettings = true
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(connectionTitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let latency = coordinator.latencyMilliseconds {
                            Text(String(format: "%.1f ms", latency))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(transportLabel)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.liquidCyan)
                        Text(guidedAccess.badgeTitle)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                guidedAccess.isEnabled ? Color.green : Color.liquidAmber
                            )
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var keyboardMenu: some View {
        Menu {
            ForEach(KeyboardMode.allCases) { mode in
                Button(mode.title) { keyboardMode = mode }
            }
        } label: {
            Image(systemName: keyboardMode == .off ? "keyboard" : "keyboard.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keyboard mode")
    }

    private var editOverflowMenu: some View {
        Menu {
            Button {
                sendUndo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            Button {
                sendRedo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            Divider()
            Button {
                sendBrushSmaller()
            } label: {
                Label("Brush smaller", systemImage: "minus.circle")
            }
            Button {
                sendBrushLarger()
            } label: {
                Label("Brush larger", systemImage: "plus.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit actions")
    }

    private func sendUndo() {
        coordinator.sendShortcut(keyCode: 6, modifiers: ModifierMask.command.rawValue)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendRedo() {
        coordinator.sendShortcut(
            keyCode: 6,
            modifiers: ModifierMask.command.rawValue | ModifierMask.shift.rawValue
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendBrushSmaller() {
        coordinator.sendShortcut(keyCode: 33, modifiers: 0)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendBrushLarger() {
        coordinator.sendShortcut(keyCode: 30, modifiers: 0)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func toolbarCluster<Content: View>(
        spacing: CGFloat = 4,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: spacing) {
            content()
        }
        .padding(.horizontal, 4)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var keyboardAccessory: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                toolbarCluster {
                    ForEach(FunctionKey.allCases) { key in
                        Button {
                            coordinator.sendFunctionKey(key)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(key.title)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.white.opacity(0.075))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                toolbarCluster {
                    ForEach(LiquidModifier.allCases) { modifier in
                        LiquidModifierButton(modifier: modifier)
                    }
                }

                toolbarCluster {
                    accessoryIcon("sun.min", label: "Brightness down") {
                        coordinator.sendSystemAction(.brightnessDown)
                    }
                    accessoryIcon("sun.max", label: "Brightness up") {
                        coordinator.sendSystemAction(.brightnessUp)
                    }
                    accessoryIcon("rectangle.3.group", label: "Mission Control") {
                        coordinator.sendSystemAction(.missionControl)
                    }
                    accessoryIcon("rectangle.on.rectangle", label: "App Exposé") {
                        coordinator.sendSystemAction(.appExpose)
                    }
                    accessoryIcon("chevron.left.2", label: "Desktop left") {
                        coordinator.sendSystemAction(.desktopLeft)
                    }
                    accessoryIcon("chevron.right.2", label: "Desktop right") {
                        coordinator.sendSystemAction(.desktopRight)
                    }
                    accessoryIcon("square.grid.3x3", label: "Launchpad") {
                        coordinator.sendSystemAction(.launchpad)
                    }
                    accessoryIcon("playpause", label: "Play/Pause") {
                        coordinator.sendSystemAction(.playPause)
                    }
                    accessoryIcon("forward.end", label: "Next") {
                        coordinator.sendSystemAction(.nextTrack)
                    }
                    accessoryIcon("backward.end", label: "Previous") {
                        coordinator.sendSystemAction(.previousTrack)
                    }
                    accessoryIcon("speaker.minus", label: "Volume down") {
                        coordinator.sendSystemAction(.volumeDown)
                    }
                    accessoryIcon("speaker.plus", label: "Volume up") {
                        coordinator.sendSystemAction(.volumeUp)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(red: 0.035, green: 0.035, blue: 0.04).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func accessoryIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.075))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var connectionTitle: String {
        switch coordinator.connectionState {
        case .connected:
            return coordinator.transportMode == .usb ? "USB Cable" : "Connected"
        case .searching:
            return coordinator.transportMode == .direct ? "Connecting…" : "Searching…"
        case .failed:
            return "Connection issue"
        case .idle:
            return "Offline"
        }
    }

    private var connectionColor: Color {
        switch coordinator.connectionState {
        case .connected: return .green
        case .searching: return .liquidAmber
        case .failed: return .liquidOrange
        case .idle: return .secondary
        }
    }

    private var transportLabel: String {
        switch coordinator.transportMode {
        case .automatic: return "AUTO"
        case .usb: return "USB"
        case .direct: return "IP"
        }
    }

    @ViewBuilder
    private var radialLayer: some View {
        if let center = pencil.radialMenuCenter {
            LiquidRadialHUD(namespace: glassNS, onSelect: { tool in
                switch tool {
                case .undo:
                    coordinator.sendShortcut(
                        keyCode: 6,
                        modifiers: ModifierMask.command.rawValue
                    )
                case .eraser:
                    coordinator.sendShortcut(keyCode: 14, modifiers: 0)
                case .pen:
                    break
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                pencil.radialMenuCenter = nil
            }, onClose: {
                pencil.radialMenuCenter = nil
            })
            .position(x: center.x, y: center.y)
            .zIndex(6)
        }
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let message = pencil.lastEventMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .zIndex(5)
        }
    }

    @ViewBuilder
    private var dropLayer: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.liquidCyan.opacity(0.8), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.liquidCyan.opacity(0.06))
                )
                .overlay {
                    Label("Drop to send", systemImage: "doc.badge.arrow.up")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.tint(.liquidCyan).interactive(), in: .capsule)
                }
                .padding(36)
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(7)
        }
    }

    // MARK: - Files

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

// MARK: - Canvas bridge

@available(iOS 26.0, *)
private struct LiquidCanvasRepresentable: UIViewRepresentable {
    let pencil: PencilProManager
    let isConnected: Bool

    func makeUIView(context: Context) -> HybridCanvasView {
        let canvas = HybridCanvasView(frame: .zero)
        canvas.onPacket = { packet in
            UDPClient.shared.send(packet)
        }
        canvas.ambientColor = isConnected ? .liquidCyan : .liquidAmber
        pencil.attach(to: canvas)
        return canvas
    }

    func updateUIView(_ uiView: HybridCanvasView, context: Context) {
        uiView.ambientColor = isConnected ? .liquidCyan : .liquidAmber
    }
}

// MARK: - Ambient light source

@available(iOS 26.0, *)
private struct LiquidAmbientBackdrop: View {
    let isConnected: Bool

    var body: some View {
        ZStack {
            PhaseAnimator([0.07, 0.14]) { opacity in
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
                        SIMD2<Float>(0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1, 0.5),
                        SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 1), SIMD2<Float>(1, 1),
                    ],
                    colors: isConnected
                        ? [
                            Color.liquidCyan, Color.liquidIndigo, Color.liquidCyan,
                            Color.liquidIndigo, Color.liquidBase, Color.liquidIndigo,
                            Color.liquidCyan, Color.liquidIndigo, Color.liquidCyan,
                        ]
                        : [
                            Color.liquidAmber, Color.liquidOrange, Color.liquidAmber,
                            Color.liquidOrange, Color.liquidBase, Color.liquidOrange,
                            Color.liquidAmber, Color.liquidOrange, Color.liquidAmber,
                        ]
                )
                .opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 2.6)
            }

            // Localised light pools sit directly under the floating glass
            // islands, so the lensing has coloured content to refract.
            HStack(spacing: 0) {
                Ellipse()
                    .fill((isConnected ? Color.liquidCyan : Color.liquidAmber).opacity(0.48))
                    .frame(width: 260, height: 480)
                    .blur(radius: 70)
                    .offset(x: -40)
                Spacer()
                Ellipse()
                    .fill((isConnected ? Color.liquidIndigo : Color.liquidOrange).opacity(0.42))
                    .frame(width: 280, height: 500)
                    .blur(radius: 80)
                    .offset(x: 40)
            }

            VStack {
                Capsule()
                    .fill((isConnected ? Color.liquidCyan : Color.liquidAmber).opacity(0.34))
                    .frame(width: 340, height: 96)
                    .blur(radius: 50)
                    .offset(y: -18)
                Spacer()
            }
        }
        .mask(
            RadialGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.38),
                    .init(color: .white.opacity(0.9), location: 0.85),
                    .init(color: .white.opacity(0.45), location: 1.0),
                ],
                center: .center,
                startRadius: 0,
                endRadius: 1300
            )
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - Top pill

@available(iOS 26.0, *)
private struct LiquidConnectionPill: View {
    @ObservedObject var coordinator: SessionCoordinator
    let namespace: Namespace.ID
    let action: () -> Void

    private var isUploading: Bool {
        guard let progress = coordinator.uploadProgress else { return false }
        return progress < 1
    }

    private var statusKey: String {
        if isUploading { return "upload" }
        switch coordinator.connectionState {
        case .connected: return "connected"
        case .searching: return "searching"
        case .failed: return "failed"
        case .idle: return "idle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                if isUploading,
                   let name = coordinator.uploadName,
                   let progress = coordinator.uploadProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .lineLimit(1)
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.liquidCyan)
                            .frame(width: 130)
                    }
                } else {
                    Text(statusTitle)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    if let latency = coordinator.latencyMilliseconds {
                        Text(String(format: "%.1f ms", latency))
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if coordinator.transportMode != .automatic {
                        Text(coordinator.transportMode == .usb ? "USB" : "Cable")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Color.liquidCyan)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("connection", in: namespace)
        .glassEffectTransition(.matchedGeometry)
        .animation(.spring(response: 0.4, dampingFraction: 0.84), value: statusKey)
        .accessibilityLabel("Connection settings")
    }

    private var statusColor: Color {
        switch coordinator.connectionState {
        case .connected: return .green
        case .searching: return .liquidAmber
        case .failed: return .liquidOrange
        case .idle: return .secondary
        }
    }

    private var statusTitle: String {
        switch coordinator.connectionState {
        case .connected:
            return coordinator.peerName.map { $0.contains(":") ? "Mac" : $0 } ?? "Mac"
        case .searching:
            return coordinator.transportMode == .direct ? "Connecting…" : "Searching…"
        case .failed:
            return "Connection issue"
        case .idle:
            return "Offline"
        }
    }
}

// MARK: - Keyboard

@available(iOS 26.0, *)
private struct LiquidKeyboardButton: View {
    @Binding var mode: KeyboardMode

    var body: some View {
        Menu {
            ForEach(KeyboardMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    Label(item.title, systemImage: item == mode ? "checkmark" : "keyboard")
                }
            }
        } label: {
            Image(systemName: mode == .off ? "keyboard" : "keyboard.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Keyboard mode")
    }
}

// MARK: - Modifier island

private enum LiquidModifier: String, CaseIterable, Identifiable {
    case command
    case shift
    case option
    case control
    case space

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .command: return "command"
        case .shift: return "shift"
        case .option: return "option"
        case .control: return "control"
        case .space: return "Space"
        }
    }

    var mask: ModifierMask {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        case .space: return .space
        }
    }
}

@available(iOS 26.0, *)
private struct LiquidModifierButton: View {
    let modifier: LiquidModifier
    @State private var pressed = false

    private var isSpace: Bool { modifier == .space }

    var body: some View {
        Group {
            if isSpace {
                Text("Space")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: modifier.symbol)
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .foregroundStyle(pressed ? Color.black : Color.white.opacity(0.86))
        .frame(width: isSpace ? 72 : 46, height: 46)
        .contentShape(isSpace ? AnyShape(Capsule()) : AnyShape(Circle()))
        .background {
            if isSpace {
                Capsule(style: .continuous)
                    .fill(pressed ? Color.liquidCyan.opacity(0.55) : Color.clear)
            } else {
                Circle()
                    .fill(pressed ? Color.liquidCyan.opacity(0.55) : Color.clear)
            }
        }
        .shadow(color: pressed ? Color.liquidCyan.opacity(0.55) : .clear, radius: 8)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in setPressed(true) }
                .onEnded { _ in setPressed(false) }
        )
        .accessibilityLabel(isSpace ? "Space" : modifier.symbol)
    }

    private func setPressed(_ value: Bool) {
        guard value != pressed else { return }
        pressed = value
        ModifierState.shared.set(modifier.mask, enabled: value)
        liquidPublishModifierState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

@MainActor
private func liquidPublishModifierState() {
    UDPClient.shared.send(VPadPacket.trackpadMove(
        dx: 0,
        dy: 0,
        modifiers: ModifierState.shared.snapshot()
    ))
}

// MARK: - Toolbar buttons

@available(iOS 26.0, *)
private struct LiquidShortcutButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 46, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(label)
    }
}

@available(iOS 26.0, *)
private struct LiquidCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

// MARK: - Radial palette

private enum LiquidRadialTool: String, CaseIterable, Identifiable {
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

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .eraser: return "Eraser"
        case .undo: return "Undo"
        }
    }
}

@available(iOS 26.0, *)
private struct LiquidRadialHUD: View {
    let namespace: Namespace.ID
    let onSelect: (LiquidRadialTool) -> Void
    let onClose: () -> Void
    @State private var selected: LiquidRadialTool = .pen

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ZStack {
                ForEach(Array(LiquidRadialTool.allCases.enumerated()), id: \.element) { index, tool in
                    Button {
                        selected = tool
                        onSelect(tool)
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(selected == tool ? Color.black : Color.primary)
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selected == tool
                            ? .regular.tint(.liquidCyan).interactive()
                            : .regular.interactive(),
                        in: .circle
                    )
                    .glassEffectID(tool.rawValue, in: namespace)
                    .offset(radialOffset(for: index))
                    .accessibilityLabel(tool.label)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close palette")
            }
            .frame(width: 190, height: 190)
        }
        .transition(.scale(scale: 0.62).combined(with: .opacity))
    }

    private func radialOffset(for index: Int) -> CGSize {
        let angle = -Double.pi / 2 + Double(index) * (2 * Double.pi / 3)
        return CGSize(width: cos(angle) * 58, height: sin(angle) * 58)
    }
}

// MARK: - Tools sheet

@available(iOS 26.0, *)
private struct LiquidToolsSheet: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var pencil: PencilProManager
    @Binding var keyboardMode: KeyboardMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Pencil Pro") {
                    Picker("Squeeze", selection: $pencil.squeezeMode) {
                        ForEach(SqueezeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(pencil.lastEventMessage ?? "Last Pencil interaction: —")
                        .font(.caption)
                        .foregroundStyle(pencil.lastEventMessage == nil ? .secondary : .primary)
                }

                Section("Keyboard") {
                    Picker("Mode", selection: $keyboardMode) {
                        ForEach(KeyboardMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Connection") {
                    LabeledContent("Transport", value: coordinator.transportMode.title)
                    if coordinator.transportMode == .direct {
                        LabeledContent("Mac IP", value: coordinator.manualHost)
                    }
                    LabeledContent(
                        "Status",
                        value: coordinator.isConnected
                            ? "Connected · \(coordinator.peerName ?? "Mac")"
                            : "Searching…"
                    )
                    if let latency = coordinator.latencyMilliseconds {
                        LabeledContent("Ping", value: String(format: "%.1f ms", latency))
                    }
                    if let error = coordinator.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Gestures") {
                    ForEach(GestureEngine.bindings) { binding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(binding.title)
                            Text(binding.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !GestureEngine.shared.patternBindings.isEmpty {
                        ForEach(GestureEngine.shared.patternBindings) { binding in
                            Text("\(binding.title): \(binding.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("File transfer") {
                    if let name = coordinator.uploadName, let progress = coordinator.uploadProgress {
                        LabeledContent(name, value: "\(Int(progress * 100))%")
                        ProgressView(value: progress)
                    }
                    if let status = coordinator.lastFileStatus {
                        LabeledContent("Last file", value: status.displayName)
                    }
                }
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Dock buttons / localized light

@available(iOS 26.0, *)
private struct PencilStatusBadge: View {
    let action: () -> Void
    @ObservedObject private var monitor = PencilStatusMonitor.shared

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let active = Date().timeIntervalSince(monitor.lastActivity) < 300
                let neverActive = monitor.lastActivity == Date.distantPast
                HStack(spacing: 6) {
                    Image(systemName: "applepencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(active ? Color.liquidCyan : Color.white.opacity(0.55))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Pencil")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(active ? "Connected" : (neverActive ? "Ready" : "Idle"))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(active ? Color.green : Color.white.opacity(0.4))
                    }
                    Circle()
                        .fill(active ? Color.green : Color.white.opacity(0.28))
                        .frame(width: 5, height: 5)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .frame(height: 46)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apple Pencil settings")
    }
}

@available(iOS 26.0, *)
private struct DockIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(DockPressStyle())
        .accessibilityLabel(label)
    }
}

private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(configuration.isPressed ? Color.liquidCyan.opacity(0.28) : Color.clear)
            )
            .shadow(
                color: configuration.isPressed ? Color.liquidCyan.opacity(0.5) : .clear,
                radius: 7
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@available(iOS 26.0, *)
private struct LiquidLocalizedBacklights: View {
    let isConnected: Bool

    private var primary: Color { isConnected ? .liquidCyan : .liquidAmber }
    private var secondary: Color { isConnected ? .liquidIndigo : .liquidOrange }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [primary.opacity(0.22), secondary.opacity(0.15)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 430, height: 58)
                    .blur(radius: 34)
                    .position(x: geo.size.width / 2, y: 38)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [secondary.opacity(0.18), primary.opacity(0.24)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 520, height: 62)
                    .blur(radius: 36)
                    .position(x: geo.size.width / 2, y: geo.size.height - 42)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Palette

private extension Color {
    static let liquidCyan = Color(red: 0.0, green: 0.90, blue: 1.0)
    static let liquidIndigo = Color(red: 0.18, green: 0.36, blue: 0.95)
    static let liquidBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let liquidAmber = Color(red: 0.96, green: 0.70, blue: 0.28)
    static let liquidOrange = Color(red: 0.95, green: 0.45, blue: 0.18)
}

private extension UIColor {
    static let liquidCyan = UIColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 1.0)
    static let liquidAmber = UIColor(red: 0.96, green: 0.70, blue: 0.28, alpha: 1.0)
}
