import AppKit
import ScreenCaptureKit
import CoreMedia
import Combine

@MainActor
class CaptureSessionManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var capturedFrameCount = 0
    @Published var lastExportedURL: URL?
    @Published var isExporting = false
    @Published var exportError: String?
    @Published var isTakingScreenshot = false
    @Published var scrollProgress: String?

    // Merger state
    @Published var mergerCaptures: [MergerCapture] = []
    @Published var mergeDirection: MergeDirection = .vertical
    @Published var isMergerActive = false

    let settings: CaptureSettings

    /// Set by MenuBarController so we can dismiss the popover before capture
    nonisolated(unsafe) var onCaptureStarting: (() -> Void)?

    private var stream: SCStream?
    private var frameProcessor: FrameProcessor?
    private var timer: Timer?
    private var startTime: Date?
    private var delayTimer: Timer?
    private var cropRect: CGRect?

    init(settings: CaptureSettings) {
        self.settings = settings
        super.init()
    }

    // MARK: - Public API

    func startCapture() {
        guard !isRecording else { return }

        exportError = nil
        lastExportedURL = nil

        // Close the popover before starting
        onCaptureStarting?()

        let delay = settings.captureDelay
        if delay > 0 {
            var remaining = delay
            delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    Task { @MainActor [weak self] in
                        self?.delayTimer = nil
                        self?.beginCapture()
                    }
                }
            }
        } else {
            beginCapture()
        }
    }

    func stopCapture() {
        guard isRecording else { return }
        Task {
            await finalizeCapture()
        }
    }

    func cancelCapture() {
        delayTimer?.invalidate()
        delayTimer = nil
        if isRecording {
            Task {
                try? await stream?.stopCapture()
                stream = nil
                isRecording = false
                timer?.invalidate()
                timer = nil
                frameProcessor = nil
            }
        }
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard !isRecording, !isTakingScreenshot else { return }

        exportError = nil
        lastExportedURL = nil

        onCaptureStarting?()
        isTakingScreenshot = true

        let mode = settings.screenshotMode
        if mode == .fullPage {
            scrollProgress = "Loading page..."
        }

        Task {
            do {
                let url = try await ScreenshotCapture.capture(mode: mode, settings: settings)
                self.lastExportedURL = url
                self.isTakingScreenshot = false
                self.scrollProgress = nil
            } catch let error as ScreenshotError where error.errorDescription == "Screenshot cancelled" {
                self.isTakingScreenshot = false
                self.scrollProgress = nil
            } catch {
                self.exportError = error.localizedDescription
                self.isTakingScreenshot = false
                self.scrollProgress = nil
            }
        }
    }

    // MARK: - Merger

    func startMerger() {
        mergerCaptures = []
        isMergerActive = true
        exportError = nil
        lastExportedURL = nil
    }

    func captureNextMergerFrame() {
        guard isMergerActive else { return }
        onCaptureStarting?()

        Task {
            guard let result = await RegionSelectionOverlay.selectRegion() else { return }
            let display = result.display
            let rect = result.rect

            do {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width * 2
                config.height = display.height * 2
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                if #available(macOS 14.0, *) {
                    config.captureResolution = .best
                }

                let fullImage = try await ScreenshotCapture.captureSingleFrame(
                    filter: filter, configuration: config
                )

                let scaleX = CGFloat(fullImage.width) / CGFloat(display.width)
                let scaleY = CGFloat(fullImage.height) / CGFloat(display.height)
                let scaledCrop = CGRect(
                    x: rect.origin.x * scaleX,
                    y: rect.origin.y * scaleY,
                    width: rect.width * scaleX,
                    height: rect.height * scaleY
                )

                if let cropped = fullImage.cropping(to: scaledCrop) {
                    let capture = MergerCapture(image: cropped)
                    self.mergerCaptures.append(capture)
                }
            } catch {
                self.exportError = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    func removeMergerCapture(at index: Int) {
        guard mergerCaptures.indices.contains(index) else { return }
        mergerCaptures.remove(at: index)
    }

    func moveMergerCapture(from source: IndexSet, to destination: Int) {
        mergerCaptures.move(fromOffsets: source, toOffset: destination)
    }

    func mergeAndSave() {
        guard !mergerCaptures.isEmpty else { return }

        isExporting = true
        let images = mergerCaptures.map { $0.image }
        let direction = mergeDirection

        Task.detached { [settings = self.settings] in
            do {
                let merged: CGImage
                if direction == .vertical {
                    merged = try MergerStitcher.stitchVertical(images)
                } else {
                    merged = try MergerStitcher.stitchHorizontal(images)
                }

                let final_ = ScreenshotCapture.applyResize(image: merged, settings: settings)
                let url = try ScreenshotCapture.saveImage(final_, settings: settings)

                await MainActor.run {
                    self.lastExportedURL = url
                    self.isExporting = false
                    self.isMergerActive = false
                    self.mergerCaptures = []
                }
            } catch {
                await MainActor.run {
                    self.exportError = "Merge failed: \(error.localizedDescription)"
                    self.isExporting = false
                }
            }
        }
    }

    func cancelMerger() {
        mergerCaptures = []
        isMergerActive = false
    }

    // MARK: - Private

    private func beginCapture() {
        Task {
            do {
                let filter: SCContentFilter
                let captureWidth: Int
                let captureHeight: Int

                switch settings.captureMode {
                case .region:
                    guard let result = await RegionSelectionOverlay.selectRegion() else { return }
                    let display = result.display
                    let rect = result.rect
                    self.cropRect = rect

                    filter = SCContentFilter(
                        display: display,
                        excludingWindows: []
                    )
                    captureWidth = display.width
                    captureHeight = display.height

                case .window:
                    guard let window = await WindowPicker.pickWindow() else { return }
                    filter = SCContentFilter(
                        desktopIndependentWindow: window
                    )
                    let frame = window.frame
                    captureWidth = Int(frame.width)
                    captureHeight = Int(frame.height)
                    self.cropRect = nil

                case .fullScreen:
                    guard let (display, excludedWindows) = await WindowPicker.pickDisplay() else { return }

                    filter = SCContentFilter(
                        display: display,
                        excludingWindows: excludedWindows
                    )
                    captureWidth = display.width
                    captureHeight = display.height
                    self.cropRect = nil
                }

                let config = SCStreamConfiguration()

                let outputWidth: Int
                let outputHeight: Int
                if settings.resizeEnabled {
                    if settings.maintainAspectRatio {
                        let aspect = Double(captureWidth) / Double(captureHeight)
                        outputWidth = settings.resizeWidth
                        outputHeight = Int(Double(settings.resizeWidth) / aspect)
                    } else {
                        outputWidth = settings.resizeWidth
                        outputHeight = settings.resizeHeight
                    }
                } else if let crop = self.cropRect {
                    outputWidth = Int(crop.width)
                    outputHeight = Int(crop.height)
                } else {
                    outputWidth = captureWidth
                    outputHeight = captureHeight
                }

                config.width = settings.captureMode == .region ? captureWidth : outputWidth
                config.height = settings.captureMode == .region ? captureHeight : outputHeight
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
                config.showsCursor = settings.captureCursor
                config.pixelFormat = kCVPixelFormatType_32BGRA

                frameProcessor = FrameProcessor(
                    cropRect: self.cropRect,
                    targetSize: (settings.resizeEnabled || self.cropRect != nil)
                        ? CGSize(width: outputWidth, height: outputHeight)
                        : nil
                )

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(frameProcessor!, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()

                self.stream = stream
                self.isRecording = true
                self.capturedFrameCount = 0
                self.elapsedTime = 0
                self.startTime = Date()

                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self = self, let start = self.startTime else { return }
                        self.elapsedTime = Date().timeIntervalSince(start)
                        self.capturedFrameCount = self.frameProcessor?.frameCount ?? 0

                        if self.elapsedTime >= Double(self.settings.maxDuration) {
                            self.stopCapture()
                        }
                    }
                }

            } catch {
                exportError = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func finalizeCapture() async {
        timer?.invalidate()
        timer = nil

        do {
            try await stream?.stopCapture()
        } catch {
            // Stream may already be stopped
        }
        stream = nil
        isRecording = false

        guard let processor = frameProcessor, !processor.frames.isEmpty else {
            exportError = "No frames captured"
            frameProcessor = nil
            return
        }

        isExporting = true
        let frames = processor.frames
        frameProcessor = nil

        Task.detached { [settings = self.settings] in
            do {
                let encoder: FrameEncoder = GIFEncoder()

                let url = try await encoder.encode(
                    frames: frames,
                    fps: settings.fps,
                    settings: settings
                )

                await MainActor.run {
                    self.lastExportedURL = url
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.exportError = "Export failed: \(error.localizedDescription)"
                    self.isExporting = false
                }
            }
        }
    }
}
