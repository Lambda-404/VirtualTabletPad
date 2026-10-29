import Combine
import UIKit
import VPadProtocol

enum SqueezeMode: String, CaseIterable, Identifiable {
    case macRightClick
    case radialPalette
    case customAction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macRightClick: return "Mac Right-Click"
        case .radialPalette: return "Radial Palette"
        case .customAction: return "Custom Action"
        }
    }
}

/// Owns the Pencil Pro interaction, haptics and squeeze routing.
@MainActor
final class PencilProManager: NSObject, ObservableObject, UIPencilInteractionDelegate {
    @Published var squeezeMode: SqueezeMode = .macRightClick
    @Published var gestureBindings: PencilGestureBindings = PencilGestureBindings()
    @Published var radialMenuCenter: CGPoint?
    @Published private(set) var lastEventMessage: String?

    private weak var canvas: HybridCanvasView?
    private var interaction: UIPencilInteraction?
    private var feedback: UICanvasFeedbackGenerator?
    private var eventClearTask: Task<Void, Never>?

    func attach(to canvas: HybridCanvasView) {
        if let oldCanvas = self.canvas, let interaction {
            oldCanvas.removeInteraction(interaction)
        }
        self.canvas = canvas
        let interaction = UIPencilInteraction(delegate: self)
        canvas.addInteraction(interaction)
        self.interaction = interaction
        feedback = UICanvasFeedbackGenerator(view: canvas)
        radialMenuCenter = nil
        NSLog(
            "VPAD_PENCIL attached tapPreferred=%ld squeezePreferred=%ld",
            UIPencilInteraction.preferredTapAction.rawValue,
            UIPencilInteraction.preferredSqueezeAction.rawValue
        )
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        NSLog("VPAD_PENCIL tap")
        let location = tap.hoverPose?.location ?? .zero
        feedback?.pathCompleted(at: location)

        switch gestureBindings.doubleTapAction {
        case .toggleTool("eraser"):
            showEvent("Double-tap → Eraser (E)")
            UDPClient.shared.send(VPadPacket.stylusDoubleTap(modifiers: ModifierState.shared.snapshot()))
        default:
            showEvent("Double-tap → \(gestureBindings.doubleTapAction.title)")
            execute(gestureBindings.doubleTapAction)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        NSLog(
            "VPAD_PENCIL squeeze phase=%ld preferred=%ld",
            squeeze.phase.rawValue,
            UIPencilInteraction.preferredSqueezeAction.rawValue
        )
        guard squeeze.phase == .began else { return }
        let poseLocation = squeeze.hoverPose?.location
        let location = poseLocation ?? canvas?.centerPoint ?? .zero
        feedback?.alignmentOccurred(at: location)

        switch squeezeMode {
        case .macRightClick:
            showEvent(poseLocation == nil ? "Squeeze (no hover pose)" : "Squeeze → Mac right-click")
            guard let pose = squeeze.hoverPose,
                  let canvas,
                  let (nx, ny) = canvas.normalizedPoint(pose.location) else {
                return
            }
            UDPClient.shared.send(VPadPacket.stylusSqueeze(
                x: nx,
                y: ny,
                rollAngle: Float32(pose.rollAngle),
                modifiers: ModifierState.shared.snapshot()
            ))
        case .radialPalette:
            showEvent("Squeeze → Radial palette")
            radialMenuCenter = location
        case .customAction:
            showEvent("Squeeze → \(gestureBindings.squeezeAction.title)")
            execute(gestureBindings.squeezeAction)
        }
    }

    private func execute(_ action: Action) {
        switch action {
        case .key(let combo):
            UDPClient.shared.send(VPadPacket.keyShortcut(keyCode: combo.keyCode, modifiers: combo.modifiers))
        case .systemAction(let sys):
            UDPClient.shared.send(VPadPacket.systemAction(sys))
        case .macro(let steps):
            Task { @MainActor in
                for step in steps {
                    switch step {
                    case .keyDown(let code, let mods):
                        UDPClient.shared.send(VPadPacket.keyboardPress(keyCode: code, phase: .began, modifiers: mods))
                    case .keyUp(let code):
                        UDPClient.shared.send(VPadPacket.keyboardPress(keyCode: code, phase: .ended, modifiers: 0))
                    case .delayMs(let ms):
                        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    }
                }
            }
        case .toggleTool(let tool):
            if tool.lowercased() == "eraser" {
                UDPClient.shared.send(VPadPacket.stylusDoubleTap(modifiers: ModifierState.shared.snapshot()))
            } else if tool.lowercased() == "brush" {
                UDPClient.shared.send(VPadPacket.keyShortcut(keyCode: 11, modifiers: 0))
            }
        }
    }

    private func showEvent(_ message: String) {
        lastEventMessage = message
        eventClearTask?.cancel()
        eventClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.lastEventMessage = nil
        }
    }
}
