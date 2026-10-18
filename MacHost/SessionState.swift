import Foundation
import VPadProtocol

/// Authoritative session lifecycle for diagnostics. The UDP hot path holds its
/// own `SessionCrypto` reference, so it never awaits this actor.
actor SessionState {
    static let shared = SessionState()

    struct Snapshot: Sendable {
        var isArmed: Bool
        var peer: String?
        var stats: SessionStats?
        var armedAt: Date?
    }

    private var token: UUID?
    private var session: SessionCrypto?
    private var peer: String?
    private var armedAt: Date?

    func arm(token: UUID, session: SessionCrypto, peer: String) {
        self.token = token
        self.session = session
        self.peer = peer
        self.armedAt = Date()
    }

    func disarm(token: UUID) {
        guard self.token == token else { return }
        self.token = nil
        self.session = nil
        self.peer = nil
        self.armedAt = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            isArmed: session != nil,
            peer: peer,
            stats: session?.stats(),
            armedAt: armedAt
        )
    }
}
