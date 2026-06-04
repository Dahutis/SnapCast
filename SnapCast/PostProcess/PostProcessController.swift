import AppKit
import SwiftUI

/// Owns the single post-process editor window. Because the app runs as a menu
/// bar accessory (LSUIElement), we temporarily promote it to a regular app
/// while the editor is open so the window can take focus and show standard
/// chrome, then drop back to accessory on close.
@MainActor
final class PostProcessController: NSObject, NSWindowDelegate {
    static let shared = PostProcessController()

    /// Injected by AppDelegate at launch — needed to build documents (output
    /// folder, format, clipboard prefs).
    var settings: CaptureSettings?

    private var window: NSWindow?

    private override init() { super.init() }

    /// Open the editor on a saved capture file (PNG / JPEG / GIF).
    func open(url: URL) {
        guard let settings else {
            NSSound.beep()
            return
        }
        guard let document = EditorDocument.load(url: url, settings: settings) else {
            presentLoadFailure(url)
            return
        }
        present(document: document)
    }

    private func present(document: EditorDocument) {
        let editor = EditorView(document: document) { [weak self] in
            self?.closeWindow()
        }
        let hosting = NSHostingController(rootView: editor)

        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "NxCapture — Edit"
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = hosting
            window.center()
            self.window = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the editor is gone.
        NSApp.setActivationPolicy(.accessory)
    }

    private func presentLoadFailure(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open in editor"
        alert.informativeText = "NxCapture couldn't read \(url.lastPathComponent)."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
