import SwiftUI
import AppKit

/// The post-process editor UI: a toolbar of annotation + transform tools, the
/// interactive canvas, an optional GIF timeline, and an export bar.
struct EditorView: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var annotation: AnnotationState
    let onClose: () -> Void

    @State private var resizeText: String = ""
    @State private var statusMessage: String?

    init(document: EditorDocument, onClose: @escaping () -> Void) {
        self.document = document
        self.annotation = document.annotation
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            EditorCanvasView(document: document)
                .frame(minWidth: 480, minHeight: 320)
                .layoutPriority(1)
            if document.isAnimated {
                Divider()
                timeline
            }
            Divider()
            exportBar
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear { resizeText = "\(Int(document.baseSize.width))" }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            brushGroup
            divider
            shapeGroup
            divider
            toolButton(.eraser)
            divider
            colorGroup
            divider
            thicknessGroup
            divider
            historyGroup
            divider
            transformGroup
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var brushGroup: some View {
        HStack(spacing: 4) {
            ForEach([AnnotationTool.pen, .highlighter, .marker]) { toolButton($0) }
        }
    }

    private var shapeGroup: some View {
        HStack(spacing: 4) {
            ForEach([AnnotationTool.line, .arrow, .rectangle, .ellipse]) { toolButton($0) }
        }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let active = !document.isCropping && annotation.tool == tool
        return Button {
            document.isCropping = false
            annotation.tool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundColor(active ? .white : .primary.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .help(tool.displayName)
    }

    private var colorGroup: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationColor.allCases) { color in
                Button { annotation.color = color } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white, lineWidth: annotation.color == color ? 2 : 0))
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(color.rawValue.capitalized)
            }
        }
    }

    private var thicknessGroup: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationThickness.allCases) { thickness in
                Button { annotation.thickness = thickness } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(annotation.thickness == thickness ? Color.accentColor.opacity(0.25) : .clear)
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(annotation.thickness == thickness ? Color.accentColor : Color.primary.opacity(0.7))
                            .frame(width: thickness.swatchRadius * 2, height: thickness.swatchRadius * 2)
                    }
                }
                .buttonStyle(.plain)
                .help("\(Int(thickness.width)) pt")
            }
        }
    }

    private var historyGroup: some View {
        HStack(spacing: 4) {
            iconButton("arrow.uturn.backward", "Undo") { annotation.undo() }
                .disabled(annotation.elements.isEmpty)
            iconButton("trash", "Clear annotations") { annotation.clear() }
                .disabled(annotation.elements.isEmpty)
        }
    }

    private var transformGroup: some View {
        HStack(spacing: 4) {
            Button {
                document.isCropping.toggle()
                if document.isCropping { annotation.tool = .pen }
            } label: {
                Image(systemName: "crop")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundColor(document.isCropping ? .white : .primary.opacity(0.75))
                    .background(RoundedRectangle(cornerRadius: 7).fill(document.isCropping ? Color.accentColor : .clear))
            }
            .buttonStyle(.plain)
            .help("Crop — drag a region")

            iconButton("xmark.square", "Reset crop") { document.resetCrop() }
                .disabled(document.cropRect == nil)

            iconButton("rotate.right", "Rotate 90° clockwise") {
                document.rotateCW()
                resizeText = "\(Int(document.baseSize.width))"
            }
        }
    }

    private func iconButton(_ systemName: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundColor(.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22)
    }

    // MARK: - Timeline (GIF)

    private var timeline: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Text("Frames \(document.keptIndices.count)/\(document.frames.count)")
                    .font(.caption).foregroundColor(.secondary)

                Button("Set In") { document.trimStart = document.previewIndex }
                    .help("Trim start to the current frame")
                Button("Set Out") { document.trimEnd = document.previewIndex }
                    .help("Trim end to the current frame")

                Button("Remove \(document.selectedFrames.count)") { document.removeSelectedFrames() }
                    .disabled(document.selectedFrames.isEmpty)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "speedometer").foregroundColor(.secondary)
                    Slider(value: $document.speedMultiplier, in: 0.25...4.0, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2fx", document.speedMultiplier))
                        .font(.caption.monospacedDigit()).frame(width: 44, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)

            thumbnailStrip
        }
        .padding(.vertical, 8)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 4) {
                ForEach(Array(document.frames.enumerated()), id: \.element.id) { index, frame in
                    thumbnail(index: index, frame: frame)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 76)
    }

    private func thumbnail(index: Int, frame: EditorFrame) -> some View {
        let inRange = index >= min(document.trimStart, document.trimEnd)
            && index <= max(document.trimStart, document.trimEnd)
        let isPreview = index == document.previewIndex
        let isSelected = document.selectedFrames.contains(index)

        return Image(nsImage: NSImage(cgImage: frame.image, size: NSSize(width: 96, height: 60)))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(inRange ? 1 : 0.3)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPreview ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    if isSelected { document.selectedFrames.remove(index) }
                    else { document.selectedFrames.insert(index) }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .red : .white.opacity(0.8))
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { document.previewIndex = index }
    }

    // MARK: - Export bar

    private var exportBar: some View {
        HStack(spacing: 12) {
            if !document.isAnimated {
                HStack(spacing: 6) {
                    Text("Width").font(.caption).foregroundColor(.secondary)
                    TextField("px", text: $resizeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { applyResize() }
                    Text("px").font(.caption).foregroundColor(.secondary)
                    Button("Apply") { applyResize() }
                }
            }

            if let status = statusMessage {
                Text(status).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)

            Button {
                exportNow()
            } label: {
                if document.isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(document.isExporting)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func applyResize() {
        guard let w = Int(resizeText.trimmingCharacters(in: .whitespaces)), w > 0 else {
            resizeText = "\(Int(document.baseSize.width))"
            return
        }
        document.resizeWidth = (w == Int(document.baseSize.width)) ? nil : w
        statusMessage = "Output width \(w)px"
    }

    private func exportNow() {
        statusMessage = nil
        Task {
            document.isExporting = true
            do {
                let url = try await document.export()
                document.lastSavedURL = url
                if document.settings.copyToClipboard {
                    ClipboardHelper.copyExportedFile(at: url, isAnimated: document.isAnimated)
                }
                CaptureToast.shared.show(imageURL: url)
                statusMessage = "Saved \(url.lastPathComponent)"
            } catch {
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
            document.isExporting = false
        }
    }
}
