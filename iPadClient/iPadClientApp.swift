import SwiftUI

@main
struct iPadClientApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .preferredColorScheme(.dark)
        }
    }
}
