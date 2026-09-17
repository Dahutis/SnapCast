import AppKit
import Carbon

// MARK: - Model

/// A captured key chord (modifiers + key code).
struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt16
    let modifiersRaw: UInt   // NSEvent.ModifierFlags.rawValue masked to device-independent flags

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRaw) }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(keyCode: event.keyCode, modifiers: mods)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue == modifiersRaw
    }

    /// macOS-style chord display (e.g. "⌘⇧6", "Esc").
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += KeyCodeSymbol.string(for: keyCode)
        return s
    }
}

/// Discrete user-triggerable actions. Per-mode actions skip the popover's
/// currently-selected mode and trigger that exact capture directly.
enum ShortcutAction: String, CaseIterable, Codable {
    case recordingRegion
    case recordingFullScreen
    case recordingWindow
    case screenshotRegion
    case screenshotFullScreen
    case screenshotWindow
    case screenshotFullPage
    case mergerSession
    case stopRecording
    case pauseRecording
    case cancelCurrent
    case toggleAnnotation
    case openEditor
    case recordingRegionAnnotate
    case screenshotRegionAnnotate

    var displayName: String {
        switch self {
        case .recordingRegion:      return "Record — Region"
        case .recordingFullScreen:  return "Record — Full Screen"
        case .recordingWindow:      return "Record — Window"
        case .screenshotRegion:     return "Screenshot — Region"
        case .screenshotFullScreen: return "Screenshot — Full Screen"
        case .screenshotWindow:     return "Screenshot — Window"
        case .screenshotFullPage:   return "Screenshot — Full Page"
        case .mergerSession:        return "Merger Session"
        case .stopRecording:        return "Stop Recording"
        case .pauseRecording:       return "Pause / Resume Recording"
        case .cancelCurrent:        return "Cancel"
        case .toggleAnnotation:     return "Annotation — Paint / Passthrough"
        case .openEditor:           return "Open Editor (last capture)"
        case .recordingRegionAnnotate:  return "Record — Region + Annotate"
        case .screenshotRegionAnnotate: return "Screenshot — Region + Annotate"
        }
    }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .recordingRegion:      return ShortcutBinding(keyCode: 22, modifiers: [.command, .shift]) // ⌘⇧6
        case .recordingFullScreen:  return ShortcutBinding(keyCode: 26, modifiers: [.command, .shift]) // ⌘⇧7
        case .recordingWindow:      return ShortcutBinding(keyCode: 28, modifiers: [.command, .shift]) // ⌘⇧8
        case .screenshotRegion:     return ShortcutBinding(keyCode: 25, modifiers: [.command, .shift]) // ⌘⇧9
        case .screenshotFullScreen: return ShortcutBinding(keyCode: 29, modifiers: [.command, .shift]) // ⌘⇧0
        case .screenshotWindow:     return nil
        case .screenshotFullPage:   return nil
        case .mergerSession:        return nil
        case .stopRecording:        return ShortcutBinding(keyCode: 47, modifiers: [.command, .shift]) // ⌘⇧.
        case .pauseRecording:       return ShortcutBinding(keyCode: 43, modifiers: [.command, .shift]) // ⌘⇧,
        case .cancelCurrent:        return ShortcutBinding(keyCode: 53, modifiers: [])                  // Esc
        case .toggleAnnotation:     return ShortcutBinding(keyCode: 35, modifiers: [.command, .shift]) // ⌘⇧P
        case .openEditor:           return ShortcutBinding(keyCode: 14, modifiers: [.command, .shift]) // ⌘⇧E
        case .recordingRegionAnnotate:  return ShortcutBinding(keyCode: 22, modifiers: [.control, .shift]) // ⌃⇧6
        case .screenshotRegionAnnotate: return ShortcutBinding(keyCode: 25, modifiers: [.control, .shift]) // ⌃⇧9
        }
    }
}

/// Global flag so the dispatcher pauses while the user is rebinding a shortcut
/// (otherwise pressing the existing chord during rebind would re-fire the action).
enum ShortcutRecording {
    static var isActive: Bool = false
}

/// Renders an NSEvent.keyCode as a display string. Uses Carbon UCKeyTranslate
/// for printable keys; falls back to a curated map for special keys.
enum KeyCodeSymbol {
    static func string(for keyCode: UInt16) -> String {
        if let named = specialKeyName[keyCode] { return named }
        return translateUnshifted(keyCode: keyCode)?.uppercased() ?? "?"
    }

    private static let specialKeyName: [UInt16: String] = [
        53: "Esc", 36: "↩", 76: "⌤", 48: "⇥", 49: "Space",
        51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        116: "PgUp", 121: "PgDn", 115: "Home", 119: "End",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func translateUnshifted(keyCode: UInt16) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(cfData) else { return nil }
        let layoutPtr = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        let result = UCKeyTranslate(
            layoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0, // unshifted
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )
        guard result == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}

// MARK: - Dispatcher

class KeyboardShortcuts {
    private let captureManager: CaptureSessionManager
    private let settings: CaptureSettings
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(captureManager: CaptureSessionManager, settings: CaptureSettings) {
        self.captureManager = captureManager
        self.settings = settings
        setupMonitors()
    }

    private func setupMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if ShortcutRecording.isActive { return }
        for action in ShortcutAction.allCases {
            guard let binding = settings.shortcuts[action.rawValue],
                  binding.matches(event) else { continue }
            dispatch(action)
            return
        }
    }

    private func dispatch(_ action: ShortcutAction) {
        Task { @MainActor in
            let busy = captureManager.isRecording || captureManager.isTakingScreenshot
            switch action {
            case .recordingRegion:
                if !busy { captureManager.startCapture(mode: .region) }
            case .recordingFullScreen:
                if !busy { captureManager.startCapture(mode: .fullScreen) }
            case .recordingWindow:
                if !busy { captureManager.startCapture(mode: .window) }
            case .screenshotRegion:
                if !busy { captureManager.takeScreenshot(mode: .region) }
            case .screenshotFullScreen:
                if !busy { captureManager.takeScreenshot(mode: .fullScreen) }
            case .screenshotWindow:
                if !busy { captureManager.takeScreenshot(mode: .window) }
            case .screenshotFullPage:
                if !busy { captureManager.takeScreenshot(mode: .fullPage) }
            case .mergerSession:
                if !busy { captureManager.startMerger() }
            case .stopRecording:
                if captureManager.isRecording { captureManager.stopCapture() }
            case .pauseRecording:
                if captureManager.isRecording { captureManager.togglePause() }
            case .cancelCurrent:
                if captureManager.isRecording { captureManager.cancelCapture() }
            case .toggleAnnotation:
                AnnotationSession.current?.toggleCanvasActive()
            case .openEditor:
                if let url = captureManager.lastExportedURL {
                    PostProcessController.shared.open(url: url)
                }
            case .recordingRegionAnnotate:
                if !busy { captureManager.startCapture(mode: .region, forceAnnotate: true) }
            case .screenshotRegionAnnotate:
                if !busy { captureManager.takeScreenshot(mode: .region, forceAnnotate: true) }
            }
        }
    }

    deinit {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    }
}
