import SwiftUI
import VPadProtocol

struct GestureMapView: View {
    static let windowID = "gesture-map"

    @State private var actions: [UInt16: GestureAction] = [:]
    @State private var selectedID: UInt16?
    @State private var newIDText = ""
    @State private var statusMessage: String?

    @State private var kind: ActionKind = .keyMacro
    @State private var keyCodesText = ""
    @State private var activeModifiers: Set<ModifierKey> = []
    @State private var scriptPath = ""
    @State private var scriptArguments = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260)
            editor
                .frame(minWidth: 400)
        }
        .frame(minWidth: 680, minHeight: 460)
        .padding(12)
        .onAppear {
            reload()
            if selectedID == nil {
                selectedID = sortedIDs.first
            }
            loadDraft()
        }
        .onChange(of: selectedID) { _, _ in
            loadDraft()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gesture Map")
                .font(.headline)

            List(selection: $selectedID) {
                ForEach(sortedIDs, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gesture \(id)")
                        Text(summary(for: id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(id)
                }
            }
            .frame(minHeight: 280)

            HStack(spacing: 6) {
                TextField("ID", text: $newIDText)
                    .frame(width: 72)
                Button("Add") { addGesture() }
                Spacer()
            }
        }
        .padding(8)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let id = selectedID {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gesture \(id)")
                    .font(.title3.bold())

                Picker("Action", selection: $kind) {
                    ForEach(ActionKind.allCases) { actionKind in
                        Text(actionKind.title).tag(actionKind)
                    }
                }
                .pickerStyle(.segmented)

                if kind == .keyMacro {
                    keyMacroEditor
                } else {
                    scriptEditor
                }

                HStack {
                    Button("Save Changes") { saveSelected() }
                    Button("Revert") { loadDraft() }
                    Spacer()
                    Button("Delete", role: .destructive) { deleteSelected() }
                }

                Divider()

                HStack {
                    Button("Save All") { saveAll() }
                    Button("Reset Defaults") { resetDefaults() }
                    Spacer()
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            VStack {
                Spacer()
                Text("Select a gesture to edit, or add a new ID.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(8)
        }
    }

    private var keyMacroEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key codes")
                .font(.caption.bold())
            TextField("Comma-separated virtual key codes, e.g. 48, 49", text: $keyCodesText)
                .textFieldStyle(.roundedBorder)
            Text("Modifiers (applied to every stroke)")
                .font(.caption.bold())
            HStack(spacing: 14) {
                ForEach(ModifierKey.allCases) { modifier in
                    Toggle(modifier.title, isOn: modifierBinding(modifier))
                        .toggleStyle(.checkbox)
                }
            }
            Text("Example: Cmd+Tab = key code 48, Command checked. The Mac holds each key for 40 ms.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Executable path (absolute)")
                .font(.caption.bold())
            TextField("/usr/bin/osascript", text: $scriptPath)
                .textFieldStyle(.roundedBorder)
            Text("Arguments (one per line)")
                .font(.caption.bold())
            TextEditor(text: $scriptArguments)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(Color.secondary.opacity(0.3))
            Text(".scpt/.applescript runs through osascript, .sh through /bin/sh, others directly. Arguments are never shell-interpolated.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func saveSelected() {
        guard let id = selectedID else { return }

        if kind == .keyMacro {
            let codes = keyCodesText
                .split(separator: ",")
                .compactMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !codes.isEmpty else {
                statusMessage = "Enter at least one valid key code."
                return
            }
            let mask = activeModifiers.reduce(UInt16(0)) { $0 | $1.flag }
            actions[id] = .keyMacro(codes.map { KeyStroke(keyCode: $0, modifiers: mask) })
        } else {
            let path = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else {
                statusMessage = "Script path must be absolute."
                return
            }
            let arguments = scriptArguments
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            actions[id] = .runScript(path: path, arguments: arguments)
        }
        statusMessage = "Draft updated. Click Save All to persist."
    }

    private func saveAll() {
        if GestureMapper.shared.replaceAll(actions) {
            statusMessage = "Saved \(actions.count) gesture(s)."
        } else {
            statusMessage = "Failed to save gesture map."
        }
    }

    private func resetDefaults() {
        GestureMapper.shared.resetToDefaults()
        reload()
        if selectedID == nil {
            selectedID = sortedIDs.first
        }
        loadDraft()
        statusMessage = "Defaults restored."
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        actions.removeValue(forKey: id)
        selectedID = sortedIDs.first
        loadDraft()
        statusMessage = "Gesture \(id) removed. Click Save All to persist."
    }

    private func addGesture() {
        guard let id = UInt16(newIDText.trimmingCharacters(in: .whitespaces)), id > 0 else {
            statusMessage = "Enter a gesture ID between 1 and 65535."
            return
        }
        if actions[id] == nil {
            actions[id] = .keyMacro([
                KeyStroke(keyCode: VPadKeycode.tab, modifiers: ModifierMask.command.rawValue)
            ])
            statusMessage = "Gesture \(id) added. Click Save All to persist."
        }
        selectedID = id
        newIDText = ""
        loadDraft()
    }

    // MARK: - Draft

    private func loadDraft() {
        guard let id = selectedID, let action = actions[id] else {
            kind = .keyMacro
            keyCodesText = ""
            activeModifiers = []
            scriptPath = ""
            scriptArguments = ""
            return
        }

        switch action {
        case .keyMacro(let strokes):
            kind = .keyMacro
            keyCodesText = strokes.map { String($0.keyCode) }.joined(separator: ", ")
            let mask = strokes.first?.modifiers ?? 0
            activeModifiers = Set(ModifierKey.allCases.filter { mask & $0.flag != 0 })
            scriptPath = ""
            scriptArguments = ""
        case .runScript(let path, let arguments):
            kind = .runScript
            scriptPath = path
            scriptArguments = arguments.joined(separator: "\n")
            keyCodesText = ""
            activeModifiers = []
        }
    }

    private func reload() {
        actions = GestureMapper.shared.allActions()
        if let id = selectedID, actions[id] == nil {
            selectedID = sortedIDs.first
        }
    }

    private var sortedIDs: [UInt16] {
        actions.keys.sorted()
    }

    private func summary(for id: UInt16) -> String {
        guard let action = actions[id] else { return "not configured" }
        return GestureMapper.shared.describe(action)
    }

    private func modifierBinding(_ modifier: ModifierKey) -> Binding<Bool> {
        Binding(
            get: { activeModifiers.contains(modifier) },
            set: { isOn in
                if isOn {
                    activeModifiers.insert(modifier)
                } else {
                    activeModifiers.remove(modifier)
                }
            }
        )
    }
}

// MARK: - Local UI enums

private enum ActionKind: String, CaseIterable, Identifiable {
    case keyMacro
    case runScript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyMacro: return "Key Macro"
        case .runScript: return "Script"
        }
    }
}

private enum ModifierKey: String, CaseIterable, Identifiable {
    case command
    case shift
    case option
    case control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: return "Command"
        case .shift: return "Shift"
        case .option: return "Option"
        case .control: return "Control"
        }
    }

    var flag: UInt16 {
        switch self {
        case .command: return ModifierMask.command.rawValue
        case .shift: return ModifierMask.shift.rawValue
        case .option: return ModifierMask.option.rawValue
        case .control: return ModifierMask.control.rawValue
        }
    }
}
