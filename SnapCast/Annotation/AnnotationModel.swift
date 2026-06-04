import AppKit
import SwiftUI

/// User-pickable tool. Three families:
///   - freehand brushes (pen / highlighter / marker) draw a smoothed path
///   - shapes (line / arrow / rectangle / ellipse) are dragged start→end
///   - eraser removes whole elements via path hit-test (not pixel erase)
enum AnnotationTool: String, CaseIterable, Identifiable {
    case pen
    case highlighter
    case marker
    case line
    case arrow
    case rectangle
    case ellipse
    case eraser

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen:         return "pencil.tip"
        case .highlighter: return "highlighter"
        case .marker:      return "paintbrush.pointed.fill"
        case .line:        return "line.diagonal"
        case .arrow:       return "line.diagonal.arrow"
        case .rectangle:   return "rectangle"
        case .ellipse:     return "circle"
        case .eraser:      return "eraser"
        }
    }

    var displayName: String {
        switch self {
        case .pen:         return "Pen"
        case .highlighter: return "Highlighter"
        case .marker:      return "Marker"
        case .line:        return "Line"
        case .arrow:       return "Arrow"
        case .rectangle:   return "Rectangle"
        case .ellipse:     return "Ellipse"
        case .eraser:      return "Eraser"
        }
    }

    /// Rendering style for elements created with this tool. Shapes inherit the
    /// brush of whichever family they belong to — they all draw with the solid
    /// electric look so outlines stay crisp.
    var brush: BrushStyle {
        switch self {
        case .highlighter: return .highlighter
        case .marker:      return .marker
        default:           return .electric
        }
    }

    var isFreehand: Bool {
        switch self {
        case .pen, .highlighter, .marker: return true
        default: return false
        }
    }

    var isShape: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse: return true
        default: return false
        }
    }
}

/// How a path is painted. `electric` is the original telestrator look (soft
/// bloom under a solid core). `highlighter` is a wide translucent flat stroke.
/// `marker` is a solid flat stroke with no bloom.
enum BrushStyle: Equatable {
    case electric
    case highlighter
    case marker
}

/// Telestrator-classic palette. Yellow is the default — it reads well over both
/// light and dark content. Each color carries enough luminance to glow visibly
/// through the bloom layer.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case white, yellow, red, green, cyan

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .white:  return NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.20, alpha: 1)
        case .red:    return NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.30, alpha: 1)
        case .green:  return NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.45, alpha: 1)
        case .cyan:   return NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.00, alpha: 1)
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
}

enum AnnotationThickness: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .small:  return 4
        case .medium: return 8
        case .large:  return 14
        }
    }

    /// Visual swatch radius when rendered in the palette picker.
    var swatchRadius: CGFloat {
        switch self {
        case .small:  return 3
        case .medium: return 5
        case .large:  return 8
        }
    }
}

/// Geometry of a drawable element. Freehand carries raw sampled points;
/// shapes carry an anchor + opposite corner/endpoint (screen space).
enum AnnotationKind: Equatable {
    case freehand([CGPoint])
    case line(CGPoint, CGPoint)
    case arrow(CGPoint, CGPoint)
    case rect(CGPoint, CGPoint)
    case ellipse(CGPoint, CGPoint)
}

/// A single committed (or in-progress) annotation. Geometry is stored raw and
/// re-rendered at draw time by `AnnotationRenderer`, so smoothing/glow can be
/// tweaked without re-recording.
struct AnnotationElement: Identifiable, Equatable {
    let id = UUID()
    var kind: AnnotationKind
    var color: AnnotationColor
    var thickness: AnnotationThickness
    var brush: BrushStyle

    /// True when there's enough geometry to draw something meaningful — drops
    /// single-click freehand strokes and zero-length shapes.
    var isDrawable: Bool {
        switch kind {
        case .freehand(let pts):
            return pts.count >= 2
        case .line(let a, let b), .arrow(let a, let b),
             .rect(let a, let b), .ellipse(let a, let b):
            return hypot(a.x - b.x, a.y - b.y) >= 3
        }
    }
}

/// Shared mutable state for the active annotation session. The canvas view
/// reads from this to know what tool/color/thickness to use for new elements;
/// the palette writes into it.
///
/// `isRecording` + `elapsedTime` are written by the recording host
/// (CaptureSessionManager) so the palette can switch from its pre-capture
/// layout ("Start Recording" button) to its recording layout (timer + Stop
/// button) without an extra view-tree rebuild.
@MainActor
final class AnnotationState: ObservableObject {
    @Published var tool: AnnotationTool = .pen
    @Published var color: AnnotationColor = .yellow
    @Published var thickness: AnnotationThickness = .medium
    @Published var elements: [AnnotationElement] = []

    @Published var isRecording: Bool = false
    @Published var elapsedTime: TimeInterval = 0

    /// Whether the canvas window captures mouse input. When false, the canvas
    /// becomes a click-through overlay: existing elements stay visible (and
    /// remain in the recording) but the user can interact with apps
    /// underneath. The palette stays interactive in both states.
    @Published var isCanvasActive: Bool = true

    func append(_ element: AnnotationElement) {
        guard element.isDrawable else { return }
        elements.append(element)
    }

    func undo() {
        guard !elements.isEmpty else { return }
        elements.removeLast()
    }

    func clear() {
        elements.removeAll()
    }
}
