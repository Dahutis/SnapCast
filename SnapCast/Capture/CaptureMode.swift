import Foundation
import CoreGraphics

enum CaptureType: String, CaseIterable, Codable {
    case recording = "Recording"
    case screenshot = "Screenshot"
    case merger = "Merger"

    var systemImage: String {
        switch self {
        case .recording: return "record.circle"
        case .screenshot: return "camera"
        case .merger: return "square.stack.3d.up"
        }
    }
}

enum MergeDirection: String, CaseIterable, Codable {
    case vertical = "Vertical"
    case horizontal = "Horizontal"

    var systemImage: String {
        switch self {
        case .vertical: return "arrow.up.and.down"
        case .horizontal: return "arrow.left.and.right"
        }
    }
}

enum CaptureMode: String, CaseIterable, Codable {
    case region = "Region"
    case window = "Window"
    case fullScreen = "Full Screen"

    var systemImage: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullScreen: return "rectangle.fill"
        }
    }
}

enum ScreenshotMode: String, CaseIterable, Codable {
    case region = "Region"
    case window = "Window"
    case fullScreen = "Full Screen"
    case fullPage = "Full Page"

    var systemImage: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullScreen: return "rectangle.fill"
        case .fullPage: return "scroll"
        }
    }
}

enum ScreenshotFormat: String, CaseIterable, Codable {
    case png = "PNG"
    case jpeg = "JPEG"

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

enum OutputFormat: String, CaseIterable, Codable {
    case gif = "GIF"
    case mp4 = "MP4"

    var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .mp4: return "mp4"
        }
    }

    var isVideo: Bool { self == .mp4 }
}

enum VideoCodec: String, CaseIterable, Codable {
    case h264 = "H.264"
    case hevc = "HEVC"

    /// Longest side the hardware encoder accepts. H.264 tops out at 4096 on
    /// Apple silicon/T2 encoders, so 5K/6K Retina captures get scaled down.
    var maxDimension: Int {
        switch self {
        case .h264: return 4096
        case .hevc: return 8192
        }
    }
}

enum VideoQuality: String, CaseIterable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    /// Bits per pixel per frame. Screen content (flat UI, text) compresses far
    /// better than camera footage, so these sit well below typical video rates.
    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.04
        case .medium: return 0.08
        case .high: return 0.16
        }
    }
}

enum KeystrokeMode: String, CaseIterable, Codable {
    /// Chords with ⌘ / ⌃ / ⌥ and function keys.
    case shortcuts = "Shortcuts"
    /// Also plain typing, Return/Tab/arrows and held modifiers.
    case allKeys = "All Keys"
}

enum KeystrokePosition: String, CaseIterable, Codable {
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"
    case topCenter = "Top Center"
}

enum KeystrokeSize: String, CaseIterable, Codable {
    case small = "S"
    case medium = "M"
    case large = "L"

    /// Font size as a fraction of the frame height.
    var heightFraction: CGFloat {
        switch self {
        case .small: return 0.028
        case .medium: return 0.04
        case .large: return 0.056
        }
    }
}
