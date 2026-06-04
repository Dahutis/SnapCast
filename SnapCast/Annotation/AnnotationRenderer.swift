import AppKit

/// Stateless drawing routine shared by the live annotation canvas and the
/// post-process editor, so an element drawn over a recording looks identical to
/// the same element drawn over a still in the editor.
///
/// All methods assume an active `NSGraphicsContext` and draw in the element's
/// own coordinate space (the caller sets up any flip/transform).
enum AnnotationRenderer {

    /// Draw a single element with its brush style. Arrowheads are appended for
    /// `.arrow` elements.
    static func draw(_ element: AnnotationElement) {
        guard element.isDrawable else { return }
        let color = element.color.nsColor
        let width = element.thickness.width

        let path = bezierPath(for: element.kind)
        stroke(path, color: color, width: width, brush: element.brush)

        if case let .arrow(a, b) = element.kind {
            let head = arrowHead(from: a, to: b, width: width)
            stroke(head, color: color, width: width, brush: element.brush)
        }
    }

    /// Draw every element in order. Convenience for the editor's overlay.
    static func draw(_ elements: [AnnotationElement]) {
        for element in elements { draw(element) }
    }

    // MARK: - Stroke styling

    static func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat, brush: BrushStyle) {
        path.lineJoinStyle = .round
        switch brush {
        case .electric:
            path.lineCapStyle = .round
            // Bloom layer (wider, low-alpha) for the electric glow.
            color.withAlphaComponent(0.35).setStroke()
            path.lineWidth = width + 6
            path.stroke()
            // Solid core line on top.
            color.setStroke()
            path.lineWidth = width
            path.stroke()

        case .highlighter:
            // Wide, flat, translucent — like a real highlighter laid over text.
            path.lineCapStyle = .square
            color.withAlphaComponent(0.30).setStroke()
            path.lineWidth = width * 2.6
            path.stroke()

        case .marker:
            // Solid, flat, no bloom.
            path.lineCapStyle = .round
            color.setStroke()
            path.lineWidth = width
            path.stroke()
        }
    }

    // MARK: - Geometry

    static func bezierPath(for kind: AnnotationKind) -> NSBezierPath {
        switch kind {
        case .freehand(let pts):
            return smoothPath(for: pts)
        case .line(let a, let b), .arrow(let a, let b):
            let p = NSBezierPath()
            p.move(to: a)
            p.line(to: b)
            return p
        case .rect(let a, let b):
            return NSBezierPath(rect: normalizedRect(a, b))
        case .ellipse(let a, let b):
            return NSBezierPath(ovalIn: normalizedRect(a, b))
        }
    }

    static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Two barbs forming the arrowhead at `b`, scaled to the line width.
    private static func arrowHead(from a: CGPoint, to b: CGPoint, width: CGFloat) -> NSBezierPath {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = max(14, width * 2.2)
        let spread = CGFloat.pi / 7  // ~25°

        let left = CGPoint(
            x: b.x - length * cos(angle - spread),
            y: b.y - length * sin(angle - spread)
        )
        let right = CGPoint(
            x: b.x - length * cos(angle + spread),
            y: b.y - length * sin(angle + spread)
        )

        let path = NSBezierPath()
        path.move(to: left)
        path.line(to: b)
        path.line(to: right)
        return path
    }

    /// Catmull-Rom-style smoothing: quadratic curves between successive
    /// midpoints using recorded points as control points. Much smoother than
    /// connecting raw points with lineTo.
    static func smoothPath(for points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.move(to: points[0])
            path.line(to: points[1])
            return path
        }

        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(
                x: (points[i].x + points[i + 1].x) / 2,
                y: (points[i].y + points[i + 1].y) / 2
            )
            path.curve(to: mid, controlPoint1: points[i], controlPoint2: points[i])
        }
        path.line(to: points.last!)
        return path
    }

    // MARK: - Hit testing (eraser)

    /// True if `point` lies within `radius` of the element's painted geometry.
    /// Works for every kind by flattening the bezier path to a polyline and
    /// measuring distance to its sample points.
    static func element(_ element: AnnotationElement, isWithin radius: CGFloat, of point: CGPoint) -> Bool {
        let samples = samplePoints(for: element.kind)
        for p in samples where hypot(p.x - point.x, p.y - point.y) < radius {
            return true
        }
        return false
    }

    /// Dense sample points along an element's path (post-flattening), used for
    /// eraser hit-testing.
    static func samplePoints(for kind: AnnotationKind) -> [CGPoint] {
        if case .freehand(let pts) = kind { return pts }

        // Flattening reduces every curve to move/line/close segments, so the
        // first associated point is the vertex we care about for every element
        // except the implicit closePath.
        let flattened = bezierPath(for: kind).flattened
        var points: [CGPoint] = []
        var coords = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flattened.elementCount {
            if flattened.element(at: i, associatedPoints: &coords) != .closePath {
                points.append(coords[0])
            }
        }
        return points
    }
}
