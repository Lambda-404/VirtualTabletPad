import SwiftUI
import UIKit
import VPadProtocol

enum FunctionKey: Int, CaseIterable, Identifiable {
    case f1 = 1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    var id: Int { rawValue }
    var title: String { "F\(rawValue)" }

    /// macOS virtual keycodes for F1…F12.
    var virtualKeyCode: UInt16 {
        switch self {
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        }
    }

    var modifierMask: ModifierMask { [] }
}

struct FunctionPadView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.062).ignoresSafeArea()
            VStack(spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(FunctionKey.allCases) { key in
                        functionButton(key)
                    }
                }
                Text("System Keys")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                    systemButton(.brightnessDown, title: "Brightness −", symbol: "sun.min")
                    systemButton(.brightnessUp, title: "Brightness +", symbol: "sun.max")
                    systemButton(.missionControl, title: "All Windows", symbol: "rectangle.3.group")
                    systemButton(.appExpose, title: "App Windows", symbol: "rectangle.on.rectangle")
                    systemButton(.desktopLeft, title: "Desktop ←", symbol: "chevron.left.2")
                    systemButton(.desktopRight, title: "Desktop →", symbol: "chevron.right.2")
                    systemButton(.launchpad, title: "Launchpad", symbol: "square.grid.3x3")
                    systemButton(.playPause, title: "Play/Pause", symbol: "playpause")
                    systemButton(.nextTrack, title: "Next", symbol: "forward.end")
                    systemButton(.previousTrack, title: "Previous", symbol: "backward.end")
                    systemButton(.volumeDown, title: "Volume −", symbol: "speaker.minus")
                    systemButton(.volumeUp, title: "Volume +", symbol: "speaker.plus")
                }
                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Function Keys")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Spacer()
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
    }

    private func functionButton(_ key: FunctionKey) -> some View {
        let customAction = coordinator.actionForFunctionKey(key)
        return Button {
            if let customAction {
                coordinator.executeAction(customAction)
            } else {
                coordinator.sendFunctionKey(key)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 2) {
                Text(key.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if let customAction {
                    Text(customAction.title)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.085))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func systemButton(_ action: SystemAction, title: String, symbol: String) -> some View {
        Button {
            coordinator.sendSystemAction(action)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.075))
                )
        }
        .buttonStyle(.plain)
    }
}
