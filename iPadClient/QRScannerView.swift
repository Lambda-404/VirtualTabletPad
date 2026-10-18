import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraScanner(onCode: { code in
                onCode(code)
                dismiss()
            }, onError: { message in
                error = message
            })
            .ignoresSafeArea()

            VStack {
                HStack {
                    Text("Scan Mac QR")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                .padding(20)
                Spacer()
                if let error {
                    Text(error)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.65)))
                        .padding(.bottom, 40)
                } else {
                    Text("Point the camera at the Mac's Pair iPad QR code")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.55)))
                        .padding(.bottom, 40)
                }
            }
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerController {
        let controller = CameraScannerController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraScannerController, context: Context) {}
}

private final class CameraScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasDelivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() }
                    else { self?.onError?("Camera access is required to scan the pairing QR.") }
                }
            }
        default:
            onError?("Camera access is disabled. Enable it in Settings → VirtualTabletPad → Camera.")
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onError?("No camera is available on this device.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("Unable to read QR codes.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview
        session.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDelivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else {
            return
        }
        hasDelivered = true
        session.stopRunning()
        onCode?(value)
    }
}
