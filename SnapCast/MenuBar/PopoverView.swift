import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var settings: CaptureSettings
    @ObservedObject var captureManager: CaptureSessionManager
    @ObservedObject private var screenPermissions = ScreenPermissions.shared
    @ObservedObject private var accessibilityPermissions = AccessibilityPermissions.shared
    @State private var showingSettings = false
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
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
                    annotateChip
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if !showingSettings {
                Picker("", selection: $settings.captureType) {
                    ForEach(CaptureType.allCases, id: \.self) { type in
                        Label(type.rawValue, systemImage: type.systemImage).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            Divider()

            if showingSettings {
                settingsPage
            } else if settings.captureType == .merger {
                mergerPage
            } else if settings.captureType == .screenshot {
                screenshotPage
            } else {
                mainPage
            }
        }
        .frame(width: 320)
        .onAppear {
            // Re-read permission state every time the popover opens so the UI
            // reflects grants the user made in System Settings while away.
            screenPermissions.checkPermission()
            accessibilityPermissions.refresh()
        }
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

    // MARK: - Merger Page

    private var mergerPage: some View {
        VStack(spacing: 0) {
            if !ScreenPermissions.shared.isAuthorized {
                permissionWarning.padding()
            } else if captureManager.isExporting {
                exportingMergerView.padding()
            } else if captureManager.isMergerActive {
                mergerActiveView
            } else {
                mergerIdleView.padding()
            }

            if let error = captureManager.exportError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if let url = captureManager.lastExportedURL, !captureManager.isMergerActive {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Merged & Saved!")
                        .font(.caption)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private var mergerIdleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.title)
                .foregroundColor(.secondary)
            Text("Capture multiple regions and merge them into one image")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { captureManager.startMerger() }) {
                HStack {
                    Image(systemName: "plus.rectangle.on.rectangle")
                    Text("Start Merger Session")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
        }
    }

    private var mergerActiveView: some View {
        VStack(spacing: 0) {
            // Thumbnail list with reorder
            if captureManager.mergerCaptures.isEmpty {
                VStack(spacing: 8) {
                    Text("No captures yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Click below to capture your first region")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(height: 80)
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(captureManager.mergerCaptures.enumerated()), id: \.element.id) { index, capture in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 16)

                            Image(nsImage: capture.thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 40)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )

                            VStack(alignment: .leading) {
                                Text("\(capture.image.width)×\(capture.image.height)")
                                    .font(.caption2)
                                    .monospacedDigit()
                            }

                            Spacer()

                            Button(action: { captureManager.removeMergerCapture(at: index) }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { source, dest in
                        captureManager.moveMergerCapture(from: source, to: dest)
                    }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(captureManager.mergerCaptures.count) * 52, 200))
            }

            Divider()

            // Controls
            VStack(spacing: 8) {
                // Direction toggle
                HStack {
                    Text("Direction")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $captureManager.mergeDirection) {
                        ForEach(MergeDirection.allCases, id: \.self) { dir in
                            Label(dir.rawValue, systemImage: dir.systemImage).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                // Format
                HStack {
                    Text("Format")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $settings.screenshotFormat) {
                        ForEach(ScreenshotFormat.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }

                // Capture next button
                Button(action: { captureManager.captureNextMergerFrame() }) {
                    HStack {
                        Image(systemName: "plus.viewfinder")
                        Text("Capture Region (\(captureManager.mergerCaptures.count))")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)

                // Merge & Save button
                HStack(spacing: 8) {
                    Button(action: { captureManager.cancelMerger() }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(action: { captureManager.mergeAndSave() }) {
                        HStack {
                            Image(systemName: "rectangle.compress.vertical")
                            Text("Merge & Save")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.large)
                    .disabled(captureManager.mergerCaptures.count < 2)
                }
            }
            .padding()
        }
    }

    private var exportingMergerView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Merging \(captureManager.mergerCaptures.count) captures...")
                .font(.headline)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Screenshot Page

    private var screenshotPage: some View {
        VStack(spacing: 12) {
            if !ScreenPermissions.shared.isAuthorized {
                permissionWarning
            } else if captureManager.isTakingScreenshot {
                screenshotProgressView
            } else {
                screenshotControlsView
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

    private var screenshotControlsView: some View {
        VStack(spacing: 12) {
            // Mode grid
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    screenshotModeButton(.region)
                    screenshotModeButton(.window)
                }
                HStack(spacing: 6) {
                    screenshotModeButton(.fullScreen)
                    screenshotModeButton(.fullPage)
                }
            }

            if settings.screenshotMode == .fullPage {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .foregroundColor(.blue)
                            .font(.caption)
                        TextField("https://example.com", text: $settings.fullPageURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }

                    HStack {
                        Text("Width: \(settings.fullPageWidth)px")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("Wait: \(String(format: "%.0fs", settings.fullPageWaitTime))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Text("Format")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $settings.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            Button(action: { captureManager.takeScreenshot() }) {
                HStack {
                    Image(systemName: screenshotButtonIcon)
                    Text(screenshotButtonLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
            .disabled(settings.screenshotMode == .fullPage && settings.fullPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var screenshotButtonIcon: String {
        settings.screenshotMode == .fullPage ? "scroll" : "camera"
    }

    private var screenshotButtonLabel: String {
        settings.screenshotMode == .fullPage ? "Capture Full Page" : "Take Screenshot"
    }

    private func screenshotModeButton(_ mode: ScreenshotMode) -> some View {
        Button(action: { settings.screenshotMode = mode }) {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                    .font(.caption)
                Text(mode.rawValue)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(settings.screenshotMode == mode ? .blue : .secondary)
    }

    private var screenshotProgressView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text(captureManager.scrollProgress ?? "Capturing...")
                .font(.headline)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Controls (idle)

    private var controlsView: some View {
        VStack(spacing: 12) {
            Picker("", selection: $settings.captureMode) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
            Text("Encoding GIF...")
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
                // Permissions
                settingsSection("Permissions") {
                    permissionRow(
                        icon: "rectangle.dashed.badge.record",
                        title: "Screen Recording",
                        subtitle: "Required to capture screen content",
                        isGranted: screenPermissions.isAuthorized,
                        needsRelaunch: false,
                        grantAction: { screenPermissions.checkPermission() },
                        openAction: { screenPermissions.openSettings() },
                        relaunchAction: nil
                    )
                    permissionRow(
                        icon: "keyboard",
                        title: "Accessibility",
                        subtitle: accessibilityPermissions.needsRelaunch
                            ? "Granted — relaunch to apply"
                            : "Required for global keyboard shortcuts",
                        isGranted: accessibilityPermissions.isAuthorized,
                        needsRelaunch: accessibilityPermissions.needsRelaunch,
                        grantAction: { accessibilityPermissions.requestAccess() },
                        openAction: { accessibilityPermissions.openSettings() },
                        relaunchAction: { accessibilityPermissions.relaunch() }
                    )
                }

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

                // Full Page
                settingsSection("Full Page Capture") {
                    settingsRow("Viewport") {
                        Slider(value: fullPageWidthBinding, in: 800...2560, step: 10)
                        Text("\(settings.fullPageWidth)").frame(width: 40, alignment: .trailing).monospacedDigit()
                    }
                    settingsRow("Wait Time") {
                        Slider(value: $settings.fullPageWaitTime, in: 1...10, step: 0.5)
                        Text(String(format: "%.0fs", settings.fullPageWaitTime)).frame(width: 28, alignment: .trailing).monospacedDigit()
                    }
                    Text("Viewport width for rendering. Wait time for JS/images to load after page is ready.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Output
                settingsSection("Output") {
                    Toggle("Copy to Clipboard", isOn: $settings.copyToClipboard)
                        .font(.caption)
                    Toggle("Show Preview Toast", isOn: $settings.showCaptureToast)
                        .font(.caption)
                    Toggle("Open Editor After Capture", isOn: $settings.openEditorAfterCapture)
                        .font(.caption)
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

                // Shortcuts
                settingsSection("Shortcuts") {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        HStack {
                            Text(action.displayName)
                                .font(.caption)
                            Spacer()
                            ShortcutRecorderField(binding: settings.binding(for: action))
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") { settings.resetShortcuts() }
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

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        isGranted: Bool,
        needsRelaunch: Bool,
        grantAction: @escaping () -> Void,
        openAction: @escaping () -> Void,
        relaunchAction: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isGranted ? .green : (needsRelaunch ? .orange : .secondary))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                    Image(systemName: statusIcon(isGranted: isGranted, needsRelaunch: needsRelaunch))
                        .font(.caption2)
                        .foregroundColor(statusColor(isGranted: isGranted, needsRelaunch: needsRelaunch))
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Button("Settings", action: openAction)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
            } else if needsRelaunch, let relaunch = relaunchAction {
                Button(action: relaunch) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text("Relaunch")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            } else {
                Button("Grant", action: grantAction)
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// Compact toggle chip in the popover header. Tapping flips
    /// `annotateBeforeCapture` so the very next screenshot opens the
    /// annotation canvas after region/full-screen selection.
    private var annotateChip: some View {
        Button(action: { settings.annotateBeforeCapture.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 11, weight: .semibold))
                Text("Annotate")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    settings.annotateBeforeCapture
                        ? Color.accentColor.opacity(0.85)
                        : Color.primary.opacity(0.08)
                )
            )
            .foregroundColor(settings.annotateBeforeCapture ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(settings.annotateBeforeCapture
              ? "Annotation canvas will appear before capture"
              : "Enable to draw on the screen before capture")
    }

    private func statusIcon(isGranted: Bool, needsRelaunch: Bool) -> String {
        if isGranted { return "checkmark.circle.fill" }
        if needsRelaunch { return "arrow.clockwise.circle.fill" }
        return "exclamationmark.circle.fill"
    }

    private func statusColor(isGranted: Bool, needsRelaunch: Bool) -> Color {
        if isGranted { return .green }
        return .orange
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
    private var fullPageWidthBinding: Binding<Double> {
        Binding(get: { Double(settings.fullPageWidth) }, set: { settings.fullPageWidth = Int($0) })
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

// MARK: - Shortcut Recorder

/// Click to start recording a key chord; press a chord to capture it; Esc to
/// cancel. The × button clears the binding entirely. While any field is in
/// recording mode the global dispatcher is paused (see ShortcutRecording).
struct ShortcutRecorderField: View {
    @Binding var binding: ShortcutBinding?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: isRecording ? 1.5 : 1)
                    )
                Text(displayText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .padding(.horizontal, 8)
            }
            .frame(width: 100, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { toggleRecording() }

            Button(action: { binding = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .opacity(binding != nil ? 1 : 0.3)
            .disabled(binding == nil)
        }
        .onDisappear { stopRecording() }
    }

    private var displayText: String {
        if isRecording { return "Press keys…" }
        return binding?.displayString ?? "—"
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        ShortcutRecording.isActive = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc with no modifiers cancels the recording itself.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && mods.isEmpty {
                stopRecording()
                return nil
            }
            if let captured = ShortcutBinding(event: event) {
                binding = captured
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        ShortcutRecording.isActive = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
