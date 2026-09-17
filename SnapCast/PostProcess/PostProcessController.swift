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

    /// Open the editor on a saved capture file (PNG / JPEG / GIF), or the
    /// trimmer for MP4 recordings.
    func open(url: URL) {
        guard let settings else {
            NSSound.beep()
            return
        }
        if url.pathExtension.lowercased() == OutputFormat.mp4.fileExtension {
            let trimmer = VideoTrimViewController(url: url, settings: settings) { [weak self] in
                self?.closeWindow()
            }
            present(contentViewController: trimmer, title: "NxCapture — Trim")
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
        present(contentViewController: NSHostingController(rootView: editor), title: "NxCapture — Edit")
    }

    private func present(contentViewController: NSViewController, title: String) {
        // Stop a trimmer that's being replaced so its audio doesn't keep playing.
        (window?.contentViewController as? VideoTrimViewController)?.stopPlayback()

        if let window {
            window.contentViewController = contentViewController
            window.title = title
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = contentViewController
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
        (window?.contentViewController as? VideoTrimViewController)?.stopPlayback()
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
