import AppKit
import Combine

/// Input Monitoring lets SnapCast read key presses in other apps for Show
/// Keystrokes. Accessibility alone isn't enough on current macOS: without it
/// a keyboard event tap only sees modifier changes, never actual key presses.
///
/// The running process usually keeps reading "denied" after the user flips
/// the switch in System Settings until it relaunches.
@MainActor
final class InputMonitoringPermissions: ObservableObject {
    static let shared = InputMonitoringPermissions()

    @Published var isAuthorized: Bool = CGPreflightListenEventAccess()
    @Published var didRequestAccess: Bool = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        isAuthorized = CGPreflightListenEventAccess()
    }

    /// Adds SnapCast to the Input Monitoring list and shows the system prompt.
    /// Call only from an explicit user action.
    func requestAccess() {
        didRequestAccess = true
        _ = CGRequestListenEventAccess()
        refresh()
    }

    var needsRelaunch: Bool {
        didRequestAccess && !isAuthorized
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and relaunch the app so a fresh grant takes effect.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        // Give `open` a moment to spawn the new instance before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }
}
