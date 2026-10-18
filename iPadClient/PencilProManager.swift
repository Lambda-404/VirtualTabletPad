import Combine
import UIKit
import VPadProtocol

enum SqueezeMode: String, CaseIterable, Identifiable {
    case macRightClick
    case radialPalette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macRightClick: return "Mac Right-Click HUD"
        case .radialPalette: return "Local Radial Palette"
        }
    }
}

/// Owns the Pencil Pro interaction, haptics and squeeze routing.
@MainActor
final class PencilProManager: NSObject, ObservableObject, UIPencilInteractionDelegate {
    @Published var squeezeMode: SqueezeMode = .macRightClick
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
        showEvent("Double-tap → Eraser (E)")
        let location = tap.hoverPose?.location ?? .zero
        feedback?.pathCompleted(at: location)
        UDPClient.shared.send(VPadPacket.stylusDoubleTap(modifiers: ModifierState.shared.snapshot()))
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
