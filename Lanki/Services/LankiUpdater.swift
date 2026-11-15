//
//  LankiUpdater.swift
//  Lanki
//
//  Wraps Sparkle for the in-app auto-update flow: the once-a-day background
//  check that pops the "Update available" sheet with Install Update / Remind
//  Me Later / Skip This Version, plus the user-initiated "Check for Updates…"
//  menu item and the "Restart to Update" state once an update has been
//  downloaded in the background.
//

import AppKit
import Combine
import Sparkle

/// Central, observable Sparkle wrapper for Lanki.
///
/// Lanki is a menu-bar app (`LSUIElement`), so it rarely quits. Sparkle's
/// default behaviour would download an update in the background and then open
/// its own update window on a later quit — possibly days after the download.
/// To keep that under the app's control, `willInstallUpdateOnQuit` takes the
/// install handler over and exposes a `readyUpdateVersion` that turns the
/// "Check for Updates…" items into "Restart to Update to Lanki X.Y".
final class LankiUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = LankiUpdater()

    private var controller: SPUStandardUpdaterController!

    /// Mirrors Sparkle's persisted `SUEnableAutomaticChecks` so SwiftUI can
    /// show a live toggle. Sparkle writes the real default on first run and
    /// keeps it in UserDefaults, which takes precedence over the Info.plist.
    @Published private(set) var automaticallyChecksForUpdates = false

    /// Sparkle's `SUAutomaticallyUpdate`: download updates in the background
    /// and install them when Lanki quits. Off unless the user turns it on.
    @Published private(set) var automaticallyDownloadsUpdates = false

    /// False while Sparkle cannot start a check (e.g. one is already running).
    /// Drives the enabled state of the Check for Updates items.
    @Published private(set) var canCheckForUpdates = false

    /// The display version of a downloaded update waiting to install on quit.
    /// While set, the Check for Updates items become Restart to Update.
    @Published private(set) var readyUpdateVersion: String?

    /// Sparkle's handler that quits Lanki, installs the waiting update and
    /// relaunches. It can run again if the quit is cancelled.
    private var installReadyUpdate: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    /// Quits through the normal path; Sparkle installs the waiting update and
    /// relaunches Lanki.
    func restartToUpdate() {
        installReadyUpdate?()
    }

    static func restartTitle(forVersion version: String) -> String {
        "Restart to Update to Lanki \(version)"
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle downloaded an update in the background and will install it when
    /// Lanki quits. Taking it over stops Sparkle from opening its update window
    /// on its own later; the Restart to Update items replace that.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle shows a critical update straight away; keep that.
        guard !item.isCriticalUpdate else { return false }
        installReadyUpdate = immediateInstallHandler
        readyUpdateVersion = item.displayVersionString
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle already ends the session when the update driver aborts.
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        // Session is fully complete; safe to start another user-initiated check.
        // A waiting update's handler belongs to the cycle that just ended, so it
        // can no longer install anything.
        installReadyUpdate = nil
        readyUpdateVersion = nil
    }
}
