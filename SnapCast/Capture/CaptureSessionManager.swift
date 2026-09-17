import AppKit
import ScreenCaptureKit
import CoreMedia
import Combine

enum ClipboardHelper {
    /// Copies an exported capture to the general pasteboard. Always writes the
    /// file URL (paste into Finder, Mail, Slack, Notion, Messages, etc.). For
    /// non-animated images, also writes the bitmap so image editors (Photoshop,
    /// Preview "New from Clipboard") accept a paste. GIFs skip the bitmap path
    /// because NSImage round-tripping through the pasteboard loses animation.
    static func copyExportedFile(at url: URL, isAnimated: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardWriting] = [url as NSURL]
        if !isAnimated, let image = NSImage(contentsOf: url) {
            items.append(image)
        }
        pb.writeObjects(items)
    }
}

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
    private var videoRecorder: VideoRecorder?
    private var microphone: MicrophoneCapture?
    private var keystrokeMonitor: KeystrokeMonitor?
    /// Pushes volume slider changes into the active VideoRecorder.
    private var volumeObservers: Set<AnyCancellable> = []
    private var timer: Timer?
    private var startTime: Date?
    private var delayTimer: Timer?
    private var cropRect: CGRect?

    /// Active annotation session for the current recording (if any). Kept on
    /// the manager so the canvas stays alive for the entire recording and the
    /// palette's Stop button can route through us.
    private var annotationSession: AnnotationSession?

    init(settings: CaptureSettings) {
        self.settings = settings
        super.init()
    }

    // MARK: - Export finishing

    /// Single tail for every capture path: record the URL, optionally copy to
    /// the clipboard, show the toast, and open the post-process editor.
    func finishExport(url: URL, isAnimated: Bool) {
        lastExportedURL = url
        if settings.copyToClipboard {
            ClipboardHelper.copyExportedFile(at: url, isAnimated: isAnimated)
        }
        if settings.showCaptureToast {
            CaptureToast.shared.show(imageURL: url)
        }
        if settings.openEditorAfterCapture {
            PostProcessController.shared.open(url: url)
        }
    }

    // MARK: - Public API

    func startCapture(mode: CaptureMode? = nil, forceAnnotate: Bool = false) {
        guard !isRecording else { return }

        exportError = nil
        lastExportedURL = nil

        // Close the popover before starting
        onCaptureStarting?()

        let resolvedMode = mode ?? settings.captureMode
        let delay = settings.captureDelay
        if delay > 0 {
            var remaining = delay
            delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    Task { @MainActor [weak self] in
                        self?.delayTimer = nil
                        self?.beginCapture(mode: resolvedMode, forceAnnotate: forceAnnotate)
                    }
                }
            }
        } else {
            beginCapture(mode: resolvedMode, forceAnnotate: forceAnnotate)
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
        annotationSession?.dismiss()
        annotationSession = nil
        if isRecording {
            Task {
                try? await stream?.stopCapture()
                stream = nil
                isRecording = false
                timer?.invalidate()
                timer = nil
                frameProcessor = nil
                microphone?.stop()
                microphone = nil
                stopKeystrokeCapture()
                videoRecorder?.cancel()
                videoRecorder = nil
                volumeObservers.removeAll()
            }
        }
    }

    // MARK: - Screenshot

    func takeScreenshot(mode overrideMode: ScreenshotMode? = nil, forceAnnotate: Bool = false) {
        guard !isRecording, !isTakingScreenshot else { return }

        exportError = nil
        lastExportedURL = nil

        onCaptureStarting?()
        isTakingScreenshot = true

        let mode = overrideMode ?? settings.screenshotMode
        if mode == .fullPage {
            scrollProgress = "Loading page..."
        }

        Task {
            do {
                let url = try await ScreenshotCapture.capture(mode: mode, settings: settings, forceAnnotate: forceAnnotate)
                self.finishExport(url: url, isAnimated: false)
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
                    self.finishExport(url: url, isAnimated: false)
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

    private func beginCapture(mode: CaptureMode, forceAnnotate: Bool = false) {
        Task {
            do {
                let filter: SCContentFilter
                let captureWidth: Int
                let captureHeight: Int

                // Annotation target rect (NSScreen global coords) — set
                // alongside each mode's selection so we know where to anchor
                // the canvas window. Window mode is intentionally skipped for
                // annotation; the window can be moved/resized mid-recording
                // and tracking that is a separate design problem.
                var annotationTargetRect: NSRect?
                var annotationScreen: NSScreen?

                // Video only: Retina scale of the captured screen and, for
                // region mode, the rect SCKit should crop to natively.
                var pixelScale: CGFloat = 1
                var videoSourceRect: CGRect?

                switch mode {
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
                    annotationTargetRect = result.globalRect
                    annotationScreen = result.screen
                    pixelScale = result.screen.backingScaleFactor
                    videoSourceRect = rect

                case .window:
                    guard let window = await WindowPicker.pickWindow() else { return }
                    filter = SCContentFilter(
                        desktopIndependentWindow: window
                    )
                    let frame = window.frame
                    captureWidth = Int(frame.width)
                    captureHeight = Int(frame.height)
                    self.cropRect = nil
                    pixelScale = Self.screen(containingCGRect: frame)?.backingScaleFactor ?? 2

                case .fullScreen:
                    guard let (display, excludedWindows) = await WindowPicker.pickDisplay() else { return }

                    filter = SCContentFilter(
                        display: display,
                        excludingWindows: excludedWindows
                    )
                    captureWidth = display.width
                    captureHeight = display.height
                    self.cropRect = nil

                    if let screen = Self.screen(forDisplayID: display.displayID) ?? NSScreen.main {
                        annotationTargetRect = screen.frame
                        annotationScreen = screen
                        pixelScale = screen.backingScaleFactor
                    }
                }

                // Annotation pre-pass: if enabled and we have a target rect,
                // present the canvas + palette and wait for the user to
                // either click Start Recording or cancel. The session stays
                // alive past this point — `enterRecordingMode()` happens once
                // the SCKit stream is up, and `dismiss()` is called in
                // finalize/cancel.
                if (forceAnnotate || settings.annotateBeforeCapture),
                   let rect = annotationTargetRect,
                   let screen = annotationScreen {
                    let session = AnnotationSession(
                        targetRect: rect,
                        screen: screen,
                        isRecordingMode: true
                    )
                    session.onStopRequested = { [weak self] in self?.stopCapture() }
                    let outcome = await session.present()
                    if outcome == .cancel {
                        session.dismiss()
                        return
                    }
                    self.annotationSession = session
                }

                let keystrokes = self.startKeystrokeCapture()

                if settings.outputFormat.isVideo {
                    try await self.startVideoStream(
                        filter: filter,
                        pointSize: CGSize(
                            width: videoSourceRect?.width ?? CGFloat(captureWidth),
                            height: videoSourceRect?.height ?? CGFloat(captureHeight)
                        ),
                        sourceRect: videoSourceRect,
                        pixelScale: pixelScale,
                        keystrokes: keystrokes
                    )
                    self.cropRect = nil
                    self.didStartStream(isVideo: true)
                    return
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

                config.width = mode == .region ? captureWidth : outputWidth
                config.height = mode == .region ? captureHeight : outputHeight
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
                config.showsCursor = settings.captureCursor
                config.pixelFormat = kCVPixelFormatType_32BGRA

                frameProcessor = FrameProcessor(
                    cropRect: self.cropRect,
                    targetSize: (settings.resizeEnabled || self.cropRect != nil)
                        ? CGSize(width: outputWidth, height: outputHeight)
                        : nil,
                    keystrokes: keystrokes,
                    fps: settings.fps
                )

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(frameProcessor!, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()

                self.stream = stream
                self.didStartStream(isVideo: false)

            } catch {
                exportError = "Capture failed: \(error.localizedDescription)"
                annotationSession?.dismiss()
                annotationSession = nil
                microphone?.stop()
                microphone = nil
                stopKeystrokeCapture()
                videoRecorder?.cancel()
                videoRecorder = nil
                volumeObservers.removeAll()
            }
        }
    }

    /// Shared post-start bookkeeping for GIF and video streams.
    private func didStartStream(isVideo: Bool) {
        isRecording = true
        capturedFrameCount = 0
        elapsedTime = 0
        startTime = Date()

        // Stream is live — flip the annotation palette into its
        // recording layout (Stop button + timer). Canvas keeps
        // accepting strokes the whole time.
        annotationSession?.enterRecordingMode()

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
                self.capturedFrameCount = self.videoRecorder?.frameCount ?? self.frameProcessor?.frameCount ?? 0
                self.annotationSession?.updateElapsed(self.elapsedTime)

                // Max duration is a GIF safeguard (frames live in memory);
                // video streams to disk and runs until stopped.
                if !isVideo, self.elapsedTime >= Double(self.settings.maxDuration) {
                    self.stopCapture()
                }
            }
        }
    }

    /// Configures SCKit to deliver frames already cropped (`sourceRect`) and
    /// scaled to the final pixel size, and pipes them into a VideoRecorder.
    private func startVideoStream(
        filter: SCContentFilter,
        pointSize: CGSize,
        sourceRect: CGRect?,
        pixelScale: CGFloat,
        keystrokes: KeystrokeOverlay?
    ) async throws {
        let codec = settings.videoCodec
        let fps = settings.videoFps

        var size = CGSize(width: pointSize.width * pixelScale, height: pointSize.height * pixelScale)
        if settings.resizeEnabled {
            if settings.maintainAspectRatio {
                let aspect = pointSize.width / pointSize.height
                size = CGSize(width: CGFloat(settings.resizeWidth), height: CGFloat(settings.resizeWidth) / aspect)
            } else {
                size = CGSize(width: settings.resizeWidth, height: settings.resizeHeight)
            }
        }
        let longest = max(size.width, size.height)
        if longest > CGFloat(codec.maxDimension) {
            let factor = CGFloat(codec.maxDimension) / longest
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }
        // Encoders require even dimensions for 4:2:0 chroma subsampling.
        let width = max(2, Int(size.width) & ~1)
        let height = max(2, Int(size.height) & ~1)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect {
            config.sourceRect = sourceRect
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = settings.captureCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8

        // Mic access is checked up front: a denied prompt shouldn't kill the
        // recording, it just records without the mic and says so.
        var recordMicrophone = settings.recordMicrophone
        if recordMicrophone, !(await MicrophoneCapture.requestAccess()) {
            recordMicrophone = false
            exportError = "Microphone access denied — recording without mic. Enable it in System Settings → Privacy & Security → Microphone."
        }

        let recordAudio = settings.recordSystemAudio
        if recordAudio {
            config.capturesAudio = true
            config.sampleRate = VideoRecorder.audioSampleRate
            config.channelCount = VideoRecorder.audioChannelCount
            // Keep SnapCast's own sounds (e.g. NSSound.beep) out of the track.
            config.excludesCurrentProcessAudio = true
        }

        let recorder = try VideoRecorder(
            outputURL: settings.outputFileURL(extension: OutputFormat.mp4.fileExtension),
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            quality: settings.videoQuality,
            recordSystemAudio: recordAudio,
            recordMicrophone: recordMicrophone,
            keystrokes: keystrokes
        )
        videoRecorder = recorder

        // @Published emits the current value on subscribe, so this also sets
        // the initial gains.
        settings.$systemAudioVolume
            .sink { [weak recorder] volume in recorder?.systemAudioGain = Float(volume) }
            .store(in: &volumeObservers)
        settings.$microphoneVolume
            .sink { [weak recorder] volume in recorder?.microphoneGain = Float(volume) }
            .store(in: &volumeObservers)

        if recordMicrophone {
            let mic = try MicrophoneCapture(deviceID: settings.microphoneDeviceID, queue: recorder.queue) { [weak recorder] sample in
                recorder?.appendMicrophone(sample)
            }
            mic.start()
            microphone = mic
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        if recordAudio {
            try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Starts listening for keys if "Show Keystrokes" is on. Returns nil (and
    /// records without captions) when Input Monitoring isn't granted.
    private func startKeystrokeCapture() -> KeystrokeOverlay? {
        guard settings.showKeystrokes else { return nil }

        let timeline = KeystrokeTimeline()
        let monitor = KeystrokeMonitor(
            timeline: timeline,
            mode: settings.keystrokeMode,
            ignoredShortcuts: Array(settings.shortcuts.values)
        )
        guard monitor.start() else {
            exportError = "Show Keystrokes needs Input Monitoring permission (Settings → Permissions) — recorded without key overlay."
            return nil
        }
        keystrokeMonitor = monitor
        return KeystrokeOverlay(
            timeline: timeline,
            renderer: KeystrokeOverlayRenderer(position: settings.keystrokePosition, size: settings.keystrokeSize)
        )
    }

    private func stopKeystrokeCapture() {
        keystrokeMonitor?.stop()
        keystrokeMonitor = nil
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    /// Screen with the largest overlap with a rect in CG global coordinates
    /// (top-left origin), e.g. `SCWindow.frame`.
    private static func screen(containingCGRect rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            func overlap(_ s: NSScreen) -> CGFloat {
                guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 0 }
                let i = CGDisplayBounds(id).intersection(rect)
                return i.isNull ? 0 : i.width * i.height
            }
            return overlap(a) < overlap(b)
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

        // Tear down the annotation overlay once the stream has stopped — the
        // last frame's already been pushed to the processor by this point, so
        // dismissing now won't drop trailing strokes.
        annotationSession?.dismiss()
        annotationSession = nil
        stopKeystrokeCapture()

        if let recorder = videoRecorder {
            videoRecorder = nil
            volumeObservers.removeAll()
            microphone?.stop()
            microphone = nil
            isExporting = true
            do {
                let url = try await recorder.finish()
                finishExport(url: url, isAnimated: true)
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
            return
        }

        frameProcessor?.stop()
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
                    self.finishExport(url: url, isAnimated: true)
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
