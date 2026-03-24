import SwiftUI

@main
struct SnapCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible windows — everything runs from the menu bar popover
        Settings {
            EmptyView()
        }
    }
}
