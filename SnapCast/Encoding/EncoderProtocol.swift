import CoreGraphics
import Foundation

protocol FrameEncoder {
    func encode(frames: [(CGImage, TimeInterval)], fps: Int, settings: CaptureSettings) async throws -> URL
}

enum EncoderError: LocalizedError {
    case cannotCreateDestination
    case encodingFailed
    case noFrames
    case formatNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateDestination: return "Cannot create image destination"
        case .encodingFailed: return "Encoding failed"
        case .noFrames: return "No frames to encode"
        case .formatNotSupported(let fmt): return "\(fmt) is not supported on this system"
        }
    }
}
