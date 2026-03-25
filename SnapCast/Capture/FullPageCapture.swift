import AppKit
import WebKit

/// Captures the entire rendered content of a webpage by loading it in a
/// hidden WKWebView sized to the full document height, then snapshotting.
class FullPageCapture {

    @MainActor
    static func capture(url urlString: String, settings: CaptureSettings) async throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScreenshotError.scrollingFailed("No URL provided")
        }

        // Normalise: add https:// if no scheme
        let normalised: String
        if !trimmed.contains("://") {
            normalised = "https://\(trimmed)"
        } else {
            normalised = trimmed
        }

        guard let url = URL(string: normalised) else {
            throw ScreenshotError.scrollingFailed("Invalid URL")
        }

        let viewportWidth = CGFloat(settings.fullPageWidth)
        let waitTime = settings.fullPageWaitTime

        // 1. Create a hidden WKWebView
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 800), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // Put it in a hidden window so rendering works
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: viewportWidth, height: 800),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()

        defer {
            window.orderOut(nil)
        }

        // 2. Load the page and wait for it to finish
        try await loadPage(webView: webView, url: url)

        // 3. Wait extra time for JS/images/lazy-load to settle
        try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

        // 4. Trigger lazy-loaded content by scrolling to bottom and back via JS
        try await triggerLazyContent(webView: webView)

        // 5. Wait a bit more for lazy content to load
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 6. Get the full document dimensions
        let (docWidth, docHeight) = try await getDocumentSize(webView: webView)

        guard docHeight > 0, docWidth > 0 else {
            throw ScreenshotError.scrollingFailed("Could not determine page dimensions")
        }

        // 7. Resize the webview to the full document size
        let captureWidth = max(viewportWidth, CGFloat(docWidth))
        let captureHeight = CGFloat(docHeight)

        webView.frame = NSRect(x: 0, y: 0, width: captureWidth, height: captureHeight)
        window.setContentSize(NSSize(width: captureWidth, height: captureHeight))

        // Let it re-layout at the new size
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // 8. Snapshot the full webview
        let image = try await snapshotWebView(webView: webView, width: captureWidth, height: captureHeight)

        let finalImage = ScreenshotCapture.applyResize(image: image, settings: settings)
        return try ScreenshotCapture.saveImage(finalImage, settings: settings)
    }

    // MARK: - Page Loading

    @MainActor
    private static func loadPage(webView: WKWebView, url: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = NavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            // Store delegate to prevent dealloc
            objc_setAssociatedObject(webView, "navDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    // MARK: - JS Helpers

    @MainActor
    private static func triggerLazyContent(webView: WKWebView) async throws {
        // Scroll to bottom slowly to trigger lazy loaders, then back to top
        let js = """
        (async () => {
            const delay = ms => new Promise(r => setTimeout(r, ms));
            const step = Math.max(window.innerHeight, 500);
            const maxY = document.body.scrollHeight;
            for (let y = 0; y < maxY; y += step) {
                window.scrollTo(0, y);
                await delay(100);
            }
            window.scrollTo(0, maxY);
            await delay(300);
            window.scrollTo(0, 0);
        })();
        """
        _ = try? await webView.evaluateJavaScript(js)
    }

    @MainActor
    private static func getDocumentSize(webView: WKWebView) async throws -> (Int, Int) {
        let js = """
        JSON.stringify({
            width: Math.max(
                document.body.scrollWidth,
                document.documentElement.scrollWidth,
                document.body.offsetWidth,
                document.documentElement.offsetWidth,
                document.body.clientWidth,
                document.documentElement.clientWidth
            ),
            height: Math.max(
                document.body.scrollHeight,
                document.documentElement.scrollHeight,
                document.body.offsetHeight,
                document.documentElement.offsetHeight,
                document.body.clientHeight,
                document.documentElement.clientHeight
            )
        })
        """

        guard let result = try await webView.evaluateJavaScript(js) as? String,
              let data = result.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = json["width"] as? Int,
              let height = json["height"] as? Int
        else {
            throw ScreenshotError.scrollingFailed("Could not read document size")
        }

        return (width, height)
    }

    // MARK: - Snapshot

    @MainActor
    private static func snapshotWebView(webView: WKWebView, width: CGFloat, height: CGFloat) async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)

        let nsImage = try await webView.takeSnapshot(configuration: config)

        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenshotError.scrollingFailed("Failed to convert snapshot to image")
        }

        return cgImage
    }
}

// MARK: - Navigation Delegate

private class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var hasResumed = false
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        super.init()

        // Timeout after 30 seconds
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await MainActor.run {
                self?.finish(error: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded — give a tiny grace period for redirects
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.finish(error: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error: error)
    }

    private func finish(error: Error?) {
        guard !hasResumed else { return }
        hasResumed = true
        timeoutTask?.cancel()
        if let error = error {
            continuation?.resume(throwing: ScreenshotError.scrollingFailed(error.localizedDescription))
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
