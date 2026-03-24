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
        keyboardShortcuts = KeyboardShortcuts(captureManager: captureSessionManager)

        ScreenPermissions.shared.checkPermission()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
