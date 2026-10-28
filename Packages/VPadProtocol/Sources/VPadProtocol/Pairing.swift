import Foundation
#if canImport(Security)
import Security
#endif

/// Versioned QR code payload for mutual pairing.
public struct PairingPayloadV2: Codable, Equatable, Sendable {
    public let version: Int
    public let host: String
    public let name: String
    public let tcpPort: UInt16
    public let udpPort: UInt16
    public let hostIdentityPublicKey: Data
    public let pairingToken: Data
    public let expiresAt: TimeInterval

    public init(
        version: Int = 2,
        host: String,
        name: String,
        tcpPort: UInt16 = VPadConstants.tcpPort,
        udpPort: UInt16 = VPadConstants.udpPort,
        hostIdentityPublicKey: Data,
        pairingToken: Data,
        expiresAt: TimeInterval
    ) {
        self.version = version
        self.host = host
        self.name = name
        self.tcpPort = tcpPort
        self.udpPort = udpPort
        self.hostIdentityPublicKey = hostIdentityPublicKey
        self.pairingToken = pairingToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        Date().timeIntervalSince1970 > expiresAt
    }

    public func encodeToURLString() -> String {
        var components = URLComponents()
        components.scheme = "vpad"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "tcp", value: String(tcpPort)),
            URLQueryItem(name: "udp", value: String(udpPort)),
            URLQueryItem(name: "key", value: hostIdentityPublicKey.base64EncodedString()),
            URLQueryItem(name: "tok", value: pairingToken.base64EncodedString()),
            URLQueryItem(name: "exp", value: String(Int64(expiresAt)))
        ]
        return components.url?.absoluteString ?? ""
    }

    public static func decode(from string: String) -> PairingPayloadV2? {
        if let url = URL(string: string), url.scheme == "vpad", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            guard let host = items.first(where: { $0.name == "host" })?.value,
                  let name = items.first(where: { $0.name == "name" })?.value,
                  let keyStr = items.first(where: { $0.name == "key" })?.value,
                  let key = Data(base64Encoded: keyStr),
                  let tokStr = items.first(where: { $0.name == "tok" })?.value,
                  let tok = Data(base64Encoded: tokStr),
                  let expStr = items.first(where: { $0.name == "exp" })?.value,
                  let exp = TimeInterval(expStr) else {
                return nil
            }
            let version = Int(items.first(where: { $0.name == "v" })?.value ?? "2") ?? 2
            let tcp = UInt16(items.first(where: { $0.name == "tcp" })?.value ?? "") ?? VPadConstants.tcpPort
            let udp = UInt16(items.first(where: { $0.name == "udp" })?.value ?? "") ?? VPadConstants.udpPort
            return PairingPayloadV2(
                version: version,
                host: host,
                name: name,
                tcpPort: tcp,
                udpPort: udp,
                hostIdentityPublicKey: key,
                pairingToken: tok,
                expiresAt: exp
            )
        }
        guard let data = string.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingPayloadV2.self, from: data) else {
            return nil
        }
        return payload
    }
}

/// Metadata describing an approved, paired device.
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let identityPublicKey: Data
    public let pairedAt: Date

    public init(id: UUID = UUID(), name: String, identityPublicKey: Data, pairedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.identityPublicKey = identityPublicKey
        self.pairedAt = pairedAt
    }
}

/// Thread-safe manager for generating and validating single-use pairing tokens.
public final class PairingTokenManager: @unchecked Sendable {
    public static let shared = PairingTokenManager()
    private let lock = NSLock()
    private var activeTokens: [Data: TimeInterval] = [:]

    public init() {}

    public func generateToken(expiresIn: TimeInterval = 300) -> (token: Data, expiresAt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        var bytes = [UInt8](repeating: 0, count: 16)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        #else
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        #endif
        let token = Data(bytes)
        let expiresAt = Date().timeIntervalSince1970 + expiresIn

        cleanExpiredLocked()
        activeTokens[token] = expiresAt
        return (token, expiresAt)
    }

    public func validateAndConsume(token: Data, at currentTime: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let expiresAt = activeTokens.removeValue(forKey: token) else {
            return false
        }
        return currentTime <= expiresAt
    }

    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        activeTokens.removeAll()
    }

    private func cleanExpiredLocked() {
        let now = Date().timeIntervalSince1970
        activeTokens = activeTokens.filter { _, expiry in expiry > now }
    }
}

/// Abstract storage for approved paired devices.
public protocol DeviceAllowlistStore: Sendable {
    func isAllowed(identity: Data) -> Bool
    func allow(device: PairedDevice)
    func forget(identity: Data)
    func allDevices() -> [PairedDevice]
}

/// In-memory allowlist store for unit tests.
public final class InMemoryDeviceAllowlistStore: DeviceAllowlistStore, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [Data: PairedDevice] = [:]

    public init(initialDevices: [PairedDevice] = []) {
        for dev in initialDevices {
            devices[dev.identityPublicKey] = dev
        }
    }

    public func isAllowed(identity: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return devices[identity] != nil
    }

    public func allow(device: PairedDevice) {
        lock.lock()
        defer { lock.unlock() }
        devices[device.identityPublicKey] = device
    }

    public func forget(identity: Data) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeValue(forKey: identity)
    }

    public func allDevices() -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(devices.values)
    }
}

/// Persistent UserDefaults-backed allowlist store for production hosts.
public final class PersistentDeviceAllowlistStore: DeviceAllowlistStore, @unchecked Sendable {
    public static let shared = PersistentDeviceAllowlistStore()
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "vpad.pairedDevices") {
        self.defaults = defaults
        self.key = key
    }

    public func isAllowed(identity: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let devices = loadDevicesLocked()
        return devices.contains(where: { $0.identityPublicKey == identity })
    }

    public func allow(device: PairedDevice) {
        lock.lock()
        defer { lock.unlock() }
        var devices = loadDevicesLocked()
        devices.removeAll(where: { $0.identityPublicKey == device.identityPublicKey })
        devices.append(device)
        saveDevicesLocked(devices)
    }

    public func forget(identity: Data) {
        lock.lock()
        defer { lock.unlock() }
        var devices = loadDevicesLocked()
        devices.removeAll(where: { $0.identityPublicKey == identity })
        saveDevicesLocked(devices)
    }

    public func allDevices() -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return loadDevicesLocked()
    }

    private func loadDevicesLocked() -> [PairedDevice] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return list
    }

    private func saveDevicesLocked(_ devices: [PairedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: key)
    }
}
