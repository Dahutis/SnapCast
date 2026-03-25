import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Handles single-frame screenshot capture for Region, Window, and Full Screen modes.
class ScreenshotCapture {

    /// Captures a single screenshot based on the given mode and settings, saves to disk, returns the file URL.
    @MainActor
    static func capture(mode: ScreenshotMode, settings: CaptureSettings) async throws -> URL {
        let image: CGImage

        switch mode {
        case .region:
            image = try await captureRegion(settings: settings)
        case .window:
            image = try await captureWindow(settings: settings)
        case .fullScreen:
            image = try await captureFullScreen(settings: settings)
        case .fullPage:
            return try await FullPageCapture.capture(url: settings.fullPageURL, settings: settings)
        }

        let finalImage = applyResize(image: image, settings: settings)
        return try saveImage(finalImage, settings: settings)
    }

    // MARK: - Region

    @MainActor
    private static func captureRegion(settings: CaptureSettings) async throws -> CGImage {
        guard let result = await RegionSelectionOverlay.selectRegion() else {
            throw ScreenshotError.cancelled
        }

        let display = result.display
        let rect = result.rect

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = settings.captureCursor

        let fullImage = try await captureSingleFrame(filter: filter, configuration: config)

        // Crop to selected region
        let scaleX = CGFloat(fullImage.width) / CGFloat(display.width)
        let scaleY = CGFloat(fullImage.height) / CGFloat(display.height)
        let scaledCrop = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        guard let cropped = fullImage.cropping(to: scaledCrop) else {
            throw ScreenshotError.cropFailed
        }
        return cropped
    }

    // MARK: - Window

    @MainActor
    private static func captureWindow(settings: CaptureSettings) async throws -> CGImage {
        guard let window = await WindowPicker.pickWindow() else {
            throw ScreenshotError.cancelled
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2 // Retina
        config.height = Int(window.frame.height) * 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = settings.captureCursor
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        return try await captureSingleFrame(filter: filter, configuration: config)
    }

    // MARK: - Full Screen

    @MainActor
    private static func captureFullScreen(settings: CaptureSettings) async throws -> CGImage {
        guard let (display, excludedWindows) = await WindowPicker.pickDisplay() else {
            throw ScreenshotError.cancelled
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = settings.captureCursor

        return try await captureSingleFrame(filter: filter, configuration: config)
    }

    // MARK: - Single Frame Capture

    /// Captures a single frame using SCScreenshotManager (macOS 14+) or SCStream fallback (macOS 13).
    static func captureSingleFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } else {
            return try await captureSingleFrameViaStream(filter: filter, configuration: configuration)
        }
    }

    /// Fallback for macOS 13: start an SCStream, grab one frame, stop.
    private static func captureSingleFrameViaStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            let handler = SingleFrameHandler(continuation: continuation)

            do {
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))

                handler.stream = stream

                Task {
                    do {
                        try await stream.startCapture()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    static func applyResize(image: CGImage, settings: CaptureSettings) -> CGImage {
        guard settings.resizeEnabled else { return image }

        let targetWidth: Int
        let targetHeight: Int

        if settings.maintainAspectRatio {
            let aspect = Double(image.width) / Double(image.height)
            targetWidth = settings.resizeWidth
            targetHeight = Int(Double(settings.resizeWidth) / aspect)
        } else {
            targetWidth = settings.resizeWidth
            targetHeight = settings.resizeHeight
        }

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: targetWidth,
                  height: targetHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return ctx.makeImage() ?? image
    }

    static func saveImage(_ image: CGImage, settings: CaptureSettings) throws -> URL {
        let url = settings.outputFileURL(extension: settings.screenshotFormat.fileExtension)

        let uti: CFString
        let properties: CFDictionary?

        switch settings.screenshotFormat {
        case .png:
            uti = "public.png" as CFString
            properties = nil
        case .jpeg:
            uti = "public.jpeg" as CFString
            properties = [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            throw ScreenshotError.saveFailed
        }

        CGImageDestinationAddImage(dest, image, properties)

        guard CGImageDestinationFinalize(dest) else {
            throw ScreenshotError.saveFailed
        }

        return url
    }
}

// MARK: - Single Frame Stream Handler (macOS 13 fallback)

private class SingleFrameHandler: NSObject, SCStreamOutput {
    private let continuation: CheckedContinuation<CGImage, Error>
    private var hasResumed = false
    private let lock = NSLock()
    var stream: SCStream?

    init(continuation: CheckedContinuation<CGImage, Error>) {
        self.continuation = continuation
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        lock.unlock()

        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            continuation.resume(throwing: ScreenshotError.noContent)
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let fullRect = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard let cgImage = context.createCGImage(ciImage, from: fullRect) else {
            continuation.resume(throwing: ScreenshotError.noContent)
            return
        }

        // Stop the stream
        Task {
            try? await self.stream?.stopCapture()
        }

        continuation.resume(returning: cgImage)
    }
}

// MARK: - Errors

enum ScreenshotError: LocalizedError {
    case cancelled
    case cropFailed
    case saveFailed
    case noContent
    case scrollingFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Screenshot cancelled"
        case .cropFailed: return "Failed to crop image"
        case .saveFailed: return "Failed to save screenshot"
        case .noContent: return "No content captured"
        case .scrollingFailed(let reason): return "Scrolling capture failed: \(reason)"
        }
    }
}
