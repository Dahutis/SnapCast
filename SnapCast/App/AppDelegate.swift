import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let captureSettings = CaptureSettings()
    var menuBarController: MenuBarController!
    var captureSessionManager: CaptureSessionManager!
    var keyboardShortcuts: KeyboardShortcuts!

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureSessionManager = CaptureSessionManager(settings: captureSettings)
        menuBarController = MenuBarController(
            settings: captureSettings,
            captureManager: captureSessionManager
        )
        keyboardShortcuts = KeyboardShortcuts(captureManager: captureSessionManager, settings: captureSettings)

        // Read current permission state without surfacing prompts. The popover
        // and Settings → Permissions surface explicit Grant actions when state
        // is missing; prompting at launch races with TCC's trust cache and can
        // re-surface accessibility prompts for users who already granted.
        ScreenPermissions.shared.checkPermission()
        AccessibilityPermissions.shared.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
