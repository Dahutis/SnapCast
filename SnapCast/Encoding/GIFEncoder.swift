import AppKit
import ImageIO
import UniformTypeIdentifiers

class GIFEncoder: FrameEncoder {

    func encode(frames: [(CGImage, TimeInterval)], fps: Int, settings: CaptureSettings) async throws -> URL {
        guard !frames.isEmpty else { throw EncoderError.noFrames }

        let outputURL = settings.outputFileURL(extension: "gif")
        let frameDelay = 1.0 / Double(fps)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw EncoderError.cannotCreateDestination
        }

        // GIF file-level properties
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: settings.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let colorCount = settings.colorCount

        for (image, _) in frames {
            let processedImage: CGImage
            if settings.ditheringEnabled || colorCount < 256 {
                processedImage = quantizeImage(image, colorCount: colorCount, dithering: settings.ditheringEnabled)
            } else {
                processedImage = image
            }

            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay
                ]
            ]
            CGImageDestinationAddImage(destination, processedImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw EncoderError.encodingFailed
        }

        return outputURL
    }

    private func quantizeImage(_ image: CGImage, colorCount: Int, dithering: Bool) -> CGImage {
        let rep = NSBitmapImageRep(cgImage: image)
        let nsImage = NSImage(size: NSSize(width: image.width, height: image.height))
        nsImage.addRepresentation(rep)

        // Use NSBitmapImageRep's GIF representation which handles quantization
        let properties: [NSBitmapImageRep.PropertyKey: Any] = [
            .ditherTransparency: dithering
        ]

        if let gifData = rep.representation(using: .gif, properties: properties),
           let gifSource = CGImageSourceCreateWithData(gifData as CFData, nil),
           CGImageSourceGetCount(gifSource) > 0,
           let quantizedImage = CGImageSourceCreateImageAtIndex(gifSource, 0, nil) {
            return quantizedImage
        }

        return image
    }
}
