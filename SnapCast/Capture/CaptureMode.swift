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

    var fileExtension: String {
        return "gif"
    }
}
