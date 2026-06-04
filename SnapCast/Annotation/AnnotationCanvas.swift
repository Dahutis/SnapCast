import AppKit

/// Borderless, transparent NSWindow whose content view captures annotation
/// elements and renders them via `AnnotationRenderer`. The window is visible on
/// screen so screen-capture streams see the strokes naturally — there's no
/// per-frame compositing trick.
@MainActor
final class AnnotationCanvasWindow: NSPanel {
    let canvas: AnnotationCanvasView

    init(frame: NSRect, state: AnnotationState) {
        self.canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: frame.size), state: state)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .screenSaver
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.contentView = canvas
        // Don't constrain to screen — caller positions us precisely on the
        // target rect, including the menu-bar strip if needed.
        self.setFrame(frame, display: true)
    }

    /// When `active` is false the canvas becomes click-through: existing
    /// elements stay on screen (and in the recording) but mouse events fall
    /// through to whatever app is beneath. Returning to active reattaches
    /// mouse handling; we re-key the window so the next drag actually draws.
    func setCanvasActive(_ active: Bool) {
        self.ignoresMouseEvents = !active
        canvas.canvasActiveChanged(active)
        if active {
            self.makeKeyAndOrderFront(nil)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The actual drawing surface. Mouse events build up a current element;
/// `mouseUp` commits it to `state.elements`. Rendering is delegated to
/// `AnnotationRenderer` so the live overlay matches the editor exactly.
final class AnnotationCanvasView: NSView {
    private let state: AnnotationState
    private var stateObservation: NSObjectProtocol?

    /// In-progress element being drawn this drag. Lives outside
    /// `state.elements` until `mouseUp` so undo doesn't see half-drawn marks.
    private var currentElement: AnnotationElement?
    /// Anchor point for shape drags (start corner / line origin).
    private var shapeAnchor: CGPoint?

    private var trackingArea: NSTrackingArea?
    private var lastMouseLocation: CGPoint?

    init(frame: NSRect, state: AnnotationState) {
        self.state = state
        super.init(frame: frame)
        self.wantsLayer = true
        stateObservation = NotificationCenter.default.addObserver(
            forName: AnnotationCanvasView.redrawNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let obs = stateObservation { NotificationCenter.default.removeObserver(obs) }
    }

    static let redrawNotification = Notification.Name("AnnotationCanvasNeedsRedraw")

    /// Called by the host window when paint mode is toggled. Clears any pending
    /// in-progress element + cursor hint so the view doesn't keep "remembering"
    /// the last mouse spot from before the user switched away.
    func canvasActiveChanged(_ active: Bool) {
        if !active {
            currentElement = nil
            shapeAnchor = nil
            lastMouseLocation = nil
        }
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setShouldAntialias(true)
        ctx?.setAllowsAntialiasing(true)

        AnnotationRenderer.draw(state.elements)
        if let current = currentElement {
            AnnotationRenderer.draw(current)
        }

        // Self-drawn cursor — sized to current thickness, drawn last so it's
        // always on top of in-progress strokes.
        if let loc = lastMouseLocation, bounds.contains(loc) {
            drawCursor(at: loc)
        }
    }

    private func drawCursor(at point: CGPoint) {
        let radius: CGFloat
        let color: NSColor
        switch state.tool {
        case .eraser:
            radius = 14
            color = .white
        default:
            radius = max(3, state.thickness.width / 2)
            color = state.color.nsColor
        }

        let rect = CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        )

        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: rect).fill()

        color.setStroke()
        let outline = NSBezierPath(ovalIn: rect)
        outline.lineWidth = state.tool == .eraser ? 1.5 : 1.0
        outline.stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = point

        switch state.tool {
        case .eraser:
            eraseElement(at: point)

        case _ where state.tool.isShape:
            shapeAnchor = point
            currentElement = AnnotationElement(
                kind: shapeKind(start: point, end: point),
                color: state.color,
                thickness: state.thickness,
                brush: state.tool.brush
            )

        default: // freehand brushes
            currentElement = AnnotationElement(
                kind: .freehand([point]),
                color: state.color,
                thickness: state.thickness,
                brush: state.tool.brush
            )
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = point

        switch state.tool {
        case .eraser:
            eraseElement(at: point)

        case _ where state.tool.isShape:
            guard let anchor = shapeAnchor else { break }
            let end = event.modifierFlags.contains(.shift)
                ? constrained(from: anchor, to: point)
                : point
            currentElement?.kind = shapeKind(start: anchor, end: end)

        default: // freehand
            if case .freehand(var pts)? = currentElement?.kind {
                pts.append(point)
                currentElement?.kind = .freehand(pts)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state.tool {
        case .eraser:
            break

        case _ where state.tool.isShape:
            if let anchor = shapeAnchor {
                let end = event.modifierFlags.contains(.shift)
                    ? constrained(from: anchor, to: point)
                    : point
                currentElement?.kind = shapeKind(start: anchor, end: end)
            }
            if let element = currentElement { state.append(element) }

        default: // freehand
            if case .freehand(var pts)? = currentElement?.kind {
                pts.append(point)
                currentElement?.kind = .freehand(pts)
                if let element = currentElement { state.append(element) }
            }
        }

        currentElement = nil
        shapeAnchor = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        lastMouseLocation = nil
        needsDisplay = true
    }

    // MARK: - Helpers

    private func shapeKind(start: CGPoint, end: CGPoint) -> AnnotationKind {
        switch state.tool {
        case .line:      return .line(start, end)
        case .arrow:     return .arrow(start, end)
        case .rectangle: return .rect(start, end)
        case .ellipse:   return .ellipse(start, end)
        default:         return .line(start, end)
        }
    }

    /// Shift-constrain a shape: lines snap to 45° increments; rect/ellipse snap
    /// to a square/circle off the larger delta.
    private func constrained(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        switch state.tool {
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + len * cos(angle), y: start.y + len * sin(angle))
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side),
                           y: start.y + (dy < 0 ? -side : side))
        }
    }

    /// Removes any element whose painted geometry passes within ~14pt of `point`.
    private func eraseElement(at point: CGPoint) {
        let hitRadius: CGFloat = 14
        state.elements.removeAll { element in
            AnnotationRenderer.element(element, isWithin: hitRadius, of: point)
        }
        needsDisplay = true
    }
}
