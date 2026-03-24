import AppKit
import ScreenCaptureKit

class ScreenPermissions: ObservableObject {
    static let shared = ScreenPermissions()

    @Published var isAuthorized = false

    func checkPermission() {
        if #available(macOS 15.0, *) {
            // On macOS 15+, use the async API
            Task {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    await MainActor.run { self.isAuthorized = true }
                } catch {
                    await MainActor.run { self.isAuthorized = false }
                }
            }
        } else {
            // Pre-flight check available on macOS 13+
            let hasAccess = CGPreflightScreenCaptureAccess()
            if !hasAccess {
                CGRequestScreenCaptureAccess()
            }
            isAuthorized = CGPreflightScreenCaptureAccess()
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
