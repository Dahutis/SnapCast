import AppKit
import Carbon

/// Listens to keyboard events during a recording and feeds KeystrokeTimeline.
/// Uses a listen-only CGEventTap, which needs Input Monitoring permission —
/// an NSEvent global monitor with only Accessibility receives modifier
/// changes but no key presses on current macOS. Password fields use Secure
/// Input, so macOS never delivers those keystrokes here.
///
/// The tap's run loop source is on the main run loop, so callbacks arrive on
/// the main thread.
final class KeystrokeMonitor {
    private let timeline: KeystrokeTimeline
    private let mode: KeystrokeMode
    /// SnapCast's own bindings (Stop, Cancel, …) — kept out of the video.
    private let ignoredShortcuts: [ShortcutBinding]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Pending dead key (e.g. Czech ´ or ˇ) carried into the next keystroke.
    /// Event taps see raw keys before the text system composes them, so
    /// SnapCast composes "´" + "e" → "é" itself.
    private var deadKeyState: UInt32 = 0

    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
    ]
    private static let deleteKeyCode: UInt16 = 51

    init(timeline: KeystrokeTimeline, mode: KeystrokeMode, ignoredShortcuts: [ShortcutBinding]) {
        self.timeline = timeline
        self.mode = mode
        self.ignoredShortcuts = ignoredShortcuts
    }

    /// Returns false when the tap can't be created (Input Monitoring not granted).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<KeystrokeMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            // Unretained: stop() (also run from deinit) tears the tap down
            // before self goes away.
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables taps whose callbacks stall; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown, .flagsChanged:
            if let nsEvent = NSEvent(cgEvent: event) {
                handle(nsEvent)
            }
        default:
            break
        }
    }

    private func handle(_ event: NSEvent) {
        let now = KeystrokeTimeline.now
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])

        switch event.type {
        case .flagsChanged:
            // Bare modifier bubbles are noise in shortcuts-only mode.
            guard mode == .allKeys else { return }
            timeline.setModifiers(modifiers.isEmpty ? nil : Self.symbols(for: modifiers), at: now)

        case .keyDown:
            guard !ignoredShortcuts.contains(where: { $0.matches(event) }),
                  let chord = ShortcutBinding(event: event) else { return }

            let isCommandChord = !modifiers.isDisjoint(with: [.control, .option, .command])
            if isCommandChord || Self.functionKeyCodes.contains(event.keyCode) {
                deadKeyState = 0
                timeline.addShortcut(chord.displayString, at: now)
                return
            }

            guard mode == .allKeys else { return }
            if event.keyCode == Self.deleteKeyCode {
                deadKeyState = 0
                timeline.addTyped("⌫", at: now)
                return
            }

            let characters = typedCharacters(for: event)
            if characters.isEmpty, deadKeyState != 0 {
                // Dead key pressed; wait for the key it combines with.
                return
            }
            if !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                // Printable text (0xF700+ are AppKit's private arrow/function
                // key codepoints).
                timeline.addTyped(characters, at: now)
            } else {
                // Return, Tab, Esc, arrows, … as their own bubble.
                deadKeyState = 0
                timeline.addShortcut(chord.displayString, at: now)
            }

        default:
            break
        }
    }

    /// Translates the key through the active keyboard layout, honouring dead
    /// keys. Returns "" while a dead key is pending.
    private func typedCharacters(for event: NSEvent) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(unsafeBitCast(layoutData, to: CFData.self)) else {
            return event.characters ?? ""
        }
        let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        let flags = event.modifierFlags
        var modifierState: UInt32 = 0
        if flags.contains(.shift) { modifierState |= UInt32(shiftKey >> 8) }
        if flags.contains(.capsLock) { modifierState |= UInt32(alphaLock >> 8) }

        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = UCKeyTranslate(
            layout, event.keyCode, UInt16(kUCKeyActionDown), modifierState,
            UInt32(LMGetKbdType()), 0, &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr else { return event.characters ?? "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }
}
