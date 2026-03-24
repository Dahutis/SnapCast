import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var settings: CaptureSettings
    @ObservedObject var captureManager: CaptureSessionManager
    @State private var showingSettings = false
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if showingSettings {
                    Button(action: { showingSettings = false }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                }
                Text(showingSettings ? "Settings" : "SnapCast")
                    .font(.headline)
                Spacer()
                if !showingSettings {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if showingSettings {
                settingsPage
            } else {
                mainPage
            }
        }
        .frame(width: 320)
    }

    // MARK: - Main Page

    private var mainPage: some View {
        VStack(spacing: 12) {
            if !ScreenPermissions.shared.isAuthorized {
                permissionWarning
            } else if captureManager.isExporting {
                exportingView
            } else if captureManager.isRecording {
                recordingView
            } else {
                controlsView
            }

            if let error = captureManager.exportError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if let url = captureManager.lastExportedURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved!")
                        .font(.caption)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
    }

    // MARK: - Controls (idle)

    private var controlsView: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $settings.captureMode) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Format")
                Spacer()
                Picker("", selection: $settings.outputFormat) {
                    ForEach(OutputFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            HStack {
                Text("FPS: \(settings.fps)")
                    .font(.caption).monospacedDigit()
                Spacer()
                Text("Max: \(settings.maxDuration)s")
                    .font(.caption).monospacedDigit()
                Spacer()
                if settings.captureDelay > 0 {
                    Text("Delay: \(settings.captureDelay)s")
                        .font(.caption).monospacedDigit()
                }
            }
            .foregroundColor(.secondary)

            Button(action: { captureManager.startCapture() }) {
                HStack {
                    Image(systemName: "record.circle")
                    Text("Start Recording")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulseOpacity)
                Text("Recording")
                    .font(.headline)
                Spacer()
                Text(formatTime(captureManager.elapsedTime))
                    .font(.title2).monospacedDigit()
            }

            Text("\(captureManager.capturedFrameCount) frames captured")
                .font(.caption).foregroundColor(.secondary)

            Button(action: { captureManager.stopCapture() }) {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop Recording")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)

            Button("Cancel", action: { captureManager.cancelCapture() })
                .font(.caption)
        }
    }

    // MARK: - Exporting

    private var exportingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Encoding \(settings.outputFormat.rawValue)...")
                .font(.headline)
            Text("\(captureManager.capturedFrameCount) frames")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Permission Warning

    private var permissionWarning: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)
            Text("Screen Recording Permission Required")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("System Settings → Privacy & Security → Screen Recording")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Open System Settings") {
                ScreenPermissions.shared.openSettings()
            }
            Button("Check Again") {
                ScreenPermissions.shared.checkPermission()
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Settings Page

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Recording
                settingsSection("Recording") {
                    settingsRow("FPS") {
                        Slider(value: fpsBinding, in: 1...60, step: 1)
                        Text("\(settings.fps)").frame(width: 28, alignment: .trailing).monospacedDigit()
                    }
                    settingsRow("Max Duration") {
                        Slider(value: maxDurationBinding, in: 1...120, step: 1)
                        Text("\(settings.maxDuration)s").frame(width: 36, alignment: .trailing).monospacedDigit()
                    }
                    settingsRow("Delay") {
                        Slider(value: delayBinding, in: 0...10, step: 1)
                        Text("\(settings.captureDelay)s").frame(width: 28, alignment: .trailing).monospacedDigit()
                    }
                    Toggle("Show Cursor", isOn: $settings.captureCursor)
                        .font(.caption)
                }

                // GIF
                settingsSection("GIF") {
                    settingsRow("Colors") {
                        Slider(value: colorBinding, in: 8...256, step: 8)
                        Text("\(settings.colorCount)").frame(width: 32, alignment: .trailing).monospacedDigit()
                    }
                    Toggle("Dithering", isOn: $settings.ditheringEnabled)
                        .font(.caption)
                    settingsRow("Loop") {
                        Stepper(value: $settings.loopCount, in: 0...100) {
                            Text(settings.loopCount == 0 ? "Infinite" : "\(settings.loopCount)×")
                                .monospacedDigit()
                        }
                    }
                }

                // AVIF
                settingsSection("AVIF") {
                    settingsRow("Quality") {
                        Slider(value: $settings.quality, in: 0...1, step: 0.05)
                        Text("\(Int(settings.quality * 100))%").frame(width: 36, alignment: .trailing).monospacedDigit()
                    }
                }

                // Output
                settingsSection("Output") {
                    Toggle("Resize", isOn: $settings.resizeEnabled)
                        .font(.caption)
                    if settings.resizeEnabled {
                        HStack {
                            Text("W").font(.caption).foregroundColor(.secondary)
                            TextField("", value: $settings.resizeWidth, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                            Text("×").foregroundColor(.secondary)
                            Text("H").font(.caption).foregroundColor(.secondary)
                            TextField("", value: $settings.resizeHeight, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                        }
                        .font(.caption)
                        Toggle("Keep Aspect Ratio", isOn: $settings.maintainAspectRatio)
                            .font(.caption)
                    }

                    HStack {
                        Text("Folder")
                            .font(.caption)
                        Spacer()
                        Text(shortenedPath(settings.outputFolderPath))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("...") { chooseFolder() }
                            .font(.caption)
                    }
                }

                // Quit
                Divider()
                HStack {
                    Spacer()
                    Button("Quit SnapCast") {
                        NSApp.terminate(nil)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding()
        }
        .frame(height: 400)
    }

    // MARK: - Settings Helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    private var fpsBinding: Binding<Double> {
        Binding(get: { Double(settings.fps) }, set: { settings.fps = Int($0) })
    }
    private var maxDurationBinding: Binding<Double> {
        Binding(get: { Double(settings.maxDuration) }, set: { settings.maxDuration = Int($0) })
    }
    private var delayBinding: Binding<Double> {
        Binding(get: { Double(settings.captureDelay) }, set: { settings.captureDelay = Int($0) })
    }
    private var colorBinding: Binding<Double> {
        Binding(get: { Double(settings.colorCount) }, set: { settings.colorCount = Int($0) })
    }

    private func chooseFolder() {
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

    private func shortenedPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        let tenths = Int((interval - Double(Int(interval))) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
