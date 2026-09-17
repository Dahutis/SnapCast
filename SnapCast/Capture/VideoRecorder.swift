import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

enum VideoRecorderError: LocalizedError {
    case noFrames
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames captured"
        case .writerFailed(let error): return "Video writer failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

/// SCStreamOutput that streams frames (plus optional system audio and
/// microphone) straight into an MP4 via AVAssetWriter.
/// Unlike FrameProcessor nothing is buffered in memory, so recordings can run
/// for minutes at full Retina resolution. Cropping and scaling are done by
/// ScreenCaptureKit itself (`sourceRect` / `width` / `height`), so buffers are
/// appended as-is and encoded in hardware.
///
/// All writer access happens on `queue` — pass it as the stream's
/// sampleHandlerQueue so callbacks and `finish()` never race.
///
/// With both audio sources on, they are recorded as two tracks into a
/// temporary file and mixed down to a single track in `finish()` — most
/// players, browsers and chat apps only play the first audio track.
final class VideoRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let outputURL: URL
    let queue = DispatchQueue(label: "com.nxcapture.snapcast.video-recorder")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    /// Where the writer records; differs from `outputURL` when a mixdown is needed.
    private let recordingURL: URL

    private let keystrokes: KeystrokeOverlay?
    private let frameInterval: Double
    /// Re-emits the last frame while key captions are animating over a
    /// static screen (SCKit sends no frames when nothing changes).
    private var keystrokeTicker: DispatchSourceTimer?

    // Touched only on `queue`.
    private var sessionStarted = false
    private var sessionStart: CMTime = .invalid
    private var isClosed = false
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS: CMTime = .invalid

    private let countLock = NSLock()
    private var _frameCount = 0

    var frameCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return _frameCount
    }

    // Gains can change mid-recording from the UI, hence the lock.
    private let gainLock = NSLock()
    private var _systemAudioGain: Float = 1
    private var _microphoneGain: Float = 1

    /// Linear gain for system audio (1 = unchanged, up to 3 = +9.5 dB).
    var systemAudioGain: Float {
        get { gainLock.lock(); defer { gainLock.unlock() }; return _systemAudioGain }
        set { gainLock.lock(); _systemAudioGain = newValue; gainLock.unlock() }
    }

    /// Linear gain for the microphone (1 = unchanged, up to 3 = +9.5 dB).
    var microphoneGain: Float {
        get { gainLock.lock(); defer { gainLock.unlock() }; return _microphoneGain }
        set { gainLock.lock(); _microphoneGain = newValue; gainLock.unlock() }
    }

    static let audioSampleRate = 48_000
    static let audioChannelCount = 2

    static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannelCount,
            AVEncoderBitRateKey: 160_000,
        ]
    }

    init(
        outputURL: URL, width: Int, height: Int, fps: Int,
        codec: VideoCodec, quality: VideoQuality,
        recordSystemAudio: Bool, recordMicrophone: Bool,
        keystrokes: KeystrokeOverlay? = nil
    ) throws {
        self.outputURL = outputURL
        self.keystrokes = keystrokes
        frameInterval = 1 / Double(fps)
        recordingURL = (recordSystemAudio && recordMicrophone)
            ? outputURL.deletingLastPathComponent()
                .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).tracks.mp4")
            : outputURL
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: recordingURL)

        writer = try AVAssetWriter(outputURL: recordingURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let bitrate = max(1_000_000, Int(Double(width * height * fps) * quality.bitsPerPixel))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(videoInput) else { throw VideoRecorderError.writerFailed(writer.error) }
        writer.add(videoInput)

        // Both sources deliver float PCM; the writer transcodes to AAC.
        func makeAudioInput(_ enabled: Bool, writer: AVAssetWriter) throws -> AVAssetWriterInput? {
            guard enabled else { return nil }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw VideoRecorderError.writerFailed(writer.error) }
            writer.add(input)
            return input
        }
        systemAudioInput = try makeAudioInput(recordSystemAudio, writer: writer)
        microphoneInput = try makeAudioInput(recordMicrophone, writer: writer)
        guard writer.startWriting() else { throw VideoRecorderError.writerFailed(writer.error) }

        super.init()

        if keystrokes != nil {
            let ticker = DispatchSource.makeTimerSource(queue: queue)
            ticker.schedule(deadline: .now(), repeating: frameInterval)
            ticker.setEventHandler { [weak self] in self?.tickKeystrokes() }
            ticker.resume()
            keystrokeTicker = ticker
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !isClosed else { return }

        if type == .audio {
            appendAudio(sampleBuffer, to: systemAudioInput, gain: systemAudioGain)
            return
        }
        guard type == .screen else { return }

        // SCKit emits idle/blank status frames without an image when nothing
        // on screen changed — only complete frames carry pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        append(pixelBuffer, at: sampleBuffer.presentationTimeStamp)
    }

    private func append(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        guard writer.status == .writing else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            sessionStart = pts
        }

        // Real-time input: if the encoder is behind, drop the frame rather
        // than block SCKit's delivery queue.
        guard videoInput.isReadyForMoreMediaData,
              !lastPTS.isValid || CMTimeCompare(pts, lastPTS) > 0 else { return }

        if write(pixelBuffer, at: pts) {
            lastPixelBuffer = pixelBuffer
            lastPTS = pts
            countLock.lock()
            _frameCount += 1
            countLock.unlock()
        }
    }

    /// Appends a frame, burning in key captions when any are visible at `pts`.
    /// `lastPixelBuffer` always keeps the clean frame so re-emitted frames
    /// don't stack captions.
    private func write(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) -> Bool {
        var frame = pixelBuffer
        if let keystrokes, let pool = adaptor.pixelBufferPool {
            let captions = keystrokes.timeline.visibleCaptions(at: pts.seconds)
            var composited: CVPixelBuffer?
            if !captions.isEmpty,
               CVPixelBufferPoolCreatePixelBuffer(nil, pool, &composited) == kCVReturnSuccess,
               let composited,
               keystrokes.renderer.composite(captions, source: pixelBuffer, destination: composited) {
                frame = composited
            }
        }
        return adaptor.append(frame, withPresentationTime: pts)
    }

    private func tickKeystrokes() {
        guard !isClosed, sessionStarted, let last = lastPixelBuffer, let keystrokes else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // 1.5× the interval so real SCKit frames (stamped slightly before
        // delivery) aren't pre-empted by a duplicate.
        guard now.seconds - lastPTS.seconds >= frameInterval * 1.5,
              keystrokes.timeline.needsFrame(at: now.seconds) else { return }
        append(last, at: now)
    }

    /// Microphone samples from MicrophoneCapture. Must be called on `queue`.
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard !isClosed else { return }
        appendAudio(sampleBuffer, to: microphoneInput, gain: microphoneGain)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to audioInput: AVAssetWriterInput?, gain: Float) {
        // The session starts on the first video frame; audio that arrives
        // earlier would land before the timeline origin, so drop it.
        guard let audioInput, writer.status == .writing, sessionStarted,
              CMTimeCompare(sampleBuffer.presentationTimeStamp, sessionStart) >= 0,
              audioInput.isReadyForMoreMediaData else { return }
        if gain != 1 {
            Self.processSamples(sampleBuffer, gain: gain)
        }
        audioInput.append(sampleBuffer)
    }

    /// Applies `gain` to float32 PCM in place, then soft-limits so boosted
    /// or summed audio saturates smoothly instead of hard-clipping. Buffers
    /// in other formats are left untouched.
    private static func processSamples(_ sampleBuffer: CMSampleBuffer, gain: Float) {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return }

        // Ceiling sits below 0 dBFS because AAC encoding overshoots peaks
        // by up to ~10%.
        let ceiling: Float = 0.9
        let threshold: Float = 0.75
        let headroom = ceiling - threshold
        // Both SCKit and AVCaptureAudioDataOutput hand over contiguous block
        // buffers, so the list points at the sample buffer's own memory.
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                    let x = samples[i] * gain
                    let magnitude = abs(x)
                    samples[i] = magnitude <= threshold
                        ? x
                        : (threshold + headroom * tanh((magnitude - threshold) / headroom)) * (x < 0 ? -1 : 1)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Call after the SCStream has stopped. Holds the last frame until "now"
    /// (SCKit only sends frames when the screen changes, so a static ending
    /// would otherwise be cut off), then finalizes the file.
    func finish() async throws -> URL {
        let recordedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                guard !isClosed else {
                    continuation.resume(throwing: VideoRecorderError.noFrames)
                    return
                }

                keystrokeTicker?.cancel()
                keystrokeTicker = nil

                guard sessionStarted, lastPixelBuffer != nil else {
                    isClosed = true
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: recordingURL)
                    continuation.resume(throwing: VideoRecorderError.noFrames)
                    return
                }

                // SCKit timestamps are on the host clock.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if let last = lastPixelBuffer, CMTimeCompare(now, lastPTS) > 0 {
                    // Bypass the readiness check: this is the final sample and
                    // dropping it would shorten the video.
                    _ = write(last, at: now)
                }
                isClosed = true
                lastPixelBuffer = nil
                videoInput.markAsFinished()
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()

                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: recordingURL)
                    } else {
                        continuation.resume(throwing: VideoRecorderError.writerFailed(writer.error))
                    }
                }
            }
        }

        guard recordedURL != outputURL else { return outputURL }
        defer { try? FileManager.default.removeItem(at: recordedURL) }
        try await Self.mixDownAudio(from: recordedURL, to: outputURL)
        return outputURL
    }

    /// Rewrites `source` with its video track passed through untouched and all
    /// audio tracks mixed into one AAC track.
    private static func mixDownAudio(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoRecorderError.noFrames
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoFormat = try await videoTrack.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else {
            throw VideoRecorderError.writerFailed(reader.error)
        }
        reader.add(videoOutput)
        reader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw VideoRecorderError.writerFailed(writer.error)
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard reader.startReading(), writer.startWriting() else {
            throw VideoRecorderError.writerFailed(reader.error ?? writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let pumps = [(videoOutput as AVAssetReaderOutput, videoInput), (audioOutput, audioInput)]
        await withTaskGroup(of: Void.self) { group in
            for (index, (output, input)) in pumps.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "com.nxcapture.snapcast.mixdown.\(index)")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                guard let sample = output.copyNextSampleBuffer() else {
                                    input.markAsFinished()
                                    done.resume()
                                    return
                                }
                                if input.mediaType == .audio {
                                    // Two full-scale sources can sum past 0 dBFS.
                                    Self.processSamples(sample, gain: 1)
                                }
                                input.append(sample)
                            }
                        }
                    }
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoRecorderError.writerFailed(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoRecorderError.writerFailed(writer.error) }
    }

    /// Abort the recording and delete the partial file.
    func cancel() {
        queue.async { [self] in
            keystrokeTicker?.cancel()
            keystrokeTicker = nil
            guard !isClosed else { return }
            isClosed = true
            lastPixelBuffer = nil
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: recordingURL)
        }
    }
}
