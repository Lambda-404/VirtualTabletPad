import SwiftUI
import AppKit
import VPadProtocol

@MainActor
final class AreaMappingViewModel: ObservableObject {
    static let shared = AreaMappingViewModel()
    private let userDefaultsKey = "vpad.areaMapping.config"

    @Published var config: AreaMappingConfiguration {
        didSet {
            save()
            EventInjector.shared.areaMapping = config
        }
    }

    struct ScreenInfo: Identifiable, Hashable {
        let id: UInt32
        let name: String
        let resolution: String
        let frame: CGRect
    }

    @Published var availableScreens: [ScreenInfo] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode(AreaMappingConfiguration.self, from: data) {
            self.config = saved
        } else {
            self.config = AreaMappingConfiguration()
        }
        refreshScreens()
        EventInjector.shared.areaMapping = config
    }

    func refreshScreens() {
        availableScreens = NSScreen.screens.enumerated().map { index, screen in
            let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(index + 1)
            let name = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
            let res = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
            return ScreenInfo(id: screenNumber, name: name, resolution: res, frame: screen.frame)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}

struct AreaMappingView: View {
    static let windowID = "area-mapping"
    @StateObject private var viewModel = AreaMappingViewModel.shared

    var body: some View {
        VStack(spacing: 16) {
            // Visual Preview
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                GeometryReader { geo in
                    let screenBounds = currentScreenBounds()
                    let aspect = screenBounds.width > 0 && screenBounds.height > 0
                        ? screenBounds.width / screenBounds.height
                        : 16.0 / 9.0
                    let previewWidth = min(geo.size.width - 32, (geo.size.height - 32) * aspect)
                    let previewHeight = previewWidth / aspect

                    ZStack {
                        // Display Box
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1.5)
                            )
                            .frame(width: previewWidth, height: previewHeight)

                        // Mapped Area Box
                        let activeRect = computePreviewActiveRect(width: previewWidth, height: previewHeight)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            )
                            .frame(width: activeRect.width, height: activeRect.height)
                            .position(x: activeRect.midX, y: activeRect.midY)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 180)

            // Form Controls
            Form {
                Picker("Display", selection: Binding(
                    get: { viewModel.config.targetDisplayID ?? 0 },
                    set: { viewModel.config.targetDisplayID = ($0 == 0) ? nil : $0 }
                )) {
                    Text("Main Display").tag(UInt32(0))
                    ForEach(viewModel.availableScreens) { screen in
                        Text("\(screen.name) (\(screen.resolution))").tag(screen.id)
                    }
                }

                Picker("Orientation", selection: $viewModel.config.rotation) {
                    Text("0°").tag(TabletRotation.rotation0)
                    Text("90°").tag(TabletRotation.rotation90)
                    Text("180°").tag(TabletRotation.rotation180)
                    Text("270°").tag(TabletRotation.rotation270)
                }
                .pickerStyle(.segmented)

                Toggle("Lock Aspect Ratio (4:3)", isOn: $viewModel.config.lockAspectRatio)

                Toggle("Left-Handed Mode", isOn: $viewModel.config.isLeftHanded)
            }
            .padding(.horizontal, 8)

            Spacer()

            HStack {
                Button("Reset Defaults") {
                    viewModel.config = AreaMappingConfiguration()
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
        .onAppear {
            viewModel.refreshScreens()
        }
    }

    private func currentScreenBounds() -> CGRect {
        if let targetID = viewModel.config.targetDisplayID,
           let screen = viewModel.availableScreens.first(where: { $0.id == targetID }) {
            return screen.frame
        }
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    private func computePreviewActiveRect(width: CGFloat, height: CGFloat) -> CGRect {
        let dummyDisplay = CGRect(x: 0, y: 0, width: width, height: height)
        let p0 = viewModel.config.map(normalizedX: 0, normalizedY: 0, displayBounds: dummyDisplay)
        let p1 = viewModel.config.map(normalizedX: 1, normalizedY: 1, displayBounds: dummyDisplay)
        let minX = min(p0.x, p1.x)
        let maxX = max(p0.x, p1.x)
        let minY = min(p0.y, p1.y)
        let maxY = max(p0.y, p1.y)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 10), height: max(maxY - minY, 10))
    }
}
