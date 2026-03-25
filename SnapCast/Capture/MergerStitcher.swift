import AppKit
import CoreGraphics

/// A single capture in the merger session.
struct MergerCapture: Identifiable {
    let id = UUID()
    let image: CGImage

    /// Pre-computed thumbnail for the UI.
    var thumbnail: NSImage {
        let maxDim: CGFloat = 80
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(maxDim / w, maxDim / h, 1.0)
        let tw = Int(w * scale)
        let th = Int(h * scale)

        let nsImage = NSImage(cgImage: image, size: NSSize(width: tw, height: th))
        return nsImage
    }
}

/// Stitches an array of CGImages into one image, either vertically or horizontally.
enum MergerStitcher {

    static func stitchVertical(_ images: [CGImage]) throws -> CGImage {
        guard !images.isEmpty else { throw ScreenshotError.noContent }
        if images.count == 1 { return images[0] }

        let maxWidth = images.map { $0.width }.max()!
        let totalHeight = images.reduce(0) { $0 + $1.height }

        guard let cs = images[0].colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: maxWidth, height: totalHeight,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                             CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ScreenshotError.saveFailed }

        // Draw top to bottom (CG origin is bottom-left)
        var y = totalHeight
        for img in images {
            y -= img.height
            // Center horizontally if widths differ
            let x = (maxWidth - img.width) / 2
            ctx.draw(img, in: CGRect(x: x, y: y, width: img.width, height: img.height))
        }

        guard let result = ctx.makeImage() else { throw ScreenshotError.saveFailed }
        return result
    }

    static func stitchHorizontal(_ images: [CGImage]) throws -> CGImage {
        guard !images.isEmpty else { throw ScreenshotError.noContent }
        if images.count == 1 { return images[0] }

        let totalWidth = images.reduce(0) { $0 + $1.width }
        let maxHeight = images.map { $0.height }.max()!

        guard let cs = images[0].colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: totalWidth, height: maxHeight,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                             CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ScreenshotError.saveFailed }

        // Draw left to right
        var x = 0
        for img in images {
            // Center vertically if heights differ
            let y = (maxHeight - img.height) / 2
            ctx.draw(img, in: CGRect(x: x, y: y, width: img.width, height: img.height))
            x += img.width
        }

        guard let result = ctx.makeImage() else { throw ScreenshotError.saveFailed }
        return result
    }
}
