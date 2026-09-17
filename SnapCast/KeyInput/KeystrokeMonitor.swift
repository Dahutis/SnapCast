import AppKit

/// Listens to keyboard events during a recording and feeds KeystrokeTimeline.
/// Needs Accessibility trust (same as global shortcuts). Password fields use
/// Secure Input, so macOS never delivers those keystrokes here.
///
/// NSEvent monitors call back on the main thread.
final class KeystrokeMonitor {
    private let timeline: KeystrokeTimeline
    private let mode: KeystrokeMode
    /// SnapCast's own bindings (Stop, Cancel, …) — kept out of the video.
    private let ignoredShortcuts: [ShortcutBinding]
    private var monitors: [Any] = []

    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
    ]
    private static let deleteKeyCode: UInt16 = 51

    init(timeline: KeystrokeTimeline, mode: KeystrokeMode, ignoredShortcuts: [ShortcutBinding]) {
        self.timeline = timeline
        self.mode = mode
        self.ignoredShortcuts = ignoredShortcuts
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        // Local too, for keys pressed while a SnapCast panel is key.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    deinit { stop() }

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
                timeline.addShortcut(chord.displayString, at: now)
                return
            }

            guard mode == .allKeys else { return }
            if event.keyCode == Self.deleteKeyCode {
                timeline.addTyped("⌫", at: now)
            } else if let characters = event.characters, !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                // Printable text (0xF700+ are AppKit's private arrow/function
                // key codepoints).
                timeline.addTyped(characters, at: now)
            } else {
                // Return, Tab, Esc, arrows, … as their own bubble.
                timeline.addShortcut(chord.displayString, at: now)
            }

        default:
            break
        }
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
