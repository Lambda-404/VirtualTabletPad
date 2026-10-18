import Darwin
import Foundation
import os

/// Advertises the Mac on every active IPv4 interface so an iPad connected by a
/// plain USB-C cable can find the link-local address without a manual IP entry.
/// The beacon only carries discovery metadata; the real session remains E2EE.
final class HostBeacon: @unchecked Sendable {
    static let shared = HostBeacon()

    private let queue = DispatchQueue(label: "com.vpad.host.beacon", qos: .utility)
    private let log = Logger(subsystem: "com.vpad.MacHost", category: "beacon")
    private var timer: DispatchSourceTimer?
    private let port: UInt16 = 8899

    private init() {}

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func startLocked() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.sendBeacons()
        }
        timer.resume()
        self.timer = timer
        log.info("cable discovery beacon on udp/8899")
    }

    private func sendBeacons() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        let payload = Data("VPAD1|tcp=8889|udp=8888".utf8)
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let index = if_nametoindex(interface.ifa_name)
            guard index != 0 else { continue }

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var broadcast: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

            var boundIndex = index
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIndex, socklen_t(MemoryLayout<u_int>.size))

            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            destination.sin_addr = in_addr(s_addr: INADDR_BROADCAST)

            payload.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                _ = withUnsafePointer(to: &destination) { sockaddrPointer in
                    sockaddrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                        sendto(
                            fd,
                            base,
                            payload.count,
                            0,
                            addressPointer,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }

        }
    }
}
