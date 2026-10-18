import UIKit

/// A short-lived glowing cyan trail drawn under the Pencil. Points are appended
/// in view coordinates; the path fades out 0.8 s after the last point.
@MainActor
final class TransientInkLayer: CAShapeLayer {
    private static let maxPoints = 600
    private var points: [CGPoint] = []
    private var fadeTask: Task<Void, Never>?

    override init() {
        super.init()
        fillColor = nil
        strokeColor = UIColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0).cgColor
        lineWidth = 3
        lineCap = .round
        lineJoin = .round
        shadowColor = UIColor.cyan.cgColor
        shadowOpacity = 0.8
        shadowRadius = 4
        shadowOffset = .zero
        isGeometryFlipped = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// CoreAnimation clones the layer for presentation/animation; without this
    /// override it raises "Use of unimplemented initializer 'init(layer:)'" on
    /// the first animated stroke.
    override init(layer: Any) {
        super.init(layer: layer)
    }

    func beginStroke() {
        fadeTask?.cancel()
        fadeTask = nil
        removeAnimation(forKey: "fade")
        opacity = 1
        points.removeAll(keepingCapacity: true)
        path = nil
    }

    func append(_ point: CGPoint) {
        points.append(point)
        if points.count > Self.maxPoints {
            points.removeFirst(points.count - Self.maxPoints)
        }
        updatePath()
        scheduleFade()
    }

    func endStroke() {
        scheduleFade()
    }

    func clearNow() {
        fadeTask?.cancel()
        fadeTask = nil
        points.removeAll()
        path = nil
        opacity = 1
        removeAnimation(forKey: "fade")
    }

    private func updatePath() {
        guard let first = points.first else {
            path = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bezier = UIBezierPath()
        bezier.move(to: first)

        if points.count == 2 {
            bezier.addLine(to: points[1])
        } else if points.count > 2 {
            // Quadratic segments through midpoints: the curve stays smooth
            // without overshooting the captured Pencil samples.
            for index in 1..<(points.count - 1) {
                let current = points[index]
                let next = points[index + 1]
                let midpoint = CGPoint(
                    x: (current.x + next.x) / 2,
                    y: (current.y + next.y) / 2
                )
                bezier.addQuadCurve(to: midpoint, controlPoint: current)
            }
            bezier.addLine(to: points[points.count - 1])
        }

        path = bezier.cgPath
        opacity = 1
        removeAnimation(forKey: "fade")
        CATransaction.commit()
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.fadeOut()
        }
    }

    private func fadeOut() {
        guard !points.isEmpty else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.8
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        opacity = 0
        add(animation, forKey: "fade")

        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(820))
            guard !Task.isCancelled, let self else { return }
            self.points.removeAll()
            self.path = nil
            self.opacity = 1
            self.removeAnimation(forKey: "fade")
        }
    }
}
