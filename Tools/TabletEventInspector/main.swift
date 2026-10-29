import AppKit
import SwiftUI

// MARK: - Event Telemetry Model

struct EventLogItem: Identifiable, Sendable {
    let id = UUID()
    let timestamp: String
    let typeName: String
    let subtypeName: String
    let pressure: Double
    let tiltX: Double
    let tiltY: Double
    let rotation: Double
    let location: CGPoint
    let isProximity: Bool
    let inProximity: Bool
}

@MainActor
final class InspectorTelemetry: ObservableObject {
    @Published var lastEventName: String = "Idle"
    @Published var subtypeName: String = "None"
    @Published var pressure: Double = 0.0
    @Published var tiltX: Double = 0.0
    @Published var tiltY: Double = 0.0
    @Published var rotation: Double = 0.0
    @Published var inProximity: Bool = false
    @Published var pointerType: String = "Pen Tip"
    @Published var logs: [EventLogItem] = []
    @Published var strokePaths: [CanvasStroke] = []

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    func record(event: NSEvent) {
        let ts = dateFormatter.string(from: Date())
        let typeStr: String
        switch event.type {
        case .leftMouseDown: typeStr = "Down"
        case .leftMouseDragged: typeStr = "Drag"
        case .leftMouseUp: typeStr = "Up"
        case .mouseMoved: typeStr = "Moved"
        case .tabletPoint: typeStr = "Tablet Point"
        case .tabletProximity: typeStr = "Proximity"
        default: typeStr = "\(event.type.rawValue)"
        }

        let subStr: String
        switch event.subtype {
        case .tabletPoint: subStr = "tabletPoint"
        case .tabletProximity: subStr = "tabletProximity"
        case .touch: subStr = "touch"
        default:
            if event.subtype.rawValue == 0 {
                subStr = "default"
            } else {
                subStr = "\(event.subtype.rawValue)"
            }
        }

        let isProx = event.type == .tabletProximity || event.subtype == .tabletProximity
        if isProx {
            self.inProximity = event.isEnteringProximity
            self.pointerType = event.pointingDeviceType == .eraser ? "Eraser" : "Pen Tip"
        }

        let p = Double(event.pressure)
        let tx = Double(event.tilt.x)
        let ty = Double(event.tilt.y)
        let rot = Double(event.rotation)

        self.lastEventName = typeStr
        self.subtypeName = subStr
        self.pressure = p
        self.tiltX = tx
        self.tiltY = ty
        self.rotation = rot

        let item = EventLogItem(
            timestamp: ts,
            typeName: typeStr,
            subtypeName: subStr,
            pressure: p,
            tiltX: tx,
            tiltY: ty,
            rotation: rot,
            location: event.locationInWindow,
            isProximity: isProx,
            inProximity: self.inProximity
        )

        if logs.count >= 100 {
            logs.removeLast()
        }
        logs.insert(item, at: 0)
    }

    func clearCanvas() {
        strokePaths.removeAll()
    }

    func clearLogs() {
        logs.removeAll()
    }
}

struct CanvasStroke: Identifiable {
    let id = UUID()
    var points: [(CGPoint, Double)] // Point and pressure
}

// MARK: - Native Event Capturing View

final class TabletCanvasNSView: NSView {
    var telemetry: InspectorTelemetry?
    private var trackingAreaRef: NSTrackingArea?
    private var currentStroke: [CGPoint] = []
    private var currentPressures: [Double] = []

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingAreaRef = area
    }

    override func mouseDown(with event: NSEvent) {
        handleEvent(event)
        let point = convert(event.locationInWindow, from: nil)
        currentStroke = [point]
        currentPressures = [Double(event.pressure)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        handleEvent(event)
        let point = convert(event.locationInWindow, from: nil)
        currentStroke.append(point)
        currentPressures.append(Double(event.pressure))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        handleEvent(event)
        if !currentStroke.isEmpty, let telemetry {
            var pts: [(CGPoint, Double)] = []
            for i in 0..<currentStroke.count {
                pts.append((currentStroke[i], currentPressures[i]))
            }
            telemetry.strokePaths.append(CanvasStroke(points: pts))
        }
        currentStroke.removeAll()
        currentPressures.removeAll()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        handleEvent(event)
    }

    override func tabletPoint(with event: NSEvent) {
        handleEvent(event)
    }

    override func tabletProximity(with event: NSEvent) {
        handleEvent(event)
    }

    private func handleEvent(_ event: NSEvent) {
        telemetry?.record(event: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background grid
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        // Draw saved strokes
        if let paths = telemetry?.strokePaths {
            for stroke in paths {
                drawStroke(stroke.points, in: ctx, color: NSColor.labelColor.cgColor)
            }
        }

        // Draw live active stroke
        if !currentStroke.isEmpty {
            var activePoints: [(CGPoint, Double)] = []
            for i in 0..<currentStroke.count {
                activePoints.append((currentStroke[i], currentPressures[i]))
            }
            drawStroke(activePoints, in: ctx, color: NSColor.controlAccentColor.cgColor)
        }
    }

    private func drawStroke(_ points: [(CGPoint, Double)], in ctx: CGContext, color: CGColor) {
        guard points.count > 1 else {
            if let first = points.first {
                let r = max(1.5, CGFloat(first.1) * 8.0)
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: first.0.x - r, y: first.0.y - r, width: r * 2, height: r * 2))
            }
            return
        }

        for i in 1..<points.count {
            let p0 = points[i - 1].0
            let p1 = points[i].0
            let pr = max(1.0, CGFloat((points[i - 1].1 + points[i].1) / 2.0) * 10.0)

            ctx.setStrokeColor(color)
            ctx.setLineWidth(pr)
            ctx.setLineCap(.round)
            ctx.strokeLineSegments(between: [p0, p1])
        }
    }
}

struct TabletCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var telemetry: InspectorTelemetry

    func makeNSView(context: Context) -> TabletCanvasNSView {
        let view = TabletCanvasNSView()
        view.telemetry = telemetry
        return view
    }

    func updateNSView(_ nsView: TabletCanvasNSView, context: Context) {
        nsView.telemetry = telemetry
        nsView.needsDisplay = true
    }
}

// MARK: - SwiftUI User Interface

struct TiltGaugeView: View {
    let tiltX: Double
    let tiltY: Double

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let target = CGPoint(
                x: center.x + CGFloat(max(-1.0, min(1.0, tiltX))) * (size / 2 - 4),
                y: center.y - CGFloat(max(-1.0, min(1.0, tiltY))) * (size / 2 - 4)
            )

            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: center.y))
                    p.addLine(to: CGPoint(x: size, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: 0))
                    p.addLine(to: CGPoint(x: center.x, y: size))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

                Path { p in
                    p.move(to: center)
                    p.addLine(to: target)
                }
                .stroke(Color.accentColor, lineWidth: 2)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .position(target)
            }
        }
        .frame(width: 64, height: 64)
    }
}

struct InspectorContentView: View {
    @StateObject var telemetry = InspectorTelemetry()

    var body: some View {
        HSplitView {
            // Left: Drawing Surface
            VStack(spacing: 0) {
                HStack {
                    Label(telemetry.inProximity ? "In Proximity" : "Out of Range",
                          systemImage: telemetry.inProximity ? "antenna.radiowaves.left.and.right" : "slash.circle")
                        .font(.callout.monospaced())
                        .foregroundColor(telemetry.inProximity ? .green : .secondary)

                    Spacer()

                    Button("Clear Canvas") {
                        telemetry.clearCanvas()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                TabletCanvasRepresentable(telemetry: telemetry)
                    .frame(minWidth: 400, minHeight: 400)
            }

            // Right: Telemetry & Logs
            VStack(alignment: .leading, spacing: 12) {
                // Live Meters
                VStack(spacing: 10) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PRESSURE")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                            Text(String(format: "%.3f", telemetry.pressure))
                                .font(.system(.title3, design: .monospaced).bold())
                            ProgressView(value: telemetry.pressure, total: 1.0)
                                .tint(.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .center, spacing: 4) {
                            Text("TILT (X, Y)")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                            TiltGaugeView(tiltX: telemetry.tiltX, tiltY: telemetry.tiltY)
                            Text(String(format: "%.2f, %.2f", telemetry.tiltX, telemetry.tiltY))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .frame(width: 90)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROTATION")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f°", telemetry.rotation))
                                .font(.system(.title3, design: .monospaced).bold())
                            Text(telemetry.subtypeName)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 80, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Event Table
                HStack {
                    Text("EVENT LOG")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear") {
                        telemetry.clearLogs()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                }

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(telemetry.logs) { item in
                            HStack(spacing: 8) {
                                Text(item.timestamp)
                                    .frame(width: 80, alignment: .leading)
                                Text(item.typeName)
                                    .frame(width: 70, alignment: .leading)
                                    .foregroundColor(item.typeName == "Down" ? .green : (item.typeName == "Up" ? .orange : .primary))
                                Text(item.subtypeName)
                                    .frame(width: 90, alignment: .leading)
                                    .foregroundColor(.secondary)
                                Text(String(format: "P:%.2f", item.pressure))
                                    .frame(width: 55, alignment: .trailing)
                                Text(String(format: "T:(%.1f,%.1f)", item.tiltX, item.tiltY))
                                    .frame(width: 80, alignment: .trailing)
                                    .foregroundColor(.secondary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 420, maxWidth: 500)
        }
    }
}

// MARK: - App Delegate & Runner

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = InspectorContentView()
        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VirtualTabletPad - Tablet Event Inspector"
        win.contentView = NSHostingView(rootView: contentView)
        win.makeKeyAndOrderFront(nil)
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
