import Foundation
import VPadProtocol

/// Client-side session store. The hot UDP path keeps its own `SessionCrypto`
/// reference; this actor is the authoritative diagnostics/lifecycle snapshot.
actor ClientSessionState {
    static let shared = ClientSessionState()

    struct Snapshot: Sendable {
        var isReady: Bool
        var peer: String?
        var rttMilliseconds: Double?
    }

    private var session: SessionCrypto?
    private var peer: String?
    private var rttMilliseconds: Double?

    func arm(session: SessionCrypto, peer: String) {
        self.session = session
        self.peer = peer
    }

    func disarm() {
        session = nil
        peer = nil
        rttMilliseconds = nil
    }

    func setRTT(_ milliseconds: Double) {
        rttMilliseconds = milliseconds
    }

    func snapshot() -> Snapshot {
        Snapshot(
            isReady: session != nil,
            peer: peer,
            rttMilliseconds: rttMilliseconds
        )
    }
}
