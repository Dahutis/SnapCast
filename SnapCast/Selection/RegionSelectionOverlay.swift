import AppKit
import ScreenCaptureKit

struct RegionSelectionResult {
    let display: SCDisplay
    let rect: CGRect
}

class RegionSelectionOverlay {
    private static var activeController: OverlayController?

    @MainActor
    static func selectRegion() async -> RegionSelectionResult? {
        // Dismiss any popovers and activate the app
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 200_000_000)

        return await withCheckedContinuation { continuation in
            let controller = OverlayController { result in
                activeController = nil
                continuation.resume(returning: result)
            }
            activeController = controller
            controller.show()
        }
    }
}

private class OverlayController {
    var windows: [NSWindow] = []
    var views: [OverlayView] = []
    let completion: (RegionSelectionResult?) -> Void
    private var hasCompleted = false

    init(completion: @escaping (RegionSelectionResult?) -> Void) {
        self.completion = completion
    }

    func show() {
        for screen in NSScreen.screens {
            let view = OverlayView()
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = view

            view.onSelectionComplete = { [weak self] rect in
                self?.finish(rect: rect, screen: screen)
            }
            view.onCancel = { [weak self] in
                self?.finish(rect: nil, screen: nil)
            }

            windows.append(window)
            views.append(view)
        }

        // Show all windows
        for window in windows {
            window.orderFrontRegardless()
        }

        // Make the first window key so it receives events
        if let first = windows.first, let firstView = views.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(firstView)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func finish(rect: CGRect?, screen: NSScreen?) {
        guard !hasCompleted else { return }
        hasCompleted = true

        for w in windows {
            w.orderOut(nil)
        }
        windows.removeAll()
        views.removeAll()

        guard let rect = rect, let screen = screen, rect.width > 5, rect.height > 5 else {
            completion(nil)
            return
        }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )

                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                guard let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
                    self.completion(nil)
                    return
                }

                // Convert from NSView coords (bottom-left origin) to SCKit coords (top-left origin)
                let screenFrame = screen.frame
                let flippedY = screenFrame.height - rect.origin.y - rect.height
                let displayRect = CGRect(
                    x: rect.origin.x,
                    y: flippedY,
                    width: rect.width,
                    height: rect.height
                )

                self.completion(RegionSelectionResult(display: display, rect: displayRect))
            } catch {
                self.completion(nil)
            }
        }
    }
}

// MARK: - Overlay View (handles drawing + mouse interaction)

private class OverlayView: NSView {
    var onSelectionComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var selectionRect: CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        guard rect.width > 2, rect.height > 2 else { return nil }
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if let rect = selectionRect {
            // Clear selected area
            NSColor.clear.setFill()
            rect.fill(using: .copy)

            // White border
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()

            // Dashed blue inner border
            NSColor.systemBlue.setStroke()
            let dashed = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            dashed.lineWidth = 1
            dashed.setLineDash([6, 4], count: 2, phase: 0)
            dashed.stroke()

            // Dimension label
            drawDimensionLabel(for: rect)
        }

        // Crosshair when idle
        if !isDragging, let mouse = window?.mouseLocationOutsideOfEventStream {
            let local = convert(mouse, from: nil)
            if bounds.contains(local) {
                NSColor.white.withAlphaComponent(0.4).setStroke()

                let h = NSBezierPath()
                h.move(to: CGPoint(x: bounds.minX, y: local.y))
                h.line(to: CGPoint(x: bounds.maxX, y: local.y))
                h.lineWidth = 0.5
                h.stroke()

                let v = NSBezierPath()
                v.move(to: CGPoint(x: local.x, y: bounds.minY))
                v.line(to: CGPoint(x: local.x, y: bounds.maxY))
                v.lineWidth = 0.5
                v.stroke()
            }
        }
    }

    private func drawDimensionLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let str = NSAttributedString(string: "  \(text)  ", attributes: attrs)
        let size = str.size()
        var y = rect.maxY + 6
        if y + size.height > bounds.maxY { y = rect.minY - size.height - 6 }
        let x = max(bounds.minX, min(rect.midX - size.width / 2, bounds.maxX - size.width))
        str.draw(at: CGPoint(x: x, y: y))
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        isDragging = false

        if let rect = selectionRect {
            onSelectionComplete?(rect)
        } else {
            // Click without drag — reset
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }
}
