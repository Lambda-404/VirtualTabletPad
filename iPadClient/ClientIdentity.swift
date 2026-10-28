import Foundation
import VPadProtocol

enum ClientIdentity {
    static let keyStore = KeychainIdentityKeyStore(service: "com.vpad.iPadClient", account: "clientIdentity")

    static func current() -> IdentityKey {
        (try? keyStore.loadOrCreateIdentity()) ?? IdentityKey()
    }
}
