import CoreGraphics
import CoreText
import Foundation

/// Draws key caption bubbles into frames. Sizes scale with the frame height so
/// a small region and a 5K display get proportionally similar bubbles.
/// Bubbles are cached per text, so steady-state frames only blit images.
final class KeystrokeOverlayRenderer: @unchecked Sendable {
    private let position: KeystrokePosition
    private let size: KeystrokeSize

    private let lock = NSLock()
    private var cache: [String: CGImage] = [:]
    private static let maxCacheEntries = 64

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(position: KeystrokePosition, size: KeystrokeSize) {
        self.position = position
        self.size = size
    }

    // MARK: - Layout

    /// Stacks bubbles from the chosen edge inward, newest closest to the edge.
    func draw(_ captions: [KeystrokeTimeline.VisibleCaption], in context: CGContext, canvas: CGSize) {
        let fontSize = max(13, (canvas.height * size.heightFraction).rounded())
        let margin = max(8, canvas.height * 0.04)
        let spacing = fontSize * 0.3
        let maxWidth = canvas.width - margin * 2
        let fromTop = position == .topCenter

        var edge = fromTop ? canvas.height - margin : margin
        for caption in captions.reversed() {
            guard let bubble = bubble(for: caption.text, fontSize: fontSize) else { continue }
            var width = CGFloat(bubble.width)
            var height = CGFloat(bubble.height)
            if width > maxWidth {
                let scale = maxWidth / width
                width *= scale
                height *= scale
            }

            let x: CGFloat
            switch position {
            case .bottomLeft: x = margin
            case .bottomRight: x = canvas.width - margin - width
            case .bottomCenter, .topCenter: x = (canvas.width - width) / 2
            }
            let y = fromTop ? edge - height : edge

            context.saveGState()
            context.setAlpha(caption.alpha)
            context.interpolationQuality = .high
            context.draw(bubble, in: CGRect(x: x, y: y, width: width, height: height))
            context.restoreGState()

            edge = fromTop ? y - spacing : y + height + spacing
        }
    }

    private func bubble(for text: String, fontSize: CGFloat) -> CGImage? {
        let key = "\(Int(fontSize))|\(text)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let padX = fontSize * 0.6
        let padY = fontSize * 0.34
        let width = Int(ceil(textWidth + padX * 2))
        let height = Int(ceil(ascent + descent + padY * 2))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo
        ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = min(CGFloat(height) / 2, fontSize * 0.45)
        let lineWidth = max(1, fontSize * 0.04)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(gray: 0.08, alpha: 0.82))
        context.fillPath()
        let borderRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.addPath(CGPath(roundedRect: borderRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        context.setLineWidth(lineWidth)
        context.strokePath()

        context.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(line, context)

        let image = context.makeImage()
        if cache.count >= Self.maxCacheEntries { cache.removeAll() }
        cache[key] = image
        return image
    }
}
