import SwiftUI
import AppKit

/// Floating palette presented alongside the canvas. Reads/writes the shared
/// `AnnotationState`. Done/Cancel/Undo/Clear actions are passed in as closures
/// so the host (AnnotationSession) controls the canvas lifecycle.
struct AnnotationToolPaletteView: View {
    @ObservedObject var state: AnnotationState
    let isRecordingMode: Bool
    let onDone: () -> Void
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            toolGroup
            verticalDivider
            colorGroup
            verticalDivider
            thicknessGroup
            verticalDivider
            historyGroup
            verticalDivider
            paintModeToggle
            Spacer(minLength: 6)
            if state.isRecording {
                recordingActionGroup
            } else {
                actionGroup
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(
            ZStack {
                VisualEffectPanelBackground(material: .menu, blending: .behindWindow)
                Color.black.opacity(0.18)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    state.isRecording
                        ? Color.red.opacity(0.55)
                        : Color.white.opacity(0.08),
                    lineWidth: state.isRecording ? 1.0 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 4)
        .animation(.easeOut(duration: 0.18), value: state.isRecording)
    }

    private static let brushTools: [AnnotationTool] = [.pen, .highlighter, .marker]
    private static let shapeTools: [AnnotationTool] = [.line, .arrow, .rectangle, .ellipse]

    private var toolGroup: some View {
        HStack(spacing: 4) {
            ForEach(Self.brushTools) { toolButton($0) }
            verticalDivider
            ForEach(Self.shapeTools) { toolButton($0) }
            verticalDivider
            toolButton(.eraser)
        }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button(action: { state.tool = tool }) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(state.tool == tool ? .white : .primary.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(state.tool == tool ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tool.displayName)
    }

    private var colorGroup: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationColor.allCases) { color in
                colorSwatch(color)
            }
        }
    }

    private func colorSwatch(_ color: AnnotationColor) -> some View {
        let isSelected = state.color == color
        return Button(action: { state.color = color }) {
            ZStack {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                    )
                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(color.rawValue.capitalized)
    }

    private var thicknessGroup: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationThickness.allCases) { thickness in
                thicknessDot(thickness)
            }
        }
    }

    private func thicknessDot(_ thickness: AnnotationThickness) -> some View {
        let isSelected = state.thickness == thickness
        return Button(action: { state.thickness = thickness }) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.7))
                    .frame(width: thickness.swatchRadius * 2, height: thickness.swatchRadius * 2)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help("\(Int(thickness.width)) pt")
    }

    /// Toggle that flips the canvas between paint mode and click-through.
    /// In click-through mode the canvas window's `ignoresMouseEvents` is true
    /// so the underlying app (Terminal, browser, etc.) gets the clicks — the
    /// palette itself stays interactive so the user can flip back.
    private var paintModeToggle: some View {
        Button(action: { state.isCanvasActive.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: state.isCanvasActive ? "pencil.tip" : "hand.point.up.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(state.isCanvasActive ? "Paint" : "Click")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundColor(state.isCanvasActive ? .white : .primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        state.isCanvasActive
                            ? Color.accentColor.opacity(0.85)
                            : Color.primary.opacity(0.10)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(state.isCanvasActive
              ? "Paint mode — click to switch to passthrough (⌘⇧P)"
              : "Passthrough — clicks reach the app below (⌘⇧P to paint)")
    }

    private var historyGroup: some View {
        HStack(spacing: 4) {
            iconButton(systemName: "arrow.uturn.backward", help: "Undo (⌘Z)") {
                state.undo()
                NotificationCenter.default.post(name: AnnotationCanvasView.redrawNotification, object: nil)
            }
            .disabled(state.elements.isEmpty)

            iconButton(systemName: "trash", help: "Clear all") {
                state.clear()
                NotificationCenter.default.post(name: AnnotationCanvasView.redrawNotification, object: nil)
            }
            .disabled(state.elements.isEmpty)
        }
    }

    private var actionGroup: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")

            Button(action: onDone) {
                HStack(spacing: 5) {
                    Image(systemName: isRecordingMode ? "record.circle.fill" : "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text(isRecordingMode ? "Record" : "Capture")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecordingMode ? Color.red : Color.accentColor)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(isRecordingMode ? "Start recording" : "Capture screenshot")
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    /// Replaces `actionGroup` once the host calls `enterRecordingMode()`.
    /// Shows a live pulsing red dot, MM:SS.t elapsed timer, and a single
    /// prominent Stop button that hands control back to the recording host.
    private var recordingActionGroup: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                RecordingDot()
                Text(formatElapsed(state.elapsedTime))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.red.opacity(0.5), lineWidth: 0.5)
            )

            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.red)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        let tenths = Int((interval - floor(interval)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 24)
    }
}

/// Pulsing red dot used in the recording-state palette header. Re-implemented
/// as a small view (rather than just an Image with .opacity animation) so the
/// pulse keeps running while the palette is hosted in an NSPanel that doesn't
/// participate in the usual SwiftUI animation timing.
private struct RecordingDot: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.45 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse.toggle()
                }
            }
    }
}

private struct VisualEffectPanelBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
