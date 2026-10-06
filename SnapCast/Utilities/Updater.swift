import AppKit
import Sparkle

/// Sparkle auto-updates. The feed URL and EdDSA public key live in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`); releases are published by
/// `scripts/release.sh`.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    func checkForUpdates() {
        // SnapCast is a menu-bar app; bring it forward so the update window
        // isn't hidden behind whatever app was focused.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
