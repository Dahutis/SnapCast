import Foundation
import CoreMedia

/// Thread-safe history of key captions ("⌘⇧4", "hello", "⌥"). KeystrokeMonitor
/// writes on the main thread; recorders read from their capture queues using
/// each frame's host-clock timestamp, so the overlay is burned into frames at
/// the moment the key was pressed rather than drawn on screen.
final class KeystrokeTimeline: @unchecked Sendable {
    enum Kind {
        case shortcut
        case typing
        case modifiers
    }

    struct Caption {
        var text: String
        var kind: Kind
        let start: Double
        var lastUpdate: Double
        /// Modifier captions stay up while the keys are held.
        var isHeld = false
        /// Shortcut text without the "×N" suffix, for repeat detection.
        var baseText: String
        var repeatCount = 1

        var hold: Double {
            kind == .modifiers ? KeystrokeTimeline.modifierHoldDuration : KeystrokeTimeline.holdDuration
        }

        /// When the caption starts fading out.
        var end: Double { isHeld ? .infinity : lastUpdate + hold }
    }

    struct VisibleCaption {
        let text: String
        let alpha: CGFloat
    }

    static let holdDuration: Double = 1.4
    static let modifierHoldDuration: Double = 0.4
    static let fadeDuration: Double = 0.25
    static let maxVisible = 3
    static let maxTypingLength = 32

    /// Host clock in seconds — the same clock ScreenCaptureKit stamps frames with.
    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private let lock = NSLock()
    private var captions: [Caption] = []

    // MARK: - Writing (main thread)

    func addShortcut(_ text: String, at time: Double) {
        lock.lock()
        defer { lock.unlock() }

        dropModifierCaption(continuing: { $0.kind == .shortcut && $0.baseText == text }, at: time)
        if var last = captions.last, last.kind == .shortcut, last.baseText == text, time < last.end {
            last.repeatCount += 1
            last.text = "\(text) ×\(last.repeatCount)"
            last.lastUpdate = time
            captions[captions.count - 1] = last
        } else if !replaceModifierCaption(with: text, kind: .shortcut, at: time) {
            captions.append(Caption(text: text, kind: .shortcut, start: time, lastUpdate: time, baseText: text))
        }
        prune(before: time)
    }

    func addTyped(_ characters: String, at time: Double) {
        lock.lock()
        defer { lock.unlock() }

        dropModifierCaption(continuing: { $0.kind == .typing }, at: time)
        if var last = captions.last, last.kind == .typing, time < last.end {
            var text = last.baseText + characters
            if text.count > Self.maxTypingLength {
                text = String(text.suffix(Self.maxTypingLength))
            }
            last.baseText = text
            last.text = text.count == Self.maxTypingLength ? "…" + text : text
            last.lastUpdate = time
            captions[captions.count - 1] = last
        } else if !replaceModifierCaption(with: characters, kind: .typing, at: time) {
            captions.append(Caption(text: characters, kind: .typing, start: time, lastUpdate: time, baseText: characters))
        }
        prune(before: time)
    }

    /// `symbols` is the currently held modifier set ("⌃⌥"), or nil when all
    /// modifiers were released.
    func setModifiers(_ symbols: String?, at time: Double) {
        lock.lock()
        defer { lock.unlock() }

        let lastIndex = captions.indices.last
        if let symbols {
            if let i = lastIndex, captions[i].kind == .modifiers, captions[i].isHeld {
                captions[i].text = symbols
                captions[i].baseText = symbols
                captions[i].lastUpdate = time
            } else {
                var caption = Caption(text: symbols, kind: .modifiers, start: time, lastUpdate: time, baseText: symbols)
                caption.isHeld = true
                captions.append(caption)
            }
        } else if let i = lastIndex, captions[i].isHeld {
            captions[i].isHeld = false
            captions[i].lastUpdate = time
        }
        prune(before: time)
    }

    /// A held-modifier bubble ("⌘") turns into the chord it became ("⌘C")
    /// instead of leaving a stray bubble behind.
    private func replaceModifierCaption(with text: String, kind: Kind, at time: Double) -> Bool {
        guard var last = captions.last, last.kind == .modifiers, time < last.end else { return false }
        last.text = text
        last.baseText = text
        last.kind = kind
        last.isHeld = false
        last.lastUpdate = time
        captions[captions.count - 1] = last
        return true
    }

    /// Pressing ⌘ again for a repeated ⌘C, or ⇧ mid-word, briefly pushes a
    /// modifier bubble on top of the caption the key continues. Drop it so
    /// the repeat counter / typed text keep going in the same bubble.
    private func dropModifierCaption(continuing matches: (Caption) -> Bool, at time: Double) {
        guard captions.count >= 2,
              captions[captions.count - 1].kind == .modifiers,
              matches(captions[captions.count - 2]),
              time < captions[captions.count - 2].end else { return }
        captions.removeLast()
    }

    private func prune(before time: Double) {
        // Keep a few seconds of history: frames are timestamped slightly
        // before they're delivered, so readers look a little into the past.
        captions.removeAll { $0.end + Self.fadeDuration < time - 5 }
    }

    // MARK: - Reading (capture queues)

    /// Captions to draw on a frame captured at `time`, oldest first.
    func visibleCaptions(at time: Double) -> [VisibleCaption] {
        lock.lock()
        defer { lock.unlock() }

        var visible: [VisibleCaption] = []
        for caption in captions where caption.start <= time {
            let end = caption.end
            if time < end {
                visible.append(VisibleCaption(text: caption.text, alpha: 1))
            } else if time < end + Self.fadeDuration {
                let alpha = 1 - (time - end) / Self.fadeDuration
                visible.append(VisibleCaption(text: caption.text, alpha: CGFloat(alpha)))
            }
        }
        return Array(visible.suffix(Self.maxVisible))
    }

    /// True while a caption is on screen or has just finished fading — the
    /// recorder then keeps emitting frames even if the screen is static.
    func needsFrame(at time: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return captions.contains { $0.start <= time && time <= $0.end + Self.fadeDuration + 0.1 }
    }
}
