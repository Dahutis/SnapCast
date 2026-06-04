import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One frame of editable content. Stills are represented as a single-frame
/// document; GIFs carry one Frame per animation frame.
struct EditorFrame: Identifiable, Equatable {
    let id = UUID()
    var image: CGImage
    var delay: TimeInterval

    static func == (lhs: EditorFrame, rhs: EditorFrame) -> Bool { lhs.id == rhs.id }
}

/// Editable post-process document. Holds the base frames (with any baked
/// rotation) plus the non-destructive edit state — annotations, crop, resize,
/// speed, and GIF timeline trimming. The view layer renders previews via
/// `ImageComposer`; export bakes everything into new files.
///
/// Coordinate convention: crop rect and annotation elements live in **base
/// image pixel space, bottom-left origin** — identical to the live annotation
/// canvas — so `AnnotationRenderer` is reused unchanged.
@MainActor
final class EditorDocument: ObservableObject {
    let isAnimated: Bool
    let sourceURL: URL?
    let settings: CaptureSettings

    @Published var frames: [EditorFrame]
    @Published var baseFps: Int

    /// Shared tool/color/thickness/elements state — reused from the live
    /// annotation system so shapes & brushes behave identically here.
    let annotation = AnnotationState()

    // Non-destructive edits
    @Published var cropRect: CGRect?          // base pixel space, bottom-left; nil = full
    @Published var rotationQuarters: Int = 0  // count of 90° CW rotations baked into frames
    @Published var resizeWidth: Int?          // nil = native; output width in px
    @Published var speedMultiplier: Double = 1.0

    // GIF timeline
    @Published var previewIndex: Int = 0
    @Published var selectedFrames: Set<Int> = []
    @Published var trimStart: Int = 0
    @Published var trimEnd: Int = 0           // inclusive

    // Editor UI mode
    @Published var isCropping: Bool = false
    @Published var isExporting: Bool = false
    @Published var lastSavedURL: URL?

    init(frames: [EditorFrame], isAnimated: Bool, baseFps: Int, sourceURL: URL?, settings: CaptureSettings) {
        self.frames = frames
        self.isAnimated = isAnimated
        self.baseFps = max(1, baseFps)
        self.sourceURL = sourceURL
        self.settings = settings
        self.trimEnd = max(0, frames.count - 1)
    }

    /// Build a document by decoding a saved capture (PNG/JPEG/GIF).
    static func load(url: URL, settings: CaptureSettings) -> EditorDocument? {
        guard let decoded = ImageComposer.load(url: url) else { return nil }
        let frames = decoded.frames.map { EditorFrame(image: $0.0, delay: $0.1) }
        guard !frames.isEmpty else { return nil }
        let avgDelay = decoded.frames.map(\.1).reduce(0, +) / Double(max(1, decoded.frames.count))
        let fps = avgDelay > 0 ? Int((1.0 / avgDelay).rounded()) : settings.fps
        return EditorDocument(
            frames: frames,
            isAnimated: decoded.isAnimated,
            baseFps: min(60, max(1, fps)),
            sourceURL: url,
            settings: settings
        )
    }

    var baseSize: CGSize {
        guard let first = frames.first else { return .zero }
        return CGSize(width: first.image.width, height: first.image.height)
    }

    /// Frame currently shown in the canvas.
    var previewImage: CGImage? {
        guard frames.indices.contains(previewIndex) else { return frames.first?.image }
        return frames[previewIndex].image
    }

    /// Indices that survive trim + removal, in order.
    var keptIndices: [Int] {
        guard isAnimated else { return Array(frames.indices) }
        let lo = min(trimStart, trimEnd)
        let hi = max(trimStart, trimEnd)
        return (lo...hi).filter { !selectedFrames.contains($0) }
    }

    var exportFps: Int {
        max(1, min(60, Int((Double(baseFps) * speedMultiplier).rounded())))
    }

    // MARK: - Mutations

    func rotateCW() {
        let w = CGFloat(baseSize.width)
        frames = frames.map { EditorFrame(image: ImageComposer.rotateCW($0.image), delay: $0.delay) }
        annotation.elements = annotation.elements.map { ImageComposer.rotateElementCW($0, imageWidth: w) }
        if let c = cropRect { cropRect = ImageComposer.rotateRectCW(c, imageWidth: w) }
        rotationQuarters = (rotationQuarters + 1) % 4
    }

    func resetCrop() { cropRect = nil }

    func removeSelectedFrames() {
        guard !selectedFrames.isEmpty else { return }
        let survivors = frames.enumerated().filter { !selectedFrames.contains($0.offset) }.map(\.element)
        guard !survivors.isEmpty else { return }   // never delete everything
        frames = survivors
        selectedFrames = []
        trimStart = 0
        trimEnd = frames.count - 1
        previewIndex = min(previewIndex, frames.count - 1)
    }

    // MARK: - Export

    /// Compose the current preview frame with all edits applied. Used for the
    /// live canvas isn't this — the canvas draws layers itself — but the export
    /// path and any "flatten" preview use it.
    func renderedFrame(at index: Int) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        return ImageComposer.compose(
            base: frames[index].image,
            elements: annotation.elements,
            cropRect: cropRect,
            resizeWidth: resizeWidth
        )
    }

    /// Bake edits and write a new file next to the configured output folder.
    /// Returns the saved URL.
    func export() async throws -> URL {
        if isAnimated {
            let composed: [(CGImage, TimeInterval)] = keptIndices.compactMap { idx in
                guard let img = renderedFrame(at: idx) else { return nil }
                return (img, frames[idx].delay)
            }
            guard !composed.isEmpty else { throw EditorExportError.nothingToExport }
            // GIFEncoder uses a uniform delay derived from fps; speed is folded
            // into exportFps so the timeline edit is honored.
            return try await GIFEncoder().encode(frames: composed, fps: exportFps, settings: settings)
        } else {
            guard let img = renderedFrame(at: 0) else { throw EditorExportError.nothingToExport }
            let url = settings.outputFileURL(extension: settings.screenshotFormat.fileExtension)
            try EditorExport.saveStill(img, format: settings.screenshotFormat, to: url)
            return url
        }
    }
}

enum EditorExportError: LocalizedError {
    case nothingToExport
    case writeFailed
    var errorDescription: String? {
        switch self {
        case .nothingToExport: return "Nothing to export"
        case .writeFailed:     return "Could not write the file"
        }
    }
}

// MARK: - Image compositing

/// Pure image operations shared by preview + export. All annotation/crop
/// geometry is in base pixel space, bottom-left origin.
enum ImageComposer {

    /// Draw the base frame with annotations baked on top, then apply crop and
    /// resize. Returns a new CGImage.
    static func compose(base: CGImage, elements: [AnnotationElement], cropRect: CGRect?, resizeWidth: Int?) -> CGImage {
        let annotated = render(base: base, elements: elements)
        let cropped = cropRect.flatMap { crop(annotated, to: $0) } ?? annotated
        if let w = resizeWidth, w > 0, w != cropped.width {
            return resize(cropped, toWidth: w)
        }
        return cropped
    }

    /// Base image + annotation layer at native resolution.
    static func render(base: CGImage, elements: [AnnotationElement]) -> CGImage {
        let w = base.width, h = base.height
        guard let rep = bitmapRep(width: w, height: h),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return base }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        AnnotationRenderer.draw(elements)
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage ?? base
    }

    /// Crop using a bottom-left rect, converting to CGImage's top-left space.
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let H = CGFloat(image.height)
        let topLeft = CGRect(
            x: rect.minX,
            y: H - rect.maxY,
            width: rect.width,
            height: rect.height
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = topLeft.intersection(bounds)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }

    static func resize(_ image: CGImage, toWidth targetW: Int) -> CGImage {
        let aspect = CGFloat(image.height) / CGFloat(image.width)
        let targetH = max(1, Int((CGFloat(targetW) * aspect).rounded()))
        guard let rep = bitmapRep(width: targetW, height: targetH),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.interpolationQuality = .high
        ctx.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage ?? image
    }

    /// Rotate a CGImage 90° clockwise. New size is (height, width). Matches
    /// `rotateElementCW`/`rotateRectCW` so baked rotation keeps annotations
    /// aligned.
    static func rotateCW(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard let rep = bitmapRep(width: h, height: w),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: CGFloat(w))
        cg.rotate(by: -.pi / 2)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage ?? image
    }

    /// Point map for a 90° CW rotation in bottom-left space: (x,y) -> (y, W-x).
    static func rotateElementCW(_ element: AnnotationElement, imageWidth W: CGFloat) -> AnnotationElement {
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.y, y: W - p.x) }
        var e = element
        switch element.kind {
        case .freehand(let pts):     e.kind = .freehand(pts.map(map))
        case .line(let a, let b):    e.kind = .line(map(a), map(b))
        case .arrow(let a, let b):   e.kind = .arrow(map(a), map(b))
        case .rect(let a, let b):    e.kind = .rect(map(a), map(b))
        case .ellipse(let a, let b): e.kind = .ellipse(map(a), map(b))
        }
        return e
    }

    static func rotateRectCW(_ rect: CGRect, imageWidth W: CGFloat) -> CGRect {
        CGRect(x: rect.minY, y: W - rect.maxX, width: rect.height, height: rect.width)
    }

    // MARK: - Decode

    static func load(url: URL) -> (frames: [(CGImage, TimeInterval)], isAnimated: Bool)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [(CGImage, TimeInterval)] = []
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append((img, gifDelay(src, index: i)))
        }
        guard !frames.isEmpty else { return nil }
        return (frames, count > 1)
    }

    private static func gifDelay(_ src: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let delay = gif[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }

    private static func bitmapRep(width: Int, height: Int) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        rep?.size = NSSize(width: width, height: height)
        return rep
    }
}

// MARK: - Still export

enum EditorExport {
    static func saveStill(_ image: CGImage, format: ScreenshotFormat, to url: URL) throws {
        let utType: UTType = format == .png ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            throw EditorExportError.writeFailed
        }
        var options: [CFString: Any] = [:]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EditorExportError.writeFailed }
    }
}
