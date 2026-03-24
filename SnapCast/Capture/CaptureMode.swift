import Foundation

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

enum OutputFormat: String, CaseIterable, Codable {
    case gif = "GIF"
    case avif = "AVIF"

    var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .avif: return "avif"
        }
    }
}
