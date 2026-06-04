import SwiftUI
import AppKit

/// SwiftUI wrapper around the AppKit editing surface. The NSView does the
/// drawing + mouse handling (annotation + crop); SwiftUI owns the surrounding
/// chrome and observes the document for state changes.
struct EditorCanvasView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeNSView(context: Context) -> EditorCanvasNSView {
        EditorCanvasNSView(document: document)
    }

    func updateNSView(_ nsView: EditorCanvasNSView, context: Context) {
        nsView.needsDisplay = true
    }
}

/// Bottom-left origin (non-flipped) so it shares the annotation coordinate
/// convention with the live capture canvas. The displayed image is aspect-fit
/// inside the view; `scale`/`origin` map between view points and base pixels.
final class EditorCanvasNSView: NSView {
    private unowned let document: EditorDocument

    private var currentElement: AnnotationElement?
    private var shapeAnchor: CGPoint?
    private var cropAnchor: CGPoint?
    private var lastMouseLocation: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Geometry mapping

    private var imageRect: CGRect {
        let size = document.baseSize
        guard size.width > 0, size.height > 0 else { return bounds }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let drawW = size.width * s
        let drawH = size.height * s
        return CGRect(x: (bounds.width - drawW) / 2,
                      y: (bounds.height - drawH) / 2,
                      width: drawW, height: drawH)
    }

    private var scale: CGFloat {
        let size = document.baseSize
        guard size.width > 0 else { return 1 }
        return imageRect.width / size.width
    }

    /// View point → base pixel point (bottom-left).
    private func toPixel(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) / scale, y: (p.y - r.minY) / scale)
    }

    /// Base pixel rect → view rect.
    private func toView(_ rect: CGRect) -> CGRect {
        let r = imageRect
        return CGRect(x: r.minX + rect.minX * scale,
                      y: r.minY + rect.minY * scale,
                      width: rect.width * scale,
                      height: rect.height * scale)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let size = document.baseSize
        return CGPoint(x: min(max(0, p.x), size.width),
                       y: min(max(0, p.y), size.height))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        // Checkerboard-ish dark backing already set on layer; draw the frame.
        if let img = document.previewImage {
            NSImage(cgImage: img, size: document.baseSize).draw(in: imageRect)
        }

        // Annotations in base pixel space, scaled into the view.
        ctx.saveGState()
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        ctx.scaleBy(x: scale, y: scale)
        AnnotationRenderer.draw(document.annotation.elements)
        if let current = currentElement { AnnotationRenderer.draw(current) }
        ctx.restoreGState()

        if document.isCropping || document.cropRect != nil {
            drawCropOverlay(ctx)
        }

        if document.isCropping, let loc = lastMouseLocation {
            // crosshair handled by cursor
            _ = loc
        }
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        let region = document.cropRect.map(toView) ?? imageRect
        // Dim everything outside the crop region.
        NSColor.black.withAlphaComponent(0.45).setFill()
        let outside = NSBezierPath(rect: imageRect)
        outside.append(NSBezierPath(rect: region).reversed)
        outside.windingRule = .evenOdd
        outside.fill()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: region)
        border.lineWidth = 1.5
        border.stroke()

        // Corner handles.
        let hs: CGFloat = 6
        NSColor.white.setFill()
        for c in [CGPoint(x: region.minX, y: region.minY),
                  CGPoint(x: region.maxX, y: region.minY),
                  CGPoint(x: region.minX, y: region.maxY),
                  CGPoint(x: region.maxX, y: region.maxY)] {
            NSBezierPath(rect: CGRect(x: c.x - hs/2, y: c.y - hs/2, width: hs, height: hs)).fill()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        let pixel = clampToImage(toPixel(view))
        lastMouseLocation = view

        if document.isCropping {
            cropAnchor = pixel
            document.cropRect = CGRect(origin: pixel, size: .zero)
            needsDisplay = true
            return
        }

        let state = document.annotation
        switch state.tool {
        case .eraser:
            eraseElement(at: pixel)
        case _ where state.tool.isShape:
            shapeAnchor = pixel
            currentElement = AnnotationElement(kind: shapeKind(start: pixel, end: pixel),
                                               color: state.color, thickness: state.thickness, brush: state.tool.brush)
        default:
            currentElement = AnnotationElement(kind: .freehand([pixel]),
                                               color: state.color, thickness: state.thickness, brush: state.tool.brush)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        let pixel = clampToImage(toPixel(view))
        lastMouseLocation = view

        if document.isCropping, let anchor = cropAnchor {
            document.cropRect = CGRect(x: min(anchor.x, pixel.x),
                                       y: min(anchor.y, pixel.y),
                                       width: abs(anchor.x - pixel.x),
                                       height: abs(anchor.y - pixel.y))
            needsDisplay = true
            return
        }

        let state = document.annotation
        switch state.tool {
        case .eraser:
            eraseElement(at: pixel)
        case _ where state.tool.isShape:
            guard let anchor = shapeAnchor else { break }
            let end = event.modifierFlags.contains(.shift) ? constrained(from: anchor, to: pixel) : pixel
            currentElement?.kind = shapeKind(start: anchor, end: end)
        default:
            if case .freehand(var pts)? = currentElement?.kind {
                pts.append(pixel)
                currentElement?.kind = .freehand(pts)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        let pixel = clampToImage(toPixel(view))

        if document.isCropping {
            cropAnchor = nil
            // Discard a too-small crop (treated as a tap to clear intent).
            if let c = document.cropRect, c.width < 4 || c.height < 4 {
                document.cropRect = nil
            }
            needsDisplay = true
            return
        }

        let state = document.annotation
        switch state.tool {
        case .eraser:
            break
        case _ where state.tool.isShape:
            if let anchor = shapeAnchor {
                let end = event.modifierFlags.contains(.shift) ? constrained(from: anchor, to: pixel) : pixel
                currentElement?.kind = shapeKind(start: anchor, end: end)
            }
            if let element = currentElement { state.append(element) }
        default:
            if case .freehand(var pts)? = currentElement?.kind {
                pts.append(pixel)
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
    }

    override func mouseExited(with event: NSEvent) {
        lastMouseLocation = nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Helpers

    private func shapeKind(start: CGPoint, end: CGPoint) -> AnnotationKind {
        switch document.annotation.tool {
        case .line:      return .line(start, end)
        case .arrow:     return .arrow(start, end)
        case .rectangle: return .rect(start, end)
        case .ellipse:   return .ellipse(start, end)
        default:         return .line(start, end)
        }
    }

    private func constrained(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch document.annotation.tool {
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + len * cos(angle), y: start.y + len * sin(angle))
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
    }

    private func eraseElement(at point: CGPoint) {
        let hitRadius: CGFloat = 14 / max(scale, 0.0001)
        document.annotation.elements.removeAll {
            AnnotationRenderer.element($0, isWithin: hitRadius, of: point)
        }
        needsDisplay = true
    }
}
