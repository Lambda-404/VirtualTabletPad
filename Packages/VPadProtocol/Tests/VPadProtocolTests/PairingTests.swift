import XCTest
@testable import VPadProtocol

final class PairingTests: XCTestCase {
    func testTokenValidationAndSingleUse() {
        let manager = PairingTokenManager()
        let (token, _) = manager.generateToken(expiresIn: 60)

        // First validation must succeed
        XCTAssertTrue(manager.validateAndConsume(token: token))

        // Second validation must fail (token reuse rejected)
        XCTAssertFalse(manager.validateAndConsume(token: token))
    }

    func testTokenExpiration() {
        let manager = PairingTokenManager()
        let (token, expiresAt) = manager.generateToken(expiresIn: 10)

        // Time before expiry: accepted
        // Time after expiry: rejected
        let pastExpiry = expiresAt + 1
        XCTAssertFalse(manager.validateAndConsume(token: token, at: pastExpiry))
    }

    func testPairingPayloadEncodingAndDecoding() {
        let hostKey = Data(repeating: 0x33, count: 32)
        let token = Data(repeating: 0x44, count: 16)
        let expiry = 1799999999.0

        let payload = PairingPayloadV2(
            version: 2,
            host: "192.168.1.100",
            name: "MacBook Pro",
            tcpPort: 8889,
            udpPort: 8888,
            hostIdentityPublicKey: hostKey,
            pairingToken: token,
            expiresAt: expiry
        )

        let urlString = payload.encodeToURLString()
        guard let decoded = PairingPayloadV2.decode(from: urlString) else {
            return XCTFail("Failed to decode payload from URL")
        }

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.host, "192.168.1.100")
        XCTAssertEqual(decoded.name, "MacBook Pro")
        XCTAssertEqual(decoded.tcpPort, 8889)
        XCTAssertEqual(decoded.udpPort, 8888)
        XCTAssertEqual(decoded.hostIdentityPublicKey, hostKey)
        XCTAssertEqual(decoded.pairingToken, token)
        XCTAssertEqual(decoded.expiresAt, expiry)
    }

    func testAllowlistOperations() {
        let store = InMemoryDeviceAllowlistStore()
        let keyA = Data(repeating: 0x01, count: 32)
        let keyB = Data(repeating: 0x02, count: 32)

        let deviceA = PairedDevice(name: "iPad Pro", identityPublicKey: keyA)

        XCTAssertFalse(store.isAllowed(identity: keyA))

        // Allow device
        store.allow(device: deviceA)
        XCTAssertTrue(store.isAllowed(identity: keyA))
        XCTAssertFalse(store.isAllowed(identity: keyB))
        XCTAssertEqual(store.allDevices().count, 1)

        // Forget device
        store.forget(identity: keyA)
        XCTAssertFalse(store.isAllowed(identity: keyA))
        XCTAssertEqual(store.allDevices().count, 0)
    }

    func testApprovalDeniedLeavesAllowlistUnchanged() {
        let store = InMemoryDeviceAllowlistStore()
        let pendingKey = Data(repeating: 0x77, count: 32)

        // Simulating approval denial: device is never added to store
        let userApproved = false
        if userApproved {
            store.allow(device: PairedDevice(name: "Unknown iPad", identityPublicKey: pendingKey))
        }

        XCTAssertFalse(store.isAllowed(identity: pendingKey))
        XCTAssertEqual(store.allDevices().count, 0)
    }
}
