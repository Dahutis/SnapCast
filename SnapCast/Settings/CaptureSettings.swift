import Foundation
import Combine

class CaptureSettings: ObservableObject {
    @Published var captureMode: CaptureMode {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    @Published var outputFormat: OutputFormat {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: "outputFormat") }
    }
    @Published var fps: Int {
        didSet { UserDefaults.standard.set(fps, forKey: "fps") }
    }
    @Published var quality: Double {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }
    @Published var resizeEnabled: Bool {
        didSet { UserDefaults.standard.set(resizeEnabled, forKey: "resizeEnabled") }
    }
    @Published var resizeWidth: Int {
        didSet { UserDefaults.standard.set(resizeWidth, forKey: "resizeWidth") }
    }
    @Published var resizeHeight: Int {
        didSet { UserDefaults.standard.set(resizeHeight, forKey: "resizeHeight") }
    }
    @Published var maintainAspectRatio: Bool {
        didSet { UserDefaults.standard.set(maintainAspectRatio, forKey: "maintainAspectRatio") }
    }
    @Published var captureDelay: Int {
        didSet { UserDefaults.standard.set(captureDelay, forKey: "captureDelay") }
    }
    @Published var maxDuration: Int {
        didSet { UserDefaults.standard.set(maxDuration, forKey: "maxDuration") }
    }
    @Published var captureCursor: Bool {
        didSet { UserDefaults.standard.set(captureCursor, forKey: "captureCursor") }
    }
    @Published var colorCount: Int {
        didSet { UserDefaults.standard.set(colorCount, forKey: "colorCount") }
    }
    @Published var ditheringEnabled: Bool {
        didSet { UserDefaults.standard.set(ditheringEnabled, forKey: "ditheringEnabled") }
    }
    @Published var loopCount: Int {
        didSet { UserDefaults.standard.set(loopCount, forKey: "loopCount") }
    }
    @Published var outputFolderPath: String {
        didSet { UserDefaults.standard.set(outputFolderPath, forKey: "outputFolderPath") }
    }

    var outputFolder: URL {
        URL(fileURLWithPath: outputFolderPath)
    }

    init() {
        let defaults = UserDefaults.standard
        self.captureMode = CaptureMode(rawValue: defaults.string(forKey: "captureMode") ?? "") ?? .region
        self.outputFormat = OutputFormat(rawValue: defaults.string(forKey: "outputFormat") ?? "") ?? .gif
        self.fps = defaults.object(forKey: "fps") as? Int ?? 15
        self.quality = defaults.object(forKey: "quality") as? Double ?? 0.8
        self.resizeEnabled = defaults.bool(forKey: "resizeEnabled")
        self.resizeWidth = defaults.object(forKey: "resizeWidth") as? Int ?? 640
        self.resizeHeight = defaults.object(forKey: "resizeHeight") as? Int ?? 480
        self.maintainAspectRatio = defaults.object(forKey: "maintainAspectRatio") as? Bool ?? true
        self.captureDelay = defaults.object(forKey: "captureDelay") as? Int ?? 0
        self.maxDuration = defaults.object(forKey: "maxDuration") as? Int ?? 30
        self.captureCursor = defaults.object(forKey: "captureCursor") as? Bool ?? true
        self.colorCount = defaults.object(forKey: "colorCount") as? Int ?? 256
        self.ditheringEnabled = defaults.object(forKey: "ditheringEnabled") as? Bool ?? true
        self.loopCount = defaults.object(forKey: "loopCount") as? Int ?? 0
        self.outputFolderPath = defaults.string(forKey: "outputFolderPath")
            ?? NSHomeDirectory() + "/Desktop"
    }

    func outputFileURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "SnapCast_\(timestamp).\(ext)"

        let folder = outputFolder
        // Ensure folder exists
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder.appendingPathComponent(filename)
    }
}
