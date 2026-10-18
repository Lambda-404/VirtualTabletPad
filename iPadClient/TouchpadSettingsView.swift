import SwiftUI

struct TouchpadSettingsView: View {
    @ObservedObject var store: TouchpadSettingsStore
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TouchpadSettings
    @State private var showHelp = false

    init(store: TouchpadSettingsStore = .shared, embedded: Bool = false) {
        self.store = store
        self.embedded = embedded
        _draft = State(initialValue: store.settings)
    }

    var body: some View {
        Group {
            if embedded {
                ScrollView {
                    touchpadContent
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            } else {
                ZStack {
                    Color(red: 0.055, green: 0.055, blue: 0.062)
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        header
                        ScrollView {
                            touchpadContent
                                .padding(.horizontal, 28)
                                .padding(.top, 8)
                                .padding(.bottom, 40)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: draft) { _, next in
            store.update(next)
        }
        .alert("Touchpad Settings", isPresented: $showHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("These settings are applied on the iPad before movement is encrypted and sent to the Mac. Changes are live while you drag a slider.")
        }
    }

    private var touchpadContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            quickPresets
            motionCurve
            feel
            drag
            scrollAndZoom
            appearance
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Touchpad settings help")

            Spacer()

            Text("Touchpad Settings")
                .font(.system(size: 23, weight: .bold, design: .rounded))

            Spacer()

            Button("Reset") {
                draft = .balanced
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)

            Button("Done") {
                dismiss()
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var quickPresets: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Quick Presets")
            HStack(spacing: 12) {
                ForEach([TouchpadPreset.precise, .balanced, .swift]) { preset in
                    presetCard(preset)
                }
            }
            Text("You can fine-tune the sliders below after choosing a preset.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func presetCard(_ preset: TouchpadPreset) -> some View {
        let selected = draft.preset == preset
        return Button {
            draft = draft.applying(preset)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(height: 25)
                Text(preset.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(preset.subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.075))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color.blue.opacity(0.9) : Color.white.opacity(0.07), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    private var motionCurve: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Motion Curve")
            settingCard {
                sliderRow(
                    title: "Pointer Speed",
                    value: $draft.pointerSpeed,
                    range: 0.5...2.5,
                    step: 0.01,
                    valueText: String(format: "%.2fx", draft.pointerSpeed),
                    description: "Overall movement scale. Increase it for speed or reduce it for control."
                )
                divider
                sliderRow(
                    title: "Acceleration",
                    value: $draft.acceleration,
                    range: 0...2.5,
                    step: 0.01,
                    valueText: String(format: "%.2fx", draft.acceleration),
                    description: "Extra gain during fast swipes, useful when moving across screens."
                )
                divider
                sliderRow(
                    title: "Slow Precision",
                    value: $draft.slowPrecision,
                    range: 0...2,
                    step: 0.01,
                    valueText: String(format: "%.2fx", draft.slowPrecision),
                    description: "Higher values make slow movements more precise for small targets."
                )
            }
        }
    }

    private var feel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Feel")
            settingCard {
                sliderRow(
                    title: "Jitter Filter",
                    value: $draft.jitterFilter,
                    range: 0...1,
                    step: 0.01,
                    valueText: String(format: "%.2fx", draft.jitterFilter),
                    description: "Reduces tiny finger tremors; high values can make very slow motion less responsive."
                )
                divider
                sliderRow(
                    title: "Smoothing",
                    value: $draft.smoothing,
                    range: 0...1,
                    step: 0.01,
                    valueText: String(format: "%.2fx", draft.smoothing),
                    description: "Higher is steadier; lower follows your finger more closely."
                )
                divider
                sliderRow(
                    title: "Stop Smoothing",
                    value: $draft.stopSmoothing,
                    range: 0...1,
                    step: 0.01,
                    valueText: String(format: "%.2fx", draft.stopSmoothing),
                    description: "A short decay after lifting your finger; 0 disables the trailing motion."
                )
            }
        }
    }

    private var drag: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Drag")
            settingCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hold to drag")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("Keep one finger still to press and drag, like Sofatap and Touchpad.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $draft.holdToDrag)
                        .labelsHidden()
                        .tint(.blue)
                }
                divider
                sliderRow(
                    title: "Drag Delay",
                    value: $draft.dragDelay,
                    range: 0.15...0.8,
                    step: 0.05,
                    valueText: String(format: "%.2fs", draft.dragDelay),
                    description: "How long to hold before the left button is pressed for dragging."
                )
            }
        }
    }

    private var scrollAndZoom: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Scroll & Zoom")
            settingCard {
                sliderRow(
                    title: "Scroll Sensitivity",
                    value: $draft.scrollSensitivity,
                    range: 0.2...2,
                    step: 0.01,
                    valueText: "\(Int((draft.scrollSensitivity * 100).rounded()))%",
                    description: "Adjust how far content moves when you scroll with two fingers."
                )
                divider
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Natural scrolling")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("Content follows your two-finger movement.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { draft.naturalScrolling },
                        set: { draft.naturalScrolling = $0; draft.preset = .custom }
                    ))
                    .labelsHidden()
                    .tint(.blue)
                }
            }
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Appearance")
            settingCard {
                toggleRow(
                    title: "Show touch indicator",
                    description: "Draw a faint cyan dot under your finger.",
                    isOn: $draft.showTouchIndicator
                )
                divider
                toggleRow(
                    title: "Haptic feedback",
                    description: "A light tap when a click or right-click is sent.",
                    isOn: $draft.hapticFeedback
                )
            }
        }
    }

    // MARK: - Building blocks

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
    }

    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text(valueText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { newValue in
                    value.wrappedValue = newValue
                    draft.preset = .custom
                }
            ), in: range, step: step)
            .tint(.blue)
            Text(description)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(description)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.blue)
        }
    }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.08))
    }
}
