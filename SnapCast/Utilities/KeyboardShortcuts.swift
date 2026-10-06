import AppKit
import Carbon
import Combine

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

    /// Modifier mask in the form `RegisterEventHotKey` expects.
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if modifiers.contains(.command) { mods |= UInt32(cmdKey) }
        if modifiers.contains(.shift)   { mods |= UInt32(shiftKey) }
        if modifiers.contains(.option)  { mods |= UInt32(optionKey) }
        if modifiers.contains(.control) { mods |= UInt32(controlKey) }
        return mods
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

/// Global flag so the dispatcher pauses while the user is rebinding a shortcut.
/// Registered hot keys swallow their chord before the recorder field sees it,
/// so the dispatcher unregisters everything while this is set.
enum ShortcutRecording {
    static let didChangeNotification = Notification.Name("ShortcutRecordingDidChange")

    static var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
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

/// Fires actions through Carbon `RegisterEventHotKey`, which works while
/// SnapCast is in the background without Accessibility or Input Monitoring.
///
/// A registered hot key swallows its chord in every app, so bindings that only
/// make sense during a capture (Stop, Pause, Esc, annotation toggle) are
/// registered only while that capture is running. Otherwise ⌘⇧P or Esc would
/// stop working everywhere else just because SnapCast is launched.
@MainActor
class KeyboardShortcuts {
    private let captureManager: CaptureSessionManager
    private let settings: CaptureSettings
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    /// "SNCP" — signature shared by all of SnapCast's hot keys.
    private static let signature: OSType = 0x534E_4350

    init(captureManager: CaptureSessionManager, settings: CaptureSettings) {
        self.captureManager = captureManager
        self.settings = settings
        installEventHandler()
        observeState()
        registerHotKeys()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userInfo in
                guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == KeyboardShortcuts.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let dispatcher = Unmanaged<KeyboardShortcuts>.fromOpaque(userInfo).takeUnretainedValue()
                // Hot key events arrive on the main run loop.
                MainActor.assumeIsolated { dispatcher.handleHotKey(id: hotKeyID.id) }
                return noErr
            },
            1,
            &spec,
            // Unretained: deinit removes the handler first.
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    /// Re-register whenever the set of bindings or the set of active
    /// session-only actions changes.
    private func observeState() {
        settings.$shortcuts
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)
        captureManager.$isRecording
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)
        for name in [ShortcutRecording.didChangeNotification, AnnotationSession.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.registerHotKeys()
            })
        }
    }

    private func isAvailable(_ action: ShortcutAction) -> Bool {
        switch action {
        case .stopRecording, .pauseRecording, .cancelCurrent:
            return captureManager.isRecording
        case .toggleAnnotation:
            return AnnotationSession.current != nil
        default:
            return true
        }
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        if ShortcutRecording.isActive { return }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard isAvailable(action), let binding = settings.shortcuts[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            // Fails if another app (or an earlier SnapCast action) already owns
            // the chord; the action then simply has no hot key.
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode), binding.carbonModifiers, id,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref { hotKeyRefs.append(ref) }
        }
    }

    private func unregisterHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
    }

    private func handleHotKey(id: UInt32) {
        guard !ShortcutRecording.isActive else { return }
        let actions = ShortcutAction.allCases
        guard Int(id) < actions.count else { return }
        dispatch(actions[Int(id)])
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
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
