import Combine
import Foundation

/// Public iPadOS APIs do not expose Bluetooth connection/battery for Apple Pencil.
/// This monitor tracks recent Pencil input so the UI can show a "Pencil active"
/// state without pretending it is a Bluetooth pairing indicator.
@MainActor
final class PencilStatusMonitor: ObservableObject {
    static let shared = PencilStatusMonitor()

    @Published private(set) var lastActivity = Date.distantPast

    private init() {}

    func noteActivity() {
        lastActivity = Date()
    }
}
