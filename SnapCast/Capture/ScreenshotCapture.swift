import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Handles single-frame screenshot capture for Region, Window, and Full Screen modes.
class ScreenshotCapture {

    /// Captures a single screenshot based on the given mode and settings, saves to disk, returns the file URL.
    @MainActor
    static func capture(mode: ScreenshotMode, settings: CaptureSettings, forceAnnotate: Bool = false) async throws -> URL {
        let image: CGImage
        let annotate = forceAnnotate || settings.annotateBeforeCapture

        switch mode {
        case .region:
            image = try await captureRegion(settings: settings, annotate: annotate)
        case .window:
            image = try await captureWindow(settings: settings)
        case .fullScreen:
            image = try await captureFullScreen(settings: settings, annotate: annotate)
        case .fullPage:
            return try await FullPageCapture.capture(url: settings.fullPageURL, settings: settings)
        }

        let finalImage = applyResize(image: image, settings: settings)
        return try saveImage(finalImage, settings: settings)
    }

    // MARK: - Region

    @MainActor
    private static func captureRegion(settings: CaptureSettings, annotate: Bool) async throws -> CGImage {
        guard let result = await RegionSelectionOverlay.selectRegion() else {
            throw ScreenshotError.cancelled
        }

        let display = result.display
        let rect = result.rect

        // Annotation overlay (if enabled): show canvas + palette over the
        // selected region, wait for the user to draw and click Done. The
        // canvas stays on screen during capture so the strokes land in the
        // SCKit frame naturally — only the palette is hidden first to keep
        // the floating UI out of the captured image.
        let annotation: AnnotationSession?
        if annotate {
            let session = AnnotationSession(
                targetRect: result.globalRect,
                screen: result.screen
            )
            let outcome = await session.present()
            if outcome == .cancel {
                session.dismiss()
                throw ScreenshotError.cancelled
            }
            session.hidePalette()
            annotation = session
        } else {
            annotation = nil
        }
        defer { annotation?.dismiss() }

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
    private static func captureFullScreen(settings: CaptureSettings, annotate: Bool) async throws -> CGImage {
        guard let (display, excludedWindows) = await WindowPicker.pickDisplay() else {
            throw ScreenshotError.cancelled
        }

        // For full-screen captures we anchor the annotation canvas to the
        // NSScreen backing `display`. Pre-canvas excludedWindows already
        // omits the canvas (it doesn't exist yet at this point), so the
        // canvas's strokes land in the captured frame.
        let annotation: AnnotationSession?
        if annotate,
           let screen = matchingScreen(for: display) {
            let session = AnnotationSession(targetRect: screen.frame, screen: screen)
            let outcome = await session.present()
            if outcome == .cancel {
                session.dismiss()
                throw ScreenshotError.cancelled
            }
            session.hidePalette()
            annotation = session
        } else {
            annotation = nil
        }
        defer { annotation?.dismiss() }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = settings.captureCursor

        return try await captureSingleFrame(filter: filter, configuration: config)
    }

    /// Finds the NSScreen whose backing display matches the given SCDisplay.
    private static func matchingScreen(for display: SCDisplay) -> NSScreen? {
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            if id == display.displayID { return screen }
        }
        return NSScreen.main
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
