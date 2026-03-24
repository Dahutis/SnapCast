import AppKit
import Carbon

class KeyboardShortcuts {
    private let captureManager: CaptureSessionManager
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(captureManager: CaptureSessionManager) {
        self.captureManager = captureManager
        setupMonitors()
    }

    private func setupMonitors() {
        // Global monitor for when app is not focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor for when app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape - cancel/stop
        if event.keyCode == 53 { // kVK_Escape
            Task { @MainActor in
                if captureManager.isRecording {
                    captureManager.cancelCapture()
                }
            }
            return
        }

        // Cmd+Shift+6 - start region capture
        if modifiers == [.command, .shift] && event.keyCode == 22 { // kVK_ANSI_6
            Task { @MainActor in
                if !captureManager.isRecording {
                    captureManager.startCapture()
                }
            }
            return
        }

        // Cmd+Shift+. - stop recording
        if modifiers == [.command, .shift] && event.keyCode == 47 { // kVK_ANSI_Period
            Task { @MainActor in
                if captureManager.isRecording {
                    captureManager.stopCapture()
                }
            }
            return
        }
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
