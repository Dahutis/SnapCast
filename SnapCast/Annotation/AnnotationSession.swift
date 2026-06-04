import AppKit
import SwiftUI
import Combine

/// Result returned from an annotation session.
enum AnnotationResult {
    /// User clicked Done — strokes are committed and the canvas is still on
    /// screen at the time this resolves, so the caller can run their capture
    /// before calling `dismiss()`.
    case proceed
    /// User clicked Cancel or hit Esc — caller should abort the pending capture.
    case cancel
}

/// Coordinates the canvas window and floating tool palette for a single
/// annotation session. Lifecycle:
///   let session = AnnotationSession(targetRect: rect, screen: screen)
///   let result = await session.present()
///   if result == .proceed {
///       // perform capture — canvas is still on screen
///   }
///   session.dismiss()
///
/// Recording mode: the same session is kept alive across the entire recording.
/// After `present()` resolves with `.proceed`, the host calls
/// `enterRecordingMode()` which flips the palette into its timer/Stop layout
/// while the canvas stays visible for live drawing. `onStopRequested` fires
/// when the user clicks Stop in the palette.
@MainActor
final class AnnotationSession {
    static var current: AnnotationSession?

    let state = AnnotationState()
    private let targetRect: NSRect
    private let screen: NSScreen
    private let isRecordingMode: Bool

    /// Set by the recording host before `enterRecordingMode()` — invoked when
    /// the user clicks Stop in the palette during an active recording.
    var onStopRequested: (() -> Void)?

    private var canvasWindow: AnnotationCanvasWindow?
    private var paletteWindow: NSPanel?
    private var escapeMonitor: Any?
    private var continuation: CheckedContinuation<AnnotationResult, Never>?
    private var canvasActiveCancellable: AnyCancellable?

    /// `targetRect` is in screen (global) coordinates, bottom-left origin.
    init(targetRect: NSRect, screen: NSScreen, isRecordingMode: Bool = false) {
        self.targetRect = targetRect
        self.screen = screen
        self.isRecordingMode = isRecordingMode
    }

    /// Flip the palette into recording layout. Canvas remains visible so the
    /// user can keep drawing during the recording — strokes appear in the GIF
    /// because the canvas window is on screen, while the palette is hidden
    /// from ScreenCaptureKit via `sharingType = .none`.
    func enterRecordingMode() {
        state.isRecording = true
    }

    /// Push the latest elapsed-time into the palette's timer display.
    func updateElapsed(_ elapsed: TimeInterval) {
        state.elapsedTime = elapsed
    }

    /// Flip paint mode. When off, the canvas becomes click-through so the user
    /// can interact with apps underneath (Terminal, browser, etc.) without
    /// switching us out. The palette stays interactive in either state.
    func toggleCanvasActive() {
        state.isCanvasActive.toggle()
    }

    func setCanvasActive(_ active: Bool) {
        state.isCanvasActive = active
    }

    /// Shows canvas + palette and suspends until the user clicks Done or Cancel.
    /// The canvas remains on screen after `.proceed` resolves so the caller's
    /// capture pipeline sees the strokes — call `dismiss()` after capturing.
    func present() async -> AnnotationResult {
        AnnotationSession.current = self
        installCanvas()
        installPalette()
        installEscapeMonitor()
        observeCanvasActive()
        NSApp.activate(ignoringOtherApps: true)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func dismiss() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        canvasActiveCancellable?.cancel()
        canvasActiveCancellable = nil
        paletteWindow?.orderOut(nil)
        canvasWindow?.orderOut(nil)
        paletteWindow = nil
        canvasWindow = nil
        if AnnotationSession.current === self {
            AnnotationSession.current = nil
        }
    }

    /// Mirror `state.isCanvasActive` into the canvas window's
    /// `ignoresMouseEvents` so toggles from any source (hotkey, palette
    /// button, programmatic) route through the same code path.
    private func observeCanvasActive() {
        canvasActiveCancellable = state.$isCanvasActive.sink { [weak self] active in
            self?.canvasWindow?.setCanvasActive(active)
        }
    }

    /// Hides only the palette — used to remove the floating UI from the frame
    /// before a single-shot capture without losing the canvas's strokes.
    func hidePalette() {
        paletteWindow?.orderOut(nil)
    }

    // MARK: - Installation

    private func installCanvas() {
        let window = AnnotationCanvasWindow(frame: targetRect, state: state)
        window.makeKeyAndOrderFront(nil)
        canvasWindow = window
    }

    private func installPalette() {
        let palette = AnnotationToolPaletteView(
            state: state,
            isRecordingMode: isRecordingMode,
            onDone: { [weak self] in self?.finish(.proceed) },
            onCancel: { [weak self] in self?.finish(.cancel) },
            onStop: { [weak self] in self?.onStopRequested?() }
        )

        let host = NSHostingView(rootView: palette)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 56)

        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // One level above the canvas (also `.screenSaver`). On full-screen
        // captures the canvas covers the whole display, so a same-level palette
        // can end up *behind* it — every click would paint and only Esc would
        // work. Forcing the palette higher keeps its buttons reachable.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        // Critical: hide the palette from ScreenCaptureKit so it doesn't end
        // up in the recorded GIF. The canvas window stays at the default
        // sharingType so its strokes ARE captured.
        panel.sharingType = .none
        panel.contentView = host

        positionPalette(panel)
        panel.orderFrontRegardless()
        paletteWindow = panel
    }

    private func positionPalette(_ panel: NSPanel) {
        let paletteSize = panel.frame.size
        let visible = screen.visibleFrame
        let margin: CGFloat = 16

        // Prefer above the target rect; fall back to below if it would clip
        // the top of the visible area.
        var x = targetRect.midX - paletteSize.width / 2
        var y = targetRect.maxY + margin

        if y + paletteSize.height > visible.maxY {
            y = targetRect.minY - paletteSize.height - margin
        }
        if y < visible.minY {
            // Region fills the screen vertically — drop it inside the rect at
            // the top, just below where the menu bar / window chrome would be.
            y = min(visible.maxY - paletteSize.height - margin, targetRect.maxY - paletteSize.height - margin)
        }
        x = max(visible.minX + margin, min(x, visible.maxX - paletteSize.width - margin))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            // Esc → cancel; Cmd+Z → undo
            if event.keyCode == 53 {
                self.finish(.cancel)
                return nil
            }
            if event.keyCode == 6 && event.modifierFlags.contains(.command) {
                self.state.undo()
                NotificationCenter.default.post(name: AnnotationCanvasView.redrawNotification, object: nil)
                return nil
            }
            return event
        }
    }

    private func finish(_ result: AnnotationResult) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: result)
    }
}
