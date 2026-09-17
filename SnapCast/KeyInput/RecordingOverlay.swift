import CoreGraphics
import CoreVideo
import Foundation

/// Everything burned into recorded frames on top of the screen content: key
/// captions and click ripples. Recorders only talk to this type — it decides
/// whether a frame needs drawing and does the copy + draw.
final class RecordingOverlay: @unchecked Sendable {
    struct Keystrokes {
        let timeline: KeystrokeTimeline
        let renderer: KeystrokeOverlayRenderer
    }

    struct Clicks {
        let timeline: ClickTimeline
        /// Captured area in CG global points (top-left origin), used to map
        /// click locations into frame pixels.
        let captureRect: CGRect
    }

    let keystrokes: Keystrokes?
    let clicks: Clicks?

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init?(keystrokes: Keystrokes?, clicks: Clicks?) {
        guard keystrokes != nil || clicks != nil else { return nil }
        self.keystrokes = keystrokes
        self.clicks = clicks
    }

    /// True while something is animating at `time` (or just finished), so the
    /// recorder keeps emitting frames over a static screen.
    func needsFrame(at time: Double) -> Bool {
        keystrokes?.timeline.needsFrame(at: time) == true || clicks?.timeline.needsFrame(at: time) == true
    }

    // MARK: - Compositing

    /// Copies `source` into `destination` (both 32BGRA, same size) and draws
    /// the overlay on top. Returns false when nothing is visible at `time`,
    /// in which case `destination` is untouched and `source` should be used.
    func composite(source: CVPixelBuffer, destination: CVPixelBuffer, at time: Double) -> Bool {
        guard let content = content(at: time) else { return false }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width == CVPixelBufferGetWidth(destination), height == CVPixelBufferGetHeight(destination) else { return false }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(destination) else { return false }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(srcBytesPerRow, dstBytesPerRow)
        for row in 0..<height {
            memcpy(dst + row * dstBytesPerRow, src + row * srcBytesPerRow, rowBytes)
        }
        CVBufferPropagateAttachments(source, destination)

        guard let context = CGContext(
            data: dst, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: dstBytesPerRow, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo
        ) else { return false }
        draw(content, in: context, canvas: CGSize(width: width, height: height))
        return true
    }

    /// GIF path: a new image with the overlay drawn on top, or nil when
    /// nothing is visible at `time`.
    func composite(onto image: CGImage, at time: Double) -> CGImage? {
        guard let content = content(at: time),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo
              ) else { return nil }
        let canvas = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: canvas))
        draw(content, in: context, canvas: canvas)
        return context.makeImage()
    }

    // MARK: - Private

    private struct Content {
        let captions: [KeystrokeTimeline.VisibleCaption]
        let clicks: [ClickTimeline.VisibleClick]
    }

    private func content(at time: Double) -> Content? {
        let captions = keystrokes?.timeline.visibleCaptions(at: time) ?? []
        let clicks = clicks?.timeline.visibleClicks(at: time) ?? []
        guard !captions.isEmpty || !clicks.isEmpty else { return nil }
        return Content(captions: captions, clicks: clicks)
    }

    private func draw(_ content: Content, in context: CGContext, canvas: CGSize) {
        // Clicks first so key captions stay readable on top.
        if let clicks, !content.clicks.isEmpty {
            ClickTimeline.draw(content.clicks, captureRect: clicks.captureRect, in: context, canvas: canvas)
        }
        if let keystrokes, !content.captions.isEmpty {
            keystrokes.renderer.draw(content.captions, in: context, canvas: canvas)
        }
    }
}
