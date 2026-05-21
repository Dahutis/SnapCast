import AppKit

/// iOS-style "capture saved" preview that slides into the bottom-right of the
/// active screen after a screenshot/GIF/merger is exported.
///
/// Behavior:
/// - Slides in from the right edge with a short ease-out animation.
/// - Auto-dismisses after `visibleDuration`.
/// - Click anywhere on the thumbnail to open the file.
/// - Click the × in the top-right to dismiss early.
/// - GIFs animate inside the toast (NSImageView.animates = true).
/// - Floats above fullscreen apps so it's visible inside Unity, games, etc.
@MainActor
final class CaptureToast {
    static let shared = CaptureToast()
    private init() {}

    private var currentPanel: NSPanel?
    private var dismissTimer: Timer?

    private static let toastSize = CGSize(width: 220, height: 140)
    private static let edgePadding: CGFloat = 24
    private static let visibleDuration: TimeInterval = 5.0
    private static let slideInDuration: TimeInterval = 0.25
    private static let slideOutDuration: TimeInterval = 0.2

    func show(imageURL: URL) {
        dismissCurrent(animated: false)

        guard let image = NSImage(contentsOf: imageURL) else { return }
        // Show on whichever screen the cursor currently lives on; fall back to main.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let content = ToastContentView(image: image, imageURL: imageURL) { [weak self] in
            self?.dismissCurrent(animated: true)
        }
        panel.contentView = content

        let visible = screen.visibleFrame
        let targetOrigin = NSPoint(
            x: visible.maxX - Self.toastSize.width - Self.edgePadding,
            y: visible.minY + Self.edgePadding
        )
        let startOrigin = NSPoint(
            x: visible.maxX + 20,  // off-screen right
            y: targetOrigin.y
        )
        panel.setFrame(NSRect(origin: startOrigin, size: Self.toastSize), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        currentPanel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.slideInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: targetOrigin, size: Self.toastSize), display: true)
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.visibleDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissCurrent(animated: true) }
        }
    }

    func dismissCurrent(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel = currentPanel else { return }
        currentPanel = nil

        guard animated else {
            panel.orderOut(nil)
            return
        }

        let endFrame = NSRect(
            origin: NSPoint(x: panel.frame.origin.x + 30, y: panel.frame.origin.y),
            size: panel.frame.size
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.slideOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

private final class ToastContentView: NSView {
    private let imageURL: URL
    private let onClose: () -> Void

    init(image: NSImage, imageURL: URL, onClose: @escaping () -> Void) {
        self.imageURL = imageURL
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true

        // Rounded background card
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Drop shadow on the host view
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        self.shadow = shadow

        // Thumbnail
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true   // animates GIFs in the preview
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imageView)

        // Close button (top-right of card)
        let close = NSButton()
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        close.target = self
        close.action = #selector(handleClose)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)  // attached to host view so it can sit over the card

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),

            close.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Click anywhere on the thumbnail to open the file in its default app.
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleImageClick))
        imageView.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func handleClose() {
        onClose()
    }

    @objc private func handleImageClick() {
        NSWorkspace.shared.open(imageURL)
        onClose()
    }
}
