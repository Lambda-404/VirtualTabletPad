import Foundation
import VPadProtocol

enum HostIdentity {
    static let keyStore = KeychainIdentityKeyStore(service: "com.vpad.MacHost", account: "hostIdentity")

    static func current() -> IdentityKey {
        (try? keyStore.loadOrCreateIdentity()) ?? IdentityKey()
    }
}
