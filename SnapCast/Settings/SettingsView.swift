import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: CaptureSettings

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            recordingTab
                .tabItem { Label("Recording", systemImage: "record.circle") }
            gifTab
                .tabItem { Label("GIF", systemImage: "photo.stack") }
            avifTab
                .tabItem { Label("AVIF", systemImage: "photo") }
            outputTab
                .tabItem { Label("Output", systemImage: "square.resize") }
        }
        .frame(width: 450, height: 300)
        .padding()
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker("Default Mode", selection: $settings.captureMode) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Picker("Default Format", selection: $settings.outputFormat) {
                ForEach(OutputFormat.allCases, id: \.self) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }

            HStack {
                Text("Output Folder")
                Spacer()
                Text(settings.outputFolderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 200)
                Button("Choose...") {
                    chooseOutputFolder()
                }
            }
        }
        .padding()
    }

    // MARK: - Recording

    private var recordingTab: some View {
        Form {
            HStack {
                Text("FPS")
                Slider(value: Binding(
                    get: { Double(settings.fps) },
                    set: { settings.fps = Int($0) }
                ), in: 1...60, step: 1)
                Text("\(settings.fps)")
                    .frame(width: 30, alignment: .trailing)
                    .monospacedDigit()
            }

            HStack {
                Text("Max Duration (sec)")
                Slider(value: Binding(
                    get: { Double(settings.maxDuration) },
                    set: { settings.maxDuration = Int($0) }
                ), in: 1...120, step: 1)
                Text("\(settings.maxDuration)")
                    .frame(width: 30, alignment: .trailing)
                    .monospacedDigit()
            }

            HStack {
                Text("Delay (sec)")
                Slider(value: Binding(
                    get: { Double(settings.captureDelay) },
                    set: { settings.captureDelay = Int($0) }
                ), in: 0...10, step: 1)
                Text("\(settings.captureDelay)")
                    .frame(width: 30, alignment: .trailing)
                    .monospacedDigit()
            }

            Toggle("Capture Cursor", isOn: $settings.captureCursor)
        }
        .padding()
    }

    // MARK: - GIF

    private var gifTab: some View {
        Form {
            HStack {
                Text("Colors")
                Slider(value: Binding(
                    get: { Double(settings.colorCount) },
                    set: { settings.colorCount = Int($0) }
                ), in: 8...256, step: 8)
                Text("\(settings.colorCount)")
                    .frame(width: 35, alignment: .trailing)
                    .monospacedDigit()
            }

            Toggle("Dithering", isOn: $settings.ditheringEnabled)

            HStack {
                Text("Loop Count")
                Stepper(value: $settings.loopCount, in: 0...100) {
                    Text(settings.loopCount == 0 ? "∞" : "\(settings.loopCount)")
                        .monospacedDigit()
                }
            }
        }
        .padding()
    }

    // MARK: - AVIF

    private var avifTab: some View {
        Form {
            HStack {
                Text("Quality")
                Slider(value: $settings.quality, in: 0...1, step: 0.05)
                Text(String(format: "%.0f%%", settings.quality * 100))
                    .frame(width: 40, alignment: .trailing)
                    .monospacedDigit()
            }

            Text("AVIF requires macOS 13+. Falls back to animated HEIC if not available.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Output

    private var outputTab: some View {
        Form {
            Toggle("Resize Output", isOn: $settings.resizeEnabled)

            if settings.resizeEnabled {
                HStack {
                    Text("Width")
                    TextField("Width", value: $settings.resizeWidth, format: .number)
                        .frame(width: 80)

                    Text("×")

                    Text("Height")
                    TextField("Height", value: $settings.resizeHeight, format: .number)
                        .frame(width: 80)
                }

                Toggle("Maintain Aspect Ratio", isOn: $settings.maintainAspectRatio)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolderPath = url.path
        }
    }
}
