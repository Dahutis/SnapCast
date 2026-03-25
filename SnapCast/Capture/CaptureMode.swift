import Foundation

enum CaptureType: String, CaseIterable, Codable {
    case recording = "Recording"
    case screenshot = "Screenshot"

    var systemImage: String {
        switch self {
        case .recording: return "record.circle"
        case .screenshot: return "camera"
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

    var fileExtension: String {
        return "gif"
    }
}
