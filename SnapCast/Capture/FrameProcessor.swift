import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

class FrameProcessor: NSObject, SCStreamOutput {
    private let cropRect: CGRect?
    private let targetSize: CGSize?
    private let lock = NSLock()
    private var _frames: [(CGImage, TimeInterval)] = []

    var frames: [(CGImage, TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return _frames
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frames.count
    }

    private var firstTimestamp: TimeInterval?

    init(cropRect: CGRect?, targetSize: CGSize?) {
        self.cropRect = cropRect
        self.targetSize = targetSize
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let fullRect = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard var cgImage = context.createCGImage(ciImage, from: fullRect) else { return }

        // Crop if region mode
        if let crop = cropRect {
            let scaleX = CGFloat(cgImage.width) / fullRect.width
            let scaleY = CGFloat(cgImage.height) / fullRect.height
            let scaledCrop = CGRect(
                x: crop.origin.x * scaleX,
                y: crop.origin.y * scaleY,
                width: crop.width * scaleX,
                height: crop.height * scaleY
            )
            if let cropped = cgImage.cropping(to: scaledCrop) {
                cgImage = cropped
            }
        }

        // Resize if needed
        if let size = targetSize {
            let targetW = Int(size.width)
            let targetH = Int(size.height)
            if cgImage.width != targetW || cgImage.height != targetH {
                if let resized = resizeImage(cgImage, to: CGSize(width: targetW, height: targetH)) {
                    cgImage = resized
                }
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(pts)

        lock.lock()
        if firstTimestamp == nil {
            firstTimestamp = timestamp
        }
        let relativeTime = timestamp - (firstTimestamp ?? timestamp)
        _frames.append((cgImage, relativeTime))
        lock.unlock()
    }

    private func resizeImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}
