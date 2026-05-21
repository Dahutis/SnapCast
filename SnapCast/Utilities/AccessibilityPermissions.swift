import AppKit
import ApplicationServices
import Combine

/// Accessibility trust is required for global keyboard shortcuts to fire while
/// SnapCast isn't the focused app (`NSEvent.addGlobalMonitorForEvents` silently
/// no-ops otherwise). Unlike screen recording, accessibility is *soft* — the
/// app still works from the menu bar without it, only global hotkeys go dark.
///
/// We never prompt at launch. Prompts are issued only on explicit user action
/// (Grant button) to avoid the macOS race where TCC's trust cache isn't
/// populated yet during early `applicationDidFinishLaunching`, which surfaces
/// a duplicate prompt for users who already granted access.
///
/// macOS quirk: after the user toggles accessibility in System Settings, the
/// already-running process keeps reading `AXIsProcessTrusted() == false` until
/// it relaunches. `needsRelaunch` surfaces this so the UI can offer a one-click
/// Relaunch action instead of leaving the user stuck on "Grant" forever.
@MainActor
final class AccessibilityPermissions: ObservableObject {
    static let shared = AccessibilityPermissions()

    @Published var isAuthorized: Bool = AXIsProcessTrusted()

    /// Set true once the user has clicked Grant. Combined with `isAuthorized`
    /// this distinguishes "user hasn't tried yet" from "user granted in System
    /// Settings but the running process can't see it yet."
    @Published var didRequestAccess: Bool = false

    private init() {
        // Re-read trust state when the user returns to the app — covers the
        // case where they granted access in System Settings and tabbed back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-reads the current trust state without prompting. Safe to call anytime.
    func refresh() {
        isAuthorized = AXIsProcessTrusted()
    }

    /// Triggers the system "grant accessibility access" prompt. Call only from
    /// an explicit user gesture.
    func requestAccess() {
        didRequestAccess = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// True when the user has clicked Grant but the running process still
    /// reads as untrusted — almost always means a relaunch is required.
    var needsRelaunch: Bool {
        didRequestAccess && !isAuthorized
    }

    /// Opens the Privacy & Security → Accessibility pane in System Settings.
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and relaunch the app. After accessibility is granted in System
    /// Settings, the running process must restart before `AXIsProcessTrusted()`
    /// flips to true for it.
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
