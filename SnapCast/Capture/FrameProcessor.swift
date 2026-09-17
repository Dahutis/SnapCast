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

    private let overlay: RecordingOverlay?
    private let frameInterval: TimeInterval
    // Clean (caption-free) copy of the newest frame + its host time, guarded by `lock`.
    private var lastRawImage: CGImage?
    private var lastTimestamp: TimeInterval?
    /// Re-emits the last frame while overlay captions/clicks animate over a
    /// static screen, since SCKit sends no frames when nothing changes.
    private var overlayTicker: DispatchSourceTimer?

    init(cropRect: CGRect?, targetSize: CGSize?, overlay: RecordingOverlay? = nil, fps: Int = 15) {
        self.cropRect = cropRect
        self.targetSize = targetSize
        self.overlay = overlay
        self.frameInterval = 1 / Double(max(fps, 1))
        super.init()

        if overlay != nil {
            let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            ticker.schedule(deadline: .now(), repeating: frameInterval)
            ticker.setEventHandler { [weak self] in self?.tickOverlay() }
            ticker.resume()
            overlayTicker = ticker
        }
    }

    /// Stops the overlay ticker. Call once the stream has stopped, before
    /// reading `frames`.
    func stop() {
        overlayTicker?.cancel()
        overlayTicker = nil
    }

    deinit { overlayTicker?.cancel() }

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
        store(cgImage, at: CMTimeGetSeconds(pts))
    }

    /// Burns in any visible overlay (keys, clicks) and appends the frame.
    private func store(_ raw: CGImage, at timestamp: TimeInterval) {
        var image = raw
        if let overlay, let composited = overlay.composite(onto: raw, at: timestamp) {
            image = composited
        }

        lock.lock()
        defer { lock.unlock() }
        if let last = lastTimestamp, timestamp <= last { return }
        if firstTimestamp == nil {
            firstTimestamp = timestamp
        }
        let relativeTime = timestamp - (firstTimestamp ?? timestamp)
        _frames.append((image, relativeTime))
        lastRawImage = raw
        lastTimestamp = timestamp
    }

    private func tickOverlay() {
        guard let overlay else { return }
        lock.lock()
        let raw = lastRawImage
        let last = lastTimestamp
        lock.unlock()

        let now = KeystrokeTimeline.now
        guard let raw, let last,
              now - last >= frameInterval * 1.5,
              overlay.needsFrame(at: now) else { return }
        store(raw, at: now)
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
