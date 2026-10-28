import XCTest
@testable import VPadProtocol

final class IdentityKeyTests: XCTestCase {
    func testCreateThenLoadReturnsSameKey() throws {
        let store = InMemoryIdentityKeyStore()
        let key1 = try store.loadOrCreateIdentity()
        let key2 = try store.loadOrCreateIdentity()

        XCTAssertEqual(key1.publicKeyData, key2.publicKeyData)
        XCTAssertEqual(key1.privateKeyData, key2.privateKeyData)
    }

    func testTwoStoresProduceDifferentKeys() throws {
        let storeA = InMemoryIdentityKeyStore()
        let storeB = InMemoryIdentityKeyStore()

        let keyA = try storeA.loadOrCreateIdentity()
        let keyB = try storeB.loadOrCreateIdentity()

        XCTAssertNotEqual(keyA.publicKeyData, keyB.publicKeyData)
        XCTAssertNotEqual(keyA.privateKeyData, keyB.privateKeyData)
    }

    func testSignAndVerify() throws {
        let key = IdentityKey()
        let message = "VirtualTabletPad Handshake Transcript 2026".data(using: .utf8)!

        let signature = try key.sign(message)
        XCTAssertEqual(signature.count, 64)

        let isValid = IdentityKey.verify(signature: signature, for: message, publicKey: key.publicKey)
        XCTAssertTrue(isValid)

        let isValidRaw = IdentityKey.verify(signature: signature, for: message, publicKeyData: key.publicKeyData)
        XCTAssertTrue(isValidRaw)

        // Tampered message must fail verification
        var tamperedMessage = message
        tamperedMessage[0] ^= 0xFF
        XCTAssertFalse(IdentityKey.verify(signature: signature, for: tamperedMessage, publicKey: key.publicKey))

        // Wrong public key must fail verification
        let anotherKey = IdentityKey()
        XCTAssertFalse(IdentityKey.verify(signature: signature, for: message, publicKey: anotherKey.publicKey))

        // Tampered signature must fail verification
        var tamperedSignature = signature
        tamperedSignature[0] ^= 0xFF
        XCTAssertFalse(IdentityKey.verify(signature: tamperedSignature, for: message, publicKey: key.publicKey))
    }

    func testForgetIdentityForcesNewGeneration() throws {
        let store = InMemoryIdentityKeyStore()
        let key1 = try store.loadOrCreateIdentity()
        try store.forgetIdentity()
        let key2 = try store.loadOrCreateIdentity()

        XCTAssertNotEqual(key1.publicKeyData, key2.publicKeyData)
    }

    func testInvalidRawRepresentationThrows() {
        let shortData = Data(repeating: 0x42, count: 16)
        XCTAssertThrowsError(try IdentityKey(rawRepresentation: shortData)) { error in
            XCTAssertEqual(error as? IdentityKeyError, .invalidKeyRepresentation)
        }

        let longData = Data(repeating: 0x42, count: 64)
        XCTAssertThrowsError(try IdentityKey(rawRepresentation: longData)) { error in
            XCTAssertEqual(error as? IdentityKeyError, .invalidKeyRepresentation)
        }
    }

    func testVerifyRejectsMalformedData() {
        let key = IdentityKey()
        let message = Data("Test".utf8)
        let signature = (try? key.sign(message)) ?? Data()

        // Wrong signature length
        XCTAssertFalse(IdentityKey.verify(signature: Data(repeating: 0, count: 63), for: message, publicKeyData: key.publicKeyData))
        // Wrong public key length
        XCTAssertFalse(IdentityKey.verify(signature: signature, for: message, publicKeyData: Data(repeating: 0, count: 31)))
    }
}
