import AVFoundation
import CoreMedia

/// Captures a microphone via AVCaptureSession and hands float PCM sample
/// buffers, retimed onto the host clock (the clock ScreenCaptureKit stamps
/// its frames with), to `handler` on `queue`.
///
/// Works on macOS 13+. SCStream's own `captureMicrophone` is macOS 15-only.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private let session = AVCaptureSession()
    private let handler: (CMSampleBuffer) -> Void

    static var availableDevices: [Device] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Prompts for microphone access if it hasn't been decided yet.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// - Parameter deviceID: `AVCaptureDevice.uniqueID`, or empty for the
    ///   system default input.
    init(deviceID: String, queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) throws {
        self.handler = handler
        super.init()

        let device = (deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID))
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw MicrophoneCaptureError.noDevice }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Ask for the same layout the writer's audio input expects so a mono
        // USB mic doesn't end up in one ear.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: VideoRecorder.audioSampleRate,
            AVNumberOfChannelsKey: VideoRecorder.audioChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.noDevice
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let hostClock = CMClockGetHostTimeClock()
        guard let sessionClock = session.synchronizationClock, sessionClock != hostClock else {
            handler(sampleBuffer)
            return
        }

        let pts = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: sessionClock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        if let retimed { handler(retimed) }
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case noDevice

    var errorDescription: String? { "No microphone available" }
}
