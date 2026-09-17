import AppKit
import CoreGraphics

/// Thread-safe list of recent mouse clicks in CG global coordinates, drawn as
/// expanding rings into recorded frames.
final class ClickTimeline: @unchecked Sendable {
    enum Button {
        case left
        case right
    }

    struct VisibleClick {
        let location: CGPoint
        let button: Button
        /// 0 at the click, 1 when the ripple has finished.
        let progress: CGFloat
    }

    private struct Click {
        let location: CGPoint
        let button: Button
        let time: Double
    }

    static let duration: Double = 0.5

    private let lock = NSLock()
    private var clicks: [Click] = []

    func add(at location: CGPoint, button: Button, time: Double) {
        lock.lock()
        defer { lock.unlock() }
        clicks.append(Click(location: location, button: button, time: time))
        clicks.removeAll { $0.time + Self.duration < time - 5 }
    }

    func visibleClicks(at time: Double) -> [VisibleClick] {
        lock.lock()
        defer { lock.unlock() }
        return clicks.compactMap { click in
            let elapsed = time - click.time
            guard elapsed >= 0, elapsed < Self.duration else { return nil }
            return VisibleClick(location: click.location, button: click.button, progress: CGFloat(elapsed / Self.duration))
        }
    }

    func needsFrame(at time: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clicks.contains { $0.time <= time && time <= $0.time + Self.duration + 0.1 }
    }

    // MARK: - Drawing

    /// Maps each click from global points into frame pixels (bottom-left
    /// origin) and draws a fading, expanding ring with a soft center dot.
    static func draw(_ clicks: [VisibleClick], captureRect: CGRect, in context: CGContext, canvas: CGSize) {
        guard captureRect.width > 0, captureRect.height > 0 else { return }
        let scale = canvas.width / captureRect.width
        let baseRadius = 16 * scale
        let lineWidth = max(2, 3 * scale)

        for click in clicks {
            let x = (click.location.x - captureRect.minX) * scale
            let y = canvas.height - (click.location.y - captureRect.minY) * (canvas.height / captureRect.height)
            guard x > -baseRadius * 2, x < canvas.width + baseRadius * 2,
                  y > -baseRadius * 2, y < canvas.height + baseRadius * 2 else { continue }

            let p = click.progress
            let fade = 1 - p
            let color: (CGFloat, CGFloat, CGFloat) = click.button == .left ? (1, 0.8, 0.1) : (0.3, 0.75, 1)

            context.saveGState()
            let dotRadius = baseRadius * 0.55
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 0.35 * fade))
            context.fillEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

            let radius = baseRadius * (0.6 + 0.9 * p)
            context.setStrokeColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 0.95 * fade))
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.restoreGState()
        }
    }
}

/// Listen-only event tap for mouse-down events. Mouse taps don't need Input
/// Monitoring, unlike keyboard taps.
final class ClickMonitor {
    private let timeline: ClickTimeline
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(timeline: ClickTimeline) {
        self.timeline = timeline
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<ClickMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            // Unretained: stop() (also run from deinit) removes the tap first.
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            // ⌃-click opens context menus, so show it as a right click.
            let button: ClickTimeline.Button = event.flags.contains(.maskControl) ? .right : .left
            timeline.add(at: event.location, button: button, time: KeystrokeTimeline.now)
        case .rightMouseDown:
            timeline.add(at: event.location, button: .right, time: KeystrokeTimeline.now)
        default:
            break
        }
    }
}
