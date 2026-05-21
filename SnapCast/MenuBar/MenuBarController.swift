import AppKit
import SwiftUI

class MenuBarController {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var eventMonitor: Any?
    private let settings: CaptureSettings
    private let captureManager: CaptureSessionManager

    init(settings: CaptureSettings, captureManager: CaptureSessionManager) {
        self.settings = settings
        self.captureManager = captureManager

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        setupButton()
        setupPopover()
        setupEventMonitor()

        // Wire up popover dismissal when capture starts
        captureManager.onCaptureStarting = { [weak self] in
            self?.closePopover()
        }
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "SnapCast")
        button.image = image?.withSymbolConfiguration(config)
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 320, height: 380)
        popover.behavior = .transient
        popover.animates = true

        let popoverView = PopoverView(captureManager: captureManager)
            .environmentObject(settings)
        popover.contentViewController = NSHostingController(rootView: popoverView)
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Activate so the popover receives keyboard focus — without this the
        // app stays in LSUIElement-passive state and the local NSEvent monitor
        // never sees keyDown events.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func setRecordingState(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = recording ? "stop.circle.fill" : "record.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SnapCast")?
            .withSymbolConfiguration(config)

        if recording {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
