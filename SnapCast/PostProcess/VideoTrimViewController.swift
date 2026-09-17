import AppKit
import AVFoundation
import AVKit

/// Trims an MP4 recording using AVPlayerView's built-in trim bar (the same UI
/// as QuickTime Player). The trimmed range is exported with passthrough, so
/// nothing is re-encoded and saving is near-instant; the original file stays
/// untouched and the result is saved next to it as "…_trimmed.mp4".
final class VideoTrimViewController: NSViewController {
    private let url: URL
    private let settings: CaptureSettings
    private let onClose: () -> Void

    private let playerView = AVPlayerView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusObservation: NSKeyValueObservation?
    private var didBeginTrimming = false

    init(url: URL, settings: CaptureSettings, onClose: @escaping () -> Void) {
        self.url = url
        self.settings = settings
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        title = url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        playerView.controlsStyle = .floating
        playerView.player = AVPlayer(url: url)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.wantsLayer = true
        statusLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        statusLabel.layer?.cornerRadius = 6
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didBeginTrimming, let item = playerView.player?.currentItem else { return }

        // The trim bar can only open once the item is ready to play.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.beginTrimming() }
        }
    }

    func stopPlayback() {
        playerView.player?.pause()
    }

    private func beginTrimming() {
        guard !didBeginTrimming, playerView.canBeginTrimming else { return }
        didBeginTrimming = true
        statusObservation = nil

        playerView.beginTrimming { [weak self] result in
            guard let self else { return }
            if result == .okButton {
                self.exportTrimmedRange()
            } else {
                self.onClose()
            }
        }
    }

    private func exportTrimmedRange() {
        guard let item = playerView.player?.currentItem else { return onClose() }
        stopPlayback()

        let duration = item.duration
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
        // Trim bar confirmed without moving the handles — nothing to save.
        if CMTimeCompare(start, .zero) <= 0, CMTimeCompare(end, duration) >= 0 {
            return onClose()
        }

        statusLabel.stringValue = "  Saving…  "
        statusLabel.isHidden = false

        let outputURL = Self.trimmedURL(for: url)
        let asset = item.asset
        let timeRange = CMTimeRange(start: start, end: end)
        Task { @MainActor in
            do {
                try await Self.export(asset: asset, timeRange: timeRange, to: outputURL)
                if settings.copyToClipboard {
                    ClipboardHelper.copyExportedFile(at: outputURL, isAnimated: true)
                }
                CaptureToast.shared.show(imageURL: outputURL)
                onClose()
            } catch {
                statusLabel.isHidden = true
                let alert = NSAlert()
                alert.messageText = "Couldn't save trimmed video"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
                onClose()
            }
        }
    }

    private static func export(asset: AVAsset, timeRange: CMTimeRange, to outputURL: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoRecorderError.writerFailed(nil)
        }
        session.timeRange = timeRange
        session.shouldOptimizeForNetworkUse = true

        if #available(macOS 15.0, *) {
            try await session.export(to: outputURL, as: .mp4)
        } else {
            session.outputURL = outputURL
            session.outputFileType = .mp4
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            if session.status != .completed {
                throw VideoRecorderError.writerFailed(session.error)
            }
        }
    }

    /// "SnapCast_…mp4" → "SnapCast_…_trimmed.mp4", adding a counter if taken.
    private static func trimmedURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + "_trimmed"
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter)").appendingPathExtension("mp4")
            counter += 1
        }
        return candidate
    }
}
