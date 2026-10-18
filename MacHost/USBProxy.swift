import Darwin
import Foundation
import os

/// Bridges the iPad's raw USB TCP port (via usbmuxd) to the Mac host's normal
/// loopback TCP control port. The iPad app listens on 8890 in USB mode; usbmuxd
/// exposes that port over the cable; the host then sees a normal TCP session.
/// No Wi-Fi, IP address, router, proxy or external NIC is involved.
final class USBProxy: @unchecked Sendable {
    static let shared = USBProxy()

    private let log = Logger(subsystem: "com.vpad.MacHost", category: "usb")
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private let devicePort: UInt16 = 8890
    private let localHost = "127.0.0.1"
    private let localPort: UInt16 = 8889

    private init() {}

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread.name = "com.vpad.usb.proxy"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func runLoop() {
        log.info("USB proxy started")
        while isRunning {
            autoreleasepool {
                bridgeOnce()
            }
            if isRunning {
                Thread.sleep(forTimeInterval: 2)
            }
        }
        log.info("USB proxy stopped")
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func bridgeOnce() {
        // Do not touch the Mac host's control listener unless the iPad app is
        // actually listening in USB mode. This keeps Wi-Fi/direct sessions
        // untouched when the USB transport is not selected.
        guard let usb = connectUSB() else { return }

        let local = connectTCP(host: localHost, port: localPort)
        guard local >= 0 else {
            close(usb)
            return
        }

        setNoSigPipe(local)
        setNoSigPipe(usb)
        log.info("USB bridge connected to iPad interface")
        pump(local, usb)
        close(local)
        close(usb)
        log.info("USB bridge closed")
    }

    // MARK: - Byte pump

    private func pump(_ first: Int32, _ second: Int32) {
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInteractive).async(group: group) { [weak self] in
            self?.copyBytes(from: first, to: second)
        }
        DispatchQueue.global(qos: .userInteractive).async(group: group) { [weak self] in
            self?.copyBytes(from: second, to: first)
        }
        group.wait()
        shutdown(first, SHUT_RDWR)
        shutdown(second, SHUT_RDWR)
    }

    private func copyBytes(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while isRunning {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return recv(from, base, bytes.count, 0)
            }
            guard count > 0 else { break }
            guard sendAll(to, buffer, count: count) else { break }
        }
        // Unblock the other direction and let the bridge tear down.
        shutdown(from, SHUT_RDWR)
        shutdown(to, SHUT_RDWR)
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: offset), count - offset, 0)
            }
            if sent <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += sent
        }
        return true
    }

    private func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: - Local Mac host socket

    private func connectTCP(host: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(fd)
            return -1
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - usbmuxd

    private func connectUSB() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            let buffer = bytes.bindMemory(to: CChar.self)
            _ = path.withCString { source in
                strncpy(buffer.baseAddress!, source, buffer.count - 1)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let deviceID = listUSBDevice(fd) else {
            close(fd)
            return nil
        }

        let portNumber = UInt32(UInt16(devicePort).bigEndian)
        let connectRequest: [String: Any] = [
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": portNumber,
        ]
        guard sendPlist(fd, connectRequest, tag: 2),
              let response = receivePlist(fd),
              response["MessageType"] as? String == "Result",
              (response["Number"] as? Int) == 0 else {
            close(fd)
            return nil
        }

        // Raw tunnel from here on; remove the short receive timeout.
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func listUSBDevice(_ fd: Int32) -> Int? {
        let request: [String: Any] = [
            "MessageType": "ListDevices",
            "ClientVersionString": "VirtualTabletPad",
            "ProgName": "VirtualTabletPad",
        ]
        guard sendPlist(fd, request, tag: 1) else { return nil }

        for _ in 0..<8 {
            guard let message = receivePlist(fd) else { return nil }
            guard let devices = message["DeviceList"] as? [[String: Any]] else {
                continue
            }
            for device in devices {
                let properties = device["Properties"] as? [String: Any] ?? [:]
                let connectionType = properties["ConnectionType"] as? String
                let usbSerial = properties["USBSerialNumber"] as? String
                if connectionType == "USB" || usbSerial != nil {
                    return device["DeviceID"] as? Int
                }
            }
            return nil
        }
        return nil
    }

    private func sendPlist(_ fd: Int32, _ object: [String: Any], tag: UInt32) -> Bool {
        guard let payload = try? PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        ) else {
            return false
        }
        guard payload.count + 16 <= Int(UInt32.max) else { return false }

        var header = Data()
        header.appendUInt32LE(UInt32(payload.count + 16))
        header.appendUInt32LE(1)
        header.appendUInt32LE(8)
        header.appendUInt32LE(tag)

        var data = Data(capacity: header.count + payload.count)
        data.append(header)
        data.append(payload)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let sent = send(fd, base.advanced(by: offset), data.count - offset, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += sent
            }
            return true
        }
    }

    private func receivePlist(_ fd: Int32) -> [String: Any]? {
        guard let header = readExact(fd, count: 16) else { return nil }
        let length = Int(readUInt32LE(header, offset: 0))
        let type = readUInt32LE(header, offset: 8)
        guard length >= 16, length <= 1_048_576 else { return nil }
        guard let body = readExact(fd, count: length - 16) else { return nil }
        guard type == 8 else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: body,
            options: [],
            format: nil
        )) as? [String: Any]
    }

    private func readExact(_ fd: Int32, count: Int) -> Data? {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return recv(fd, base.advanced(by: offset), count - offset, 0)
            }
            if received <= 0 {
                if errno == EINTR { continue }
                return nil
            }
            offset += received
        }
        data.append(contentsOf: buffer)
        return data
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
