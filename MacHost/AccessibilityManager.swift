import AppKit
import ApplicationServices
import Combine
import Foundation

/// Polls the Accessibility trust state and prompts once on launch.
@MainActor
final class AccessibilityManager: ObservableObject {
    @MainActor static let shared = AccessibilityManager()

    /// `kAXTrustedCheckOptionPrompt` is an imported mutable global and is not
    /// concurrency-safe under Swift 6; its documented string value is used.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    @Published private(set) var isTrusted: Bool
    private var pollTask: Task<Void, Never>?
    private var hasPrompted = false

    private init() {
        isTrusted = AXIsProcessTrusted()
    }

    func start() {
        guard pollTask == nil else { return }
        refresh()
        if !isTrusted {
            requestAccess()
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                let trusted = AXIsProcessTrusted()
                self?.apply(trusted)
            }
        }
    }

    func requestAccess() {
        guard !hasPrompted else {
            openSettings()
            return
        }
        hasPrompted = true
        let options = [Self.promptOptionKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        apply(AXIsProcessTrusted())
    }

    private func apply(_ trusted: Bool) {
        if isTrusted != trusted {
            isTrusted = trusted
            NSLog("VPAD_ACCESSIBILITY trusted=%d", trusted ? 1 : 0)
        }
        HostStatus.shared.accessibilityGranted = trusted
    }
}
