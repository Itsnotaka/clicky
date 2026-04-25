//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar companion app with a native dashboard control center. No dock icon;
//  the always-available status item opens a compact native menu.
//

import Sparkle
import Combine
import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app is managed by the AppDelegate through the menu bar and dashboard.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private let clickyUpdaterManager = ClickyUpdaterManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        print("Clicky starting")
        print("   Version: \(version)")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(
            companionManager: companionManager,
            clickyUpdaterManager: clickyUpdaterManager
        )
        companionManager.start()
        // Auto-open the dashboard if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showDashboardOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        clickyUpdaterManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("Clicky: Registered as login item")
            } catch {
                print("Warning: Clicky: Failed to register as login item: \(error)")
            }
        }
    }

}

@MainActor
final class ClickyUpdaterManager: NSObject, ObservableObject {
    @Published private(set) var updateStatusText = "Updates: Starting..."
    @Published private(set) var canCheckForUpdates = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    func start() {
        guard updateFeedURLString != nil else {
            updateStatusText = "Updates: Feed not configured"
            canCheckForUpdates = false
            return
        }

        do {
            try updaterController.updater.start()
            refreshUpdateAvailability()
            updateStatusText = "Updates: Ready"
        } catch {
            print("Warning: Clicky: Sparkle updater failed to start: \(error)")
            updateStatusText = "Updates: Unavailable"
        }
    }

    func refreshUpdateAvailability() {
        guard updateFeedURLString != nil else {
            canCheckForUpdates = false
            return
        }

        canCheckForUpdates = updaterController.updater.canCheckForUpdates
    }

    @objc func checkForUpdates(_ sender: Any?) {
        refreshUpdateAvailability()

        guard canCheckForUpdates else { return }

        updateStatusText = "Updates: Checking..."
        updaterController.checkForUpdates(sender)
    }

    private var updateFeedURLString: String? {
        AppBundleConfiguration.stringValue(forKey: "ClickyUpdateFeedURL")
    }
}

extension ClickyUpdaterManager: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        updateFeedURLString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateStatusText = "Updates: Update available"
        refreshUpdateAvailability()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateStatusText = "Updates: Up to date"
        refreshUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        updateStatusText = "Updates: Downloading..."
        refreshUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        updateStatusText = "Updates: Downloaded"
        refreshUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        updateStatusText = "Updates: Download failed"
        refreshUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        updateStatusText = "Updates: Installing..."
        refreshUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        updateStatusText = "Updates: Ready to install"
        refreshUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateStatusText = "Updates: Check failed"
        refreshUpdateAvailability()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if error == nil, updateStatusText == "Updates: Checking..." {
            updateStatusText = "Updates: Ready"
        }

        refreshUpdateAvailability()
    }
}
