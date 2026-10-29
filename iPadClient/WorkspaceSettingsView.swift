import SwiftUI
import VPadProtocol

enum SettingsSection: String, CaseIterable, Identifiable {
    case touchpad
    case pencil
    case profiles
    case functionKeys
    case connection
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .touchpad: return "Touchpad"
        case .pencil: return "Pencil"
        case .profiles: return "Profiles"
        case .functionKeys: return "Function Keys"
        case .connection: return "Connection"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .touchpad: return "hand.point.up.left"
        case .pencil: return "pencil.tip"
        case .profiles: return "slider.horizontal.2.square"
        case .functionKeys: return "function"
        case .connection: return "network"
        case .about: return "info.circle"
        }
    }
}

struct WorkspaceSettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var pencil: PencilProManager
    @ObservedObject private var pencilInputStore = PencilSettingsStore.shared
    @ObservedObject private var pairingStore = PairingProfileStore.shared
    @ObservedObject private var guidedAccess = GuidedAccessMonitor.shared
    @Binding var keyboardMode: KeyboardMode
    @Environment(\.dismiss) private var dismiss

    @State private var selection: SettingsSection
    @State private var showFunctionPad = false
    @State private var mode: TransportMode
    @State private var host: String
    @State private var showQRScanner = false
    @State private var scanError: String?

    init(
        coordinator: SessionCoordinator,
        pencil: PencilProManager,
        keyboardMode: Binding<KeyboardMode>,
        initialSection: SettingsSection = .touchpad
    ) {
        self.coordinator = coordinator
        self.pencil = pencil
        _keyboardMode = keyboardMode
        _selection = State(initialValue: initialSection)
        _mode = State(initialValue: coordinator.transportMode)
        _host = State(initialValue: coordinator.manualHost)
    }

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.062).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                sectionPicker
                Divider().overlay(Color.white.opacity(0.08))
                detail
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: coordinator.transportMode) { _, next in mode = next }
        .onChange(of: coordinator.manualHost) { _, next in
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host = next }
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Spacer()
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = section }
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(selection == section ? Color.black : Color.white.opacity(0.75))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selection == section ? Color.white : Color.white.opacity(0.075))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .touchpad:
            TouchpadSettingsView(embedded: true)
        case .pencil:
            pencilSettings
        case .profiles:
            profilesSettings
        case .functionKeys:
            functionSettings
        case .connection:
            connectionSettings
        case .about:
            aboutSettings
        }
    }

    private var pencilSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gesture Engine")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                gestureEngineCard

                Text("Pencil Feel")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Stabilization")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Spacer()
                        Text(stabilizationLabel)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: stabilizationBinding, in: 0...1, step: 0.05)
                        .tint(.blue)

                    HStack {
                        Text("Direct")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Smooth")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Text("0% follows the Pencil tip directly (most sensitive). Higher values smooth hand tremor and round the trace, but add a little lag.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        ForEach(PencilStabilizationPreset.allCases) { preset in
                            let selected = abs(pencilInputStore.settings.stabilization - preset.value) < 0.001
                            Button {
                                var next = pencilInputStore.settings
                                next.stabilization = preset.value
                                pencilInputStore.update(next)
                            } label: {
                                Text(preset.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.78))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? Color.white : Color.white.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 4)
                        Button("Reset") {
                            var next = pencilInputStore.settings
                            next.stabilization = PencilInputSettings.defaultStabilization
                            pencilInputStore.update(next)
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.075))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.065), lineWidth: 1)
                )

                Text("Pencil Pro")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Picker("Squeeze action", selection: $pencil.squeezeMode) {
                    ForEach(SqueezeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                if pencil.squeezeMode == .customAction {
                    Picker("Squeeze Binding", selection: $pencil.gestureBindings.squeezeAction) {
                        Text("Escape").tag(Action.key(KeyCombo(keyCode: 53)))
                        Text("Space / Pan").tag(Action.key(KeyCombo(keyCode: 49)))
                        Text("Undo (⌘Z)").tag(Action.key(KeyCombo(keyCode: 6, modifiers: 0x0100)))
                        Text("Eraser").tag(Action.toggleTool("eraser"))
                        Text("Play / Pause").tag(Action.systemAction(.playPause))
                    }
                }

                Picker("Double-tap", selection: $pencil.gestureBindings.doubleTapAction) {
                    Text("Eraser").tag(Action.toggleTool("eraser"))
                    Text("Brush").tag(Action.toggleTool("brush"))
                    Text("Undo (⌘Z)").tag(Action.key(KeyCombo(keyCode: 6, modifiers: 0x0100)))
                    Text("Space / Pan").tag(Action.key(KeyCombo(keyCode: 49)))
                    Text("Tab").tag(Action.key(KeyCombo(keyCode: 48)))
                }

                Text(pencil.lastEventMessage ?? "Last Pencil interaction: —")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)

                PressureCurveEditorView(config: Binding(
                    get: { pencilInputStore.settings.pressureCurveConfig },
                    set: { value in
                        var next = pencilInputStore.settings
                        next.pressureCurveConfig = value
                        pencilInputStore.update(next)
                    }
                ))

                Toggle("Pen-only input (palm rejection)", isOn: Binding(
                    get: { pencilInputStore.settings.penOnly },
                    set: { value in
                        var next = pencilInputStore.settings
                        next.penOnly = value
                        pencilInputStore.update(next)
                    }
                ))
                .font(.system(size: 13, design: .rounded))

                Divider().overlay(Color.white.opacity(0.08))
                Text("Keyboard").font(.system(size: 18, weight: .semibold, design: .rounded))
                Picker("Keyboard mode", selection: $keyboardMode) {
                    ForEach(KeyboardMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider().overlay(Color.white.opacity(0.08))
                Text("Gestures").font(.system(size: 18, weight: .semibold, design: .rounded))
                ForEach(GestureEngine.bindings) { binding in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(binding.title).font(.system(size: 13, design: .rounded))
                        Text(binding.detail)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(GestureEngine.shared.patternBindings) { binding in
                    Text("\(binding.title): \(binding.detail)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var gestureEngineStatus: String {
        switch guidedAccess.preference {
        case .automatic:
            return "Auto · Guided Access \(guidedAccess.isSystemGuidedAccessEnabled ? "ON" : "OFF")"
        case .native:
            return "Manual · Full"
        case .safe:
            return "Manual · Safe"
        }
    }

    private var gestureEngineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mode")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text(gestureEngineStatus)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(guidedAccess.isEnabled ? Color.green : Color.orange)
            }

            Picker("Gesture engine", selection: Binding(
                get: { guidedAccess.preference },
                set: { guidedAccess.setPreference($0) }
            )) {
                ForEach(GestureModePreference.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(guidedAccess.preference.detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)

            if guidedAccess.preference == .native,
               !guidedAccess.isSystemGuidedAccessEnabled {
                Text("Manual Full only changes this app's gesture engine. iPadOS still owns 4/5-finger and screen-edge gestures; enable real Guided Access for a conflict-free test.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                guidedAccess.isEnabled
                    ? "Full 1–5 finger gestures: three-finger drag, four-finger Mission Control/App Exposé/Spaces, five-finger Launchpad/Show Desktop."
                    : "Safe gestures: 3-finger movement and 4/5-finger gestures are suppressed. Use Fn/Drag at the lower-left and the corner buttons."
            )
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private var stabilizationBinding: Binding<Double> {
        Binding(
            get: { pencilInputStore.settings.stabilization },
            set: { value in
                var next = pencilInputStore.settings
                next.stabilization = value
                pencilInputStore.update(next)
            }
        )
    }

    private var stabilizationLabel: String {
        let percent = Int((pencilInputStore.settings.stabilization * 100).rounded())
        return "\(percent)%"
    }

    private var functionSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Function Keys")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("F1–F12, brightness, Mission Control, desktop switching, Launchpad and media keys.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                Button {
                    showFunctionPad = true
                } label: {
                    Label("Open Function Pad", systemImage: "function")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Text("F1–F12 send standard macOS function keys. Brightness and media use system-defined NX events; Mission Control and desktop switching use the standard Ctrl+arrow shortcuts.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .sheet(isPresented: $showFunctionPad) {
            FunctionPadView(coordinator: coordinator)
                .presentationDetents([.height(360), .medium, .large])
                .presentationBackground(Color(red: 0.055, green: 0.055, blue: 0.062))
        }
    }

    private var connectionSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Paired Mac")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pairingStore.profile?.name ?? "No paired Mac")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(pairingStore.profile?.host ?? "Scan the Pair iPad QR code on the Mac.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Scan QR") { showQRScanner = true }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .buttonStyle(.plain)
                    if pairingStore.profile != nil {
                        Button("Forget") {
                            pairingStore.clear()
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.red.opacity(0.8))
                        .buttonStyle(.plain)
                    }
                }

                if let scanError {
                    Text(scanError)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                }

                Divider().overlay(Color.white.opacity(0.08))

                Text("Transport")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Picker("Transport", selection: $mode) {
                    ForEach(TransportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Text(mode.detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)

                if mode == .direct {
                    TextField("Mac IP", text: $host)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.075)))
                }

                Button {
                    coordinator.applyConnection(mode: mode, host: host)
                } label: {
                    Text(coordinator.isConnected ? "Reconnect" : "Connect")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(mode == .direct && host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Status", value: statusText)
                    if let latency = coordinator.latencyMilliseconds {
                        LabeledContent("Ping", value: String(format: "%.1f ms", latency))
                    }
                    if let error = coordinator.lastError {
                        Text(error)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 13, design: .rounded))

                Text("USB Cable is a raw usbmuxd tunnel. Cable/Direct IP is a fallback for USB-C Ethernet or hotspot links.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { code in
                guard let profile = pairingStore.decode(code) else {
                    scanError = "That QR code is not a VirtualTabletPad pairing code."
                    return
                }
                scanError = nil
                pairingStore.save(profile)
                mode = .direct
                host = profile.host
                coordinator.applyConnection(mode: .direct, host: profile.host)
            }
        }
    }

    private var statusText: String {
        switch coordinator.connectionState {
        case .active: return "Connected"
        case .handshaking: return "Authenticating…"
        case .connecting: return "Searching…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Offline"
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) · Build \(build)"
    }

    private var profilesSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.activeProfile.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        if let bundleID = coordinator.activeAppBundleID {
                            Text(bundleID)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )

                Text("Application Profiles").font(.system(size: 18, weight: .semibold, design: .rounded))

                ForEach(coordinator.profileStore.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                            Text(profile.bundleIdentifier)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(profile.pressureCurve.preset.title)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .padding(.vertical, 6)
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aboutSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("VirtualTabletPad")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(appVersionText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("macOS Host + iPad Client · E2EE X25519 + AES-GCM-256")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("USB Cable uses a raw usbmuxd TCP tunnel — no Wi-Fi, IP or external NIC.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PressureCurveEditorView: View {
    @Binding var config: PressureCurveConfiguration

    var body: some View {
        VStack(spacing: 10) {
            Picker("Curve Preset", selection: Binding(
                get: { config.preset },
                set: { config.selectPreset($0) }
            )) {
                ForEach(PressureCurveConfiguration.Preset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )

                    // Grid lines (25%, 50%, 75%)
                    Path { path in
                        for frac in [0.25, 0.5, 0.75] {
                            let pos = size * frac
                            path.move(to: CGPoint(x: pos, y: 0))
                            path.addLine(to: CGPoint(x: pos, y: size))
                            path.move(to: CGPoint(x: 0, y: pos))
                            path.addLine(to: CGPoint(x: size, y: pos))
                        }
                    }
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)

                    // Linear identity diagonal
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size))
                        path.addLine(to: CGPoint(x: size, y: 0))
                    }
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // 256-point LUT curve
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size))
                        for i in 1..<256 {
                            let x = (CGFloat(i) / 255.0) * size
                            let y = (1.0 - CGFloat(config.lookupTable[i])) * size
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 2.5)

                    // Control point handles in custom mode
                    if config.preset == .custom {
                        let cp1 = CGPoint(x: config.controlPoint1.x * size, y: (1.0 - config.controlPoint1.y) * size)
                        let cp2 = CGPoint(x: config.controlPoint2.x * size, y: (1.0 - config.controlPoint2.y) * size)

                        Circle()
                            .fill(Color.orange)
                            .frame(width: 14, height: 14)
                            .position(cp1)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let nx = min(max(value.location.x / size, 0), 1)
                                        let ny = min(max(1.0 - value.location.y / size, 0), 1)
                                        config.updateControlPoints(p1: CGPoint(x: nx, y: ny), p2: config.controlPoint2)
                                    }
                            )

                        Circle()
                            .fill(Color.orange)
                            .frame(width: 14, height: 14)
                            .position(cp2)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let nx = min(max(value.location.x / size, 0), 1)
                                        let ny = min(max(1.0 - value.location.y / size, 0), 1)
                                        config.updateControlPoints(p1: config.controlPoint1, p2: CGPoint(x: nx, y: ny))
                                    }
                            )
                    }
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 140)
        }
    }
}
