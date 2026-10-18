import Darwin
import Foundation
import os

/// Listens for the Mac's small link-local UDP beacon. This is what makes a bare
/// USB-C cable plug-and-play: the beacon arrives on the USB network interface and
/// its source address is the Mac's 169.254.x.x link-local address.
final class LinkDiscovery: @unchecked Sendable {
    static let shared = LinkDiscovery()

    private let queue = DispatchQueue(label: "com.vpad.client.discovery", qos: .utility)
    private let log = Logger(subsystem: "com.vpad.iPadClient", category: "discovery")
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var onHost: (@Sendable (String) -> Void)?

    private init() {}

    func start(onHost: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onHost = onHost
            self.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
            if self.socketFD >= 0 {
                close(self.socketFD)
                self.socketFD = -1
            }
        }
    }

    private func startLocked() {
        guard socketFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            log.error("discovery socket failed")
            return
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8899).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            NSLog("VPAD_DISCOVERY bind failed on udp/8899")
            log.error("discovery bind failed on udp/8899")
            close(fd)
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receive()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
        self.socketFD = fd
        NSLog("VPAD_DISCOVERY listening on udp/8899")
        log.info("listening for Mac cable discovery on udp/8899")
    }

    private func receive() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 512)

        while true {
            var remote = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)

            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &remote) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        recvfrom(
                            socketFD,
                            base,
                            bytes.count,
                            0,
                            sockaddrPointer,
                            &length
                        )
                    }
                }
            }

            guard count > 0 else { return }
            let data = Data(buffer.prefix(count))
            guard data.starts(with: Data("VPAD1".utf8)) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET,
                &remote.sin_addr,
                &hostBuffer,
                socklen_t(INET_ADDRSTRLEN)
            ) != nil else {
                continue
            }
            let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let host = String(decoding: bytes, as: UTF8.self)
            guard !host.isEmpty else { continue }
            onHost?(host)
        }
    }
}
