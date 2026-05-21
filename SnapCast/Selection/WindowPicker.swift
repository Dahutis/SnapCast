import AppKit
import SwiftUI
import ScreenCaptureKit

/// Window/display selection UI. Public API is unchanged from the previous AppKit
/// implementation — `pickWindow()` and `pickDisplay()` — but the window picker
/// now presents a SwiftUI panel with live thumbnails, search, grouping, and
/// keyboard navigation. Display picker keeps the silent mouse-location fallback
/// (no UI for single display; no UI was ever shown for multi-display either —
/// that hasn't changed).
class WindowPicker {
    private static var activePanel: NSPanel?

    /// Bundle IDs whose windows are always system chrome (Dock, menu bar items,
    /// Control Center, etc.) — never meaningful capture targets. WindowServer
    /// itself owns Backstop/Underbelly windows but those are already excluded
    /// by the `windowLayer == 0` filter; included here defensively.
    private static let systemBundleIDs: Set<String> = [
        "com.apple.WindowServer",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.wallpaper.WallpaperAgent",
    ]

    @MainActor
    static func pickWindow() async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            let ownBundleID = Bundle.main.bundleIdentifier ?? ""
            let candidateWindows = content.windows.filter { window in
                guard let app = window.owningApplication else { return false }
                guard app.bundleIdentifier != ownBundleID else { return false }
                guard window.isOnScreen else { return false }
                guard window.frame.width > 50, window.frame.height > 50 else { return false }
                // Only show normal-level windows. Higher/lower layers are
                // WindowServer chrome (per-display Backstop, Underbelly), the
                // Dock, menu bar, wallpaper, screensaver, etc. — never useful
                // capture targets and confusing if shown.
                guard window.windowLayer == 0 else { return false }
                guard !Self.systemBundleIDs.contains(app.bundleIdentifier) else { return false }
                return true
            }

            guard !candidateWindows.isEmpty else { return nil }

            // Skip the picker if there's only one candidate — nothing to choose.
            if candidateWindows.count == 1 {
                return candidateWindows.first
            }

            return await withCheckedContinuation { continuation in
                presentPicker(windows: candidateWindows) { selected in
                    continuation.resume(returning: selected)
                }
            }
        } catch {
            return nil
        }
    }

    @MainActor
    static func pickDisplay() async -> (SCDisplay, [SCWindow])? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            guard !content.displays.isEmpty else { return nil }

            let ownBundleID = Bundle.main.bundleIdentifier ?? ""
            let excludedWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == ownBundleID
            }

            if content.displays.count == 1 {
                return (content.displays[0], excludedWindows)
            }

            // Multiple displays: pick based on current mouse location.
            let mouseLocation = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                if screen.frame.contains(mouseLocation) {
                    let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                    if let display = content.displays.first(where: { $0.displayID == screenNumber }) {
                        return (display, excludedWindows)
                    }
                }
            }

            return (content.displays[0], excludedWindows)
        } catch {
            return nil
        }
    }

    // MARK: - SwiftUI Panel

    @MainActor
    private static func presentPicker(windows: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        activePanel?.orderOut(nil)

        let panel = WindowPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let finish: (SCWindow?) -> Void = { selected in
            panel.orderOut(nil)
            activePanel = nil
            completion(selected)
        }

        let view = WindowPickerView(
            windows: windows,
            onSelect: { finish($0) },
            onCancel: { finish(nil) }
        )

        let host = NSHostingView(rootView: view)
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Center on whichever screen the cursor is on; cursor-screen feels more
        // natural than "main display" when working across multiple monitors.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = screen {
            let frame = panel.frame
            let origin = NSPoint(
                x: screen.frame.midX - frame.width / 2,
                y: screen.frame.midY - frame.height / 2
            )
            panel.setFrameOrigin(origin)
        }

        activePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Panel

private final class WindowPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - SwiftUI View

private struct WindowPickerView: View {
    let windows: [SCWindow]
    let onSelect: (SCWindow) -> Void
    let onCancel: () -> Void

    @State private var searchText: String = ""
    @State private var selectedID: CGWindowID?
    @StateObject private var loader = WindowThumbnailLoader()
    @FocusState private var searchFocused: Bool

    private var groups: [WindowGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = windows.filter { window in
            guard !trimmed.isEmpty else { return true }
            let app = (window.owningApplication?.applicationName ?? "").lowercased()
            let title = (window.title ?? "").lowercased()
            return app.contains(trimmed) || title.contains(trimmed)
        }

        let grouped = Dictionary(grouping: filtered) { window in
            window.owningApplication?.bundleIdentifier ?? "unknown"
        }

        return grouped.map { (bundleID, windows) -> WindowGroup in
            let app = windows.first?.owningApplication
            return WindowGroup(
                bundleID: bundleID,
                name: app?.applicationName ?? "Unknown",
                icon: WindowPickerView.appIcon(forBundleID: bundleID),
                windows: windows.sorted { ($0.title ?? "") < ($1.title ?? "") }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var flatList: [SCWindow] {
        groups.flatMap { $0.windows }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        .frame(width: 560, height: 500)
        .background(
            ZStack {
                VisualEffectBackground(material: .menu, blending: .behindWindow)
                Color.black.opacity(0.08)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear {
            selectedID = flatList.first?.windowID
            loader.load(windows: windows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        .background(
            KeyEventHandlingView(
                onArrow: handleArrow,
                onEnter: handleEnter,
                onEscape: { onCancel() }
            )
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("Select Window")
                .font(.system(size: 13, weight: .semibold))

            Divider().frame(height: 14).opacity(0.4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search apps and windows…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit { handleEnter() }
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )

            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No matching windows")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            AppGroupSection(
                                group: group,
                                selectedID: selectedID,
                                loader: loader,
                                onSelect: { window in onSelect(window) },
                                onHover: { id in selectedID = id }
                            )
                        }
                    }
                    .padding(16)
                }
                .onChange(of: selectedID) { newValue in
                    if let id = newValue {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Keyboard navigation

    private func handleArrow(_ direction: ArrowDirection) {
        let list = flatList
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex(where: { $0.windowID == selectedID }) ?? 0
        let columns = 2
        let nextIndex: Int
        switch direction {
        case .up:    nextIndex = max(0, currentIndex - columns)
        case .down:  nextIndex = min(list.count - 1, currentIndex + columns)
        case .left:  nextIndex = max(0, currentIndex - 1)
        case .right: nextIndex = min(list.count - 1, currentIndex + 1)
        }
        selectedID = list[nextIndex].windowID
    }

    private func handleEnter() {
        if let id = selectedID, let window = windows.first(where: { $0.windowID == id }) {
            onSelect(window)
        }
    }

    private static func appIcon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct WindowGroup: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let windows: [SCWindow]

    var id: String { bundleID }
}

private struct AppGroupSection: View {
    let group: WindowGroup
    let selectedID: CGWindowID?
    @ObservedObject var loader: WindowThumbnailLoader
    let onSelect: (SCWindow) -> Void
    let onHover: (CGWindowID) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = group.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(group.windows.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08))
                    )
                Spacer()
            }
            .padding(.horizontal, 2)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(group.windows, id: \.windowID) { window in
                    WindowThumbnailCard(
                        window: window,
                        thumbnail: loader.thumbnails[window.windowID],
                        appIcon: group.icon,
                        isSelected: selectedID == window.windowID,
                        onSelect: { onSelect(window) },
                        onHover: { onHover(window.windowID) }
                    )
                    .id(window.windowID)
                }
            }
        }
    }
}

private struct WindowThumbnailCard: View {
    let window: SCWindow
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void
    let onHover: () -> Void

    @State private var isHovering = false

    private var titleText: String {
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return window.owningApplication?.applicationName ?? "Untitled Window"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.18))

                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(2)
                    } else {
                        if let appIcon = appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 36, height: 36)
                                .opacity(0.55)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .frame(height: 124)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.white.opacity(0.06),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )

                HStack(spacing: 6) {
                    if let appIcon = appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(titleText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.14)
                            : (isHovering ? Color.primary.opacity(0.06) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { onHover() }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Thumbnail Loader

@MainActor
private final class WindowThumbnailLoader: ObservableObject {
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    private var loadedIDs: Set<CGWindowID> = []

    func load(windows: [SCWindow]) {
        for window in windows where !loadedIDs.contains(window.windowID) {
            loadedIDs.insert(window.windowID)
            Task { [weak self] in
                if let image = await Self.capture(window: window) {
                    self?.thumbnails[window.windowID] = image
                }
            }
        }
    }

    private static func capture(window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Cap thumbnail size — full window resolution is wasteful for a 240px card.
        let targetWidth: CGFloat = 720
        let scale = min(1.0, targetWidth / max(window.frame.width, 1))
        config.width = max(160, Int(window.frame.width * scale))
        config.height = max(120, Int(window.frame.height * scale))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            let cg = try await ScreenshotCapture.captureSingleFrame(filter: filter, configuration: config)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch {
            return nil
        }
    }
}

// MARK: - Visual Effect Background

private struct VisualEffectBackground: NSViewRepresentable {
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

// MARK: - Keyboard handler

private enum ArrowDirection { case up, down, left, right }

private struct KeyEventHandlingView: NSViewRepresentable {
    let onArrow: (ArrowDirection) -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onArrow = onArrow
        v.onEnter = onEnter
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onArrow = onArrow
        nsView.onEnter = onEnter
        nsView.onEscape = onEscape
    }

    final class KeyView: NSView {
        var onArrow: ((ArrowDirection) -> Void)?
        var onEnter: (() -> Void)?
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Sit transparently behind the SwiftUI content as a backstop for
            // arrow keys / Enter / Esc when nothing else has focus.
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: onEscape?()                  // Esc
            case 36, 76: onEnter?()                // Return / Enter
            case 123: onArrow?(.left)              // ←
            case 124: onArrow?(.right)             // →
            case 125: onArrow?(.down)              // ↓
            case 126: onArrow?(.up)                // ↑
            default: super.keyDown(with: event)
            }
        }
    }
}
