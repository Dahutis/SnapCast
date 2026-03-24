import Foundation
import ImageIO
import UniformTypeIdentifiers

class AVIFEncoder: FrameEncoder {

    func encode(frames: [(CGImage, TimeInterval)], fps: Int, settings: CaptureSettings) async throws -> URL {
        guard !frames.isEmpty else { throw EncoderError.noFrames }

        // Check if AVIF is supported
        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let avifType = "public.avif"
        let heicType = "public.heics" // Animated HEIC sequence

        let useAVIF = supportedTypes.contains(avifType)
        let useHEIC = !useAVIF && supportedTypes.contains(heicType)

        let fileExtension: String
        let typeIdentifier: String

        if useAVIF {
            fileExtension = "avif"
            typeIdentifier = avifType
        } else if useHEIC {
            fileExtension = "heic"
            typeIdentifier = heicType
        } else {
            throw EncoderError.formatNotSupported("AVIF/HEIC")
        }

        let outputURL = settings.outputFileURL(extension: fileExtension)
        let frameDelay = 1.0 / Double(fps)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            typeIdentifier as CFString,
            frames.count,
            nil
        ) else {
            throw EncoderError.cannotCreateDestination
        }

        // File-level properties for animation
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: settings.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        for (image, _) in frames {
            let frameProperties: [String: Any] = [
                kCGImageDestinationLossyCompressionQuality as String: settings.quality,
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay
                ]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw EncoderError.encodingFailed
        }

        return outputURL
    }
}
