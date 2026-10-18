import SwiftUI

/// Connection-mode editor shared by the Liquid Glass workspace and the legacy
/// iPadOS 17 fallback. Direct mode is what makes a cable/Ethernet setup usable:
/// Bonjour is skipped and both TCP and UDP target the Mac's IP explicitly.
struct ConnectionSettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var mode: TransportMode
    @State private var host: String

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        let configured = coordinator.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = coordinator.remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usableDetected = detected.contains(".") && !detected.contains(":") ? detected : ""
        _mode = State(initialValue: coordinator.transportMode)
        _host = State(initialValue: configured.isEmpty ? usableDetected : configured)
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Transport", selection: $mode) {
                        ForEach(TransportMode.allCases) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    .pickerStyle(.inline)

                    Text(mode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Connection")
                }

                if mode == .direct {
                    Section {
                        TextField("Mac IP, e.g. 192.168.2.1", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .font(.body.monospaced())
                        if let detected = coordinator.remoteHost,
                           detected.contains("."), !detected.contains(":"),
                           detected != host {
                            HStack {
                                Text("Detected: \(detected)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Use") { host = detected }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Mac address")
                    } footer: {
                        Text("Open VirtualTabletPad's menu on the Mac and use “Copy …” under Cable / direct IP. The ports are fixed: TCP 8889 and UDP 8888.")
                    }

                    Section {
                        Text("Plug in a USB-C cable: the app auto-detects the Mac's USB link-local address and switches to Cable mode; no Wi-Fi is required. If auto-detection is unavailable, enter the Mac IP shown in its menu.")
                            .font(.footnote)
                        Label("Direct USB-C cable · auto-detected", systemImage: "cable.connector")
                        Label("iPad Personal Hotspot over USB", systemImage: "personalhotspot")
                        Label("USB-C Ethernet adapter on both ends", systemImage: "network")
                    } header: {
                        Text("Cable setup")
                    }
                }

                Section {
                    Button {
                        coordinator.applyConnection(mode: mode, host: host)
                        dismiss()
                    } label: {
                        Label(
                            coordinator.isConnected ? "Reconnect" : "Connect",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(mode == .direct && trimmedHost.isEmpty)
                }

                Section("Live status") {
                    LabeledContent("Transport", value: coordinator.transportMode.title)
                    if coordinator.transportMode == .direct {
                        LabeledContent("Mac IP", value: coordinator.manualHost)
                    }
                    switch coordinator.connectionState {
                    case .connected:
                        LabeledContent("Link", value: coordinator.peerName ?? "Connected")
                    case .searching:
                        LabeledContent("Link", value: "Searching…")
                    case .failed(let message):
                        LabeledContent("Link", value: message)
                    case .idle:
                        LabeledContent("Link", value: "Idle")
                    }
                    if let latency = coordinator.latencyMilliseconds {
                        LabeledContent("Ping", value: String(format: "%.1f ms", latency))
                    }
                    if let error = coordinator.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .onAppear {
            mode = coordinator.transportMode
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                host = coordinator.manualHost
            }
        }
        .onChange(of: coordinator.transportMode) { _, next in
            mode = next
        }
        .onChange(of: coordinator.manualHost) { _, next in
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                host = next
            }
        }
    }
}
