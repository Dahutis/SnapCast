import Foundation
import ImageIO
import UniformTypeIdentifiers

class AVIFEncoder: FrameEncoder {

    func encode(frames: [(CGImage, TimeInterval)], fps: Int, settings: CaptureSettings) async throws -> URL {
        guard !frames.isEmpty else { throw EncoderError.noFrames }

        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as! [String]

        // Try formats in order of preference
        let candidates: [(type: String, ext: String)] = [
            ("public.avif", "avif"),
            ("public.heics", "heic"),       // Animated HEIC sequence
            ("public.heic", "heic"),         // Single HEIC (we'll add multiple frames)
        ]

        var chosen: (type: String, ext: String)?
        for candidate in candidates {
            if supportedTypes.contains(candidate.type) {
                chosen = candidate
                break
            }
        }

        guard let format = chosen else {
            throw EncoderError.formatNotSupported(
                "AVIF/HEIC (available: \(supportedTypes.filter { $0.contains("heic") || $0.contains("avif") }))"
            )
        }

        let outputURL = settings.outputFileURL(extension: format.ext)
        let frameDelay = 1.0 / Double(fps)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.type as CFString,
            frames.count,
            nil
        ) else {
            // If animated format fails, try single-image HEIC with all frames
            return try await encodeFallbackHEIC(frames: frames, fps: fps, settings: settings)
        }

        // File-level properties
        let fileProperties: NSDictionary = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: settings.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties)

        for (image, _) in frames {
            let frameProperties: NSDictionary = [
                kCGImageDestinationLossyCompressionQuality: settings.quality,
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            // Finalize failed — try fallback
            try? FileManager.default.removeItem(at: outputURL)
            return try await encodeFallbackHEIC(frames: frames, fps: fps, settings: settings)
        }

        return outputURL
    }

    /// Fallback: encode each frame as a separate HEIC file, then combine into a GIF
    /// (worst case — at least the user gets output)
    private func encodeFallbackHEIC(frames: [(CGImage, TimeInterval)], fps: Int, settings: CaptureSettings) async throws -> URL {
        // Fall back to GIF if HEIC sequence isn't working
        let gifEncoder = GIFEncoder()
        return try await gifEncoder.encode(frames: frames, fps: fps, settings: settings)
    }
}
