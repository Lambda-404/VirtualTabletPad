import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

private struct PairingPayload: Codable {
    let version: Int
    let name: String
    let host: String
    let tcpPort: UInt16
    let udpPort: UInt16
}

struct PairingView: View {
    @State private var addresses: [String] = []
    @State private var selectedHost: String = ""
    @State private var qrImage: NSImage?

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair iPad")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("On the iPad: Settings → Connection → Scan Mac QR")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.white))
            } else {
                ProgressView()
                    .frame(width: 260, height: 260)
            }

            VStack(spacing: 4) {
                Text("Mac: \(Host.current().localizedName ?? "Mac")")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Address: \(selectedHost.isEmpty ? "no Wi-Fi address" : selectedHost)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("TCP 8889 · UDP 8888 · E2EE X25519/AES-GCM")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if addresses.count > 1 {
                Picker("Address", selection: $selectedHost) {
                    ForEach(addresses, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .onChange(of: selectedHost) { _, _ in rebuild() }
            }

            Button("Refresh") {
                load()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .padding(28)
        .frame(minWidth: 380, minHeight: 560)
        .onAppear { load() }
    }

    private func load() {
        addresses = localIPv4Addresses()
        if !addresses.contains(selectedHost) {
            selectedHost = addresses.first ?? ""
        }
        rebuild()
    }

    private func rebuild() {
        guard !selectedHost.isEmpty else {
            qrImage = nil
            return
        }
        let payload = PairingPayload(
            version: 1,
            name: Host.current().localizedName ?? "Mac",
            host: selectedHost,
            tcpPort: 8889,
            udpPort: 8888
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8),
              let image = makeQRCode(string) else {
            qrImage = nil
            return
        }
        qrImage = image
    }

    private func makeQRCode(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        address,
                        socklen_t(address.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        let ip = String(decoding: bytes, as: UTF8.self)
                        if !ip.hasPrefix("169.254."), !ip.hasPrefix("127.") {
                            result.append(ip)
                        }
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return Array(NSOrderedSet(array: result)) as? [String] ?? result
    }
}
