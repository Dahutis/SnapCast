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

    private static let edgePadding: CGFloat = 24
    private static let visibleDuration: TimeInterval = 5.0
    private static let slideInDuration: TimeInterval = 0.25
    private static let slideOutDuration: TimeInterval = 0.2

    /// Sizing envelope. The toast fits the image's aspect ratio within these
    /// bounds — small captures stay compact, big captures get a proportionally
    /// larger preview, very tall captures (Full Page web especially) stay
    /// narrow but go down to ~96pt so the aspect-correct thumbnail isn't
    /// distorted with letterboxing inside the toast.
    private struct ToastSize {
        static let minW: CGFloat = 96
        static let minH: CGFloat = 72
        static let absMaxW: CGFloat = 360
        static let absMaxH: CGFloat = 280
        /// Hard ceiling as a fraction of the visible screen — keeps the toast
        /// modest on small displays / external monitors.
        static let maxFractionW: CGFloat = 0.28
        static let maxFractionH: CGFloat = 0.32
        static let fallback = CGSize(width: 220, height: 140)
    }

    func show(imageURL: URL) {
        dismissCurrent(animated: false)

        guard let image = NSImage(contentsOf: imageURL) else { return }
        // Show on whichever screen the cursor currently lives on; fall back to main.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let toastSize = Self.computeToastSize(for: image, on: screen)

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
            x: visible.maxX - toastSize.width - Self.edgePadding,
            y: visible.minY + Self.edgePadding
        )
        let startOrigin = NSPoint(
            x: visible.maxX + 20,  // off-screen right
            y: targetOrigin.y
        )
        panel.setFrame(NSRect(origin: startOrigin, size: toastSize), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        currentPanel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.slideInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: targetOrigin, size: toastSize), display: true)
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.visibleDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissCurrent(animated: true) }
        }
    }

    /// Computes a toast size that matches the image's aspect ratio within the
    /// configured envelope. Wide captures get wider toasts; tall captures
    /// (long-page screenshots) stay narrow without collapsing to a hairline.
    private static func computeToastSize(for image: NSImage, on screen: NSScreen) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 1, imageSize.height > 1 else { return ToastSize.fallback }

        let visible = screen.visibleFrame
        let maxW = min(ToastSize.absMaxW, visible.width * ToastSize.maxFractionW)
        let maxH = min(ToastSize.absMaxH, visible.height * ToastSize.maxFractionH)

        // Sanity: if the screen is so tiny our maxes drop below our mins, fall
        // back to the fixed legacy size — better to clip the toast off-screen
        // edge slightly than render an unreadable sliver.
        guard maxW >= ToastSize.minW, maxH >= ToastSize.minH else { return ToastSize.fallback }

        let aspect = imageSize.width / imageSize.height
        let envelopeAspect = maxW / maxH

        var width: CGFloat
        var height: CGFloat
        if aspect >= envelopeAspect {
            // Landscape / wider than the envelope — clamp by width.
            width = maxW
            height = max(ToastSize.minH, min(maxH, width / aspect))
        } else {
            // Portrait — clamp by height.
            height = maxH
            width = max(ToastSize.minW, min(maxW, height * aspect))
        }

        return CGSize(width: width.rounded(), height: height.rounded())
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

        // The image view IS the card: rounded corners + thin white border +
        // dark fallback fill behind the image. No inner padding — the toast
        // panel is already sized to the image's aspect ratio, so any padding
        // would re-introduce letterboxing inside the toast bounds.
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true   // animates GIFs in the preview
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        imageView.layer?.cornerRadius = 12
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        // Drop shadow on the host view (image view itself can't host shadow
        // because masksToBounds clips it).
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        self.shadow = shadow

        // Close button (top-right of toast). Tinted background so it stays
        // legible over bright captures.
        let close = NSButton()
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        close.target = self
        close.action = #selector(handleClose)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            close.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Edit button (bottom-left) — opens the capture in the post-process
        // editor. Tinted background so it stays legible over bright captures.
        let edit = NSButton()
        edit.image = NSImage(systemSymbolName: "slider.horizontal.below.rectangle", accessibilityDescription: "Edit")
        edit.imagePosition = .imageLeading
        edit.title = " Edit"
        edit.font = .systemFont(ofSize: 11, weight: .semibold)
        edit.isBordered = false
        edit.contentTintColor = .white
        edit.wantsLayer = true
        edit.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        edit.layer?.cornerRadius = 6
        edit.target = self
        edit.action = #selector(handleEdit)
        edit.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edit)

        NSLayoutConstraint.activate([
            edit.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            edit.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            edit.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Click anywhere on the thumbnail to open the file in its default app.
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleImageClick))
        imageView.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func handleClose() {
        onClose()
    }

    @objc private func handleEdit() {
        PostProcessController.shared.open(url: imageURL)
        onClose()
    }

    @objc private func handleImageClick() {
        NSWorkspace.shared.open(imageURL)
        onClose()
    }
}
