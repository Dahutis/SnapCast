import AppKit
import ScreenCaptureKit

class WindowPicker {
    private static var activePanel: NSPanel?

    /// Shows a picker panel listing all available windows. Returns the selected SCWindow.
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
                return true
            }

            guard !candidateWindows.isEmpty else { return nil }

            // If only one window, just return it
            if candidateWindows.count == 1 {
                return candidateWindows.first
            }

            return await withCheckedContinuation { continuation in
                showPickerPanel(windows: candidateWindows) { selected in
                    continuation.resume(returning: selected)
                }
            }
        } catch {
            return nil
        }
    }

    /// Shows a picker panel listing all displays. Returns the selected SCDisplay.
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

            // If only one display, just return it
            if content.displays.count == 1 {
                return (content.displays[0], excludedWindows)
            }

            // Multiple displays: pick based on current mouse location
            let mouseLocation = NSEvent.mouseLocation
            let screens = NSScreen.screens

            for screen in screens {
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

    // MARK: - Picker Panel

    @MainActor
    private static func showPickerPanel(windows: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Select Window"
        panel.level = .floating
        panel.center()
        panel.isReleasedWhenClosed = false
        activePanel = panel

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 50, width: 400, height: 370))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for window in windows {
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let title = window.title ?? ""
            let label = title.isEmpty ? appName : "\(appName) — \(title)"
            let size = "\(Int(window.frame.width))×\(Int(window.frame.height))"

            let button = NSButton(title: "\(label)  [\(size)]", target: nil, action: nil)
            button.bezelStyle = .recessed
            button.setButtonType(.momentaryPushIn)
            button.alignment = .left
            button.font = NSFont.systemFont(ofSize: 13)
            button.translatesAutoresizingMaskIntoConstraints = false

            let capturedWindow = window
            button.target = nil
            button.action = nil

            // Use a click handler via subclass
            let clickButton = ClickableButton(title: "\(label)  [\(size)]") {
                panel.orderOut(nil)
                activePanel = nil
                completion(capturedWindow)
            }
            clickButton.alignment = .left
            clickButton.font = NSFont.systemFont(ofSize: 13)
            clickButton.translatesAutoresizingMaskIntoConstraints = false
            clickButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true

            stackView.addArrangedSubview(clickButton)
        }

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -8),
        ])

        scrollView.documentView = containerView
        containerView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        // Cancel button
        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 300, y: 10, width: 80, height: 30)
        let cancelClick = ClickableButton(title: "Cancel") {
            panel.orderOut(nil)
            activePanel = nil
            completion(nil)
        }
        cancelClick.frame = NSRect(x: 300, y: 10, width: 80, height: 30)
        cancelClick.bezelStyle = .rounded

        panel.contentView?.addSubview(scrollView)
        panel.contentView?.addSubview(cancelClick)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Simple NSButton subclass that calls a closure on click
private class ClickableButton: NSButton {
    private var onClick: (() -> Void)?

    convenience init(title: String, onClick: @escaping () -> Void) {
        self.init()
        self.title = title
        self.onClick = onClick
        self.bezelStyle = .recessed
        self.setButtonType(.momentaryPushIn)
        self.target = self
        self.action = #selector(handleClick)
    }

    @objc private func handleClick() {
        onClick?()
    }
}
