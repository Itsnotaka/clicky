//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and its compact native NSMenu.
//  The dashboard is the primary native control center for setup, permissions,
//  model settings, cursor preferences, computer-use context, and logs.
//

import AppKit

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    private let companionManager: CompanionManager
    private let clickyUpdaterManager: ClickyUpdaterManager
    private let dashboardWindowManager = ClickyDashboardWindowManager()

    init(companionManager: CompanionManager, clickyUpdaterManager: ClickyUpdaterManager) {
        self.companionManager = companionManager
        self.clickyUpdaterManager = clickyUpdaterManager
        super.init()
        createStatusItem()
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the clicky cursor SVG path as a template menu bar icon.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let path = NSBezierPath()
        let drawingRect = NSRect(x: 1.5, y: 1.5, width: iconSize - 3.0, height: iconSize - 3.0)
        let scaleX = drawingRect.width / 24.0
        let scaleY = drawingRect.height / 24.0

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: drawingRect.minX + x * scaleX,
                y: drawingRect.maxY - y * scaleY
            )
        }

        path.move(to: point(4.97896, 2.74473))
        path.curve(
            to: point(2.74473, 4.97896),
            controlPoint1: point(3.59074, 2.25247),
            controlPoint2: point(2.25247, 3.59074)
        )
        path.line(to: point(8.35702, 20.8063))
        path.curve(
            to: point(11.6215, 20.8952),
            controlPoint1: point(8.89212, 22.3153),
            controlPoint2: point(11.005, 22.3729)
        )
        path.line(to: point(14.3118, 14.4463))
        path.curve(
            to: point(14.4463, 14.3118),
            controlPoint1: point(14.3371, 14.3855),
            controlPoint2: point(14.3855, 14.3371)
        )
        path.line(to: point(20.8952, 11.6215))
        path.curve(
            to: point(20.8063, 8.35702),
            controlPoint1: point(22.3729, 11.005),
            controlPoint2: point(22.3153, 8.89213)
        )
        path.line(to: point(4.97896, 2.74473))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    func showDashboardOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showDashboard()
        }
    }

    @objc private func statusItemClicked() {
        showNativeStatusMenu()
    }

    private func showNativeStatusMenu() {
        guard let button = statusItem?.button else { return }

        let menu = createNativeStatusMenu()
        statusMenu = menu
        statusItem?.menu = menu
        button.performClick(nil)
    }

    private func createNativeStatusMenu() -> NSMenu {
        clickyUpdaterManager.refreshUpdateAvailability()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let toggleMenuItem = NSMenuItem(
            title: "Clicky",
            action: #selector(toggleAgentMenuItemSelected),
            keyEquivalent: ""
        )
        toggleMenuItem.target = self
        toggleMenuItem.state = companionManager.isAgentRunning ? .on : .off
        toggleMenuItem.isEnabled = true
        menu.addItem(toggleMenuItem)

        menu.addItem(.separator())

        let dashboardMenuItem = NSMenuItem(
            title: "Dashboard",
            action: #selector(dashboardMenuItemSelected),
            keyEquivalent: ""
        )
        dashboardMenuItem.target = self
        dashboardMenuItem.isEnabled = true
        menu.addItem(dashboardMenuItem)

        menu.addItem(.separator())

        let updateStatusMenuItem = NSMenuItem(
            title: clickyUpdaterManager.updateStatusText,
            action: nil,
            keyEquivalent: ""
        )
        updateStatusMenuItem.isEnabled = false
        menu.addItem(updateStatusMenuItem)

        let checkForUpdatesMenuItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(ClickyUpdaterManager.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesMenuItem.target = clickyUpdaterManager
        checkForUpdatesMenuItem.isEnabled = clickyUpdaterManager.canCheckForUpdates
        menu.addItem(checkForUpdatesMenuItem)

        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit Clicky",
            action: #selector(quitMenuItemSelected),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        quitMenuItem.isEnabled = true
        menu.addItem(quitMenuItem)

        return menu
    }

    @objc private func dashboardMenuItemSelected() {
        showDashboard()
    }

    @objc private func toggleAgentMenuItemSelected() {
        companionManager.setAgentRunning(!companionManager.isAgentRunning)
    }

    @objc private func quitMenuItemSelected() {
        NSApp.terminate(nil)
    }

    private func showDashboard() {
        dashboardWindowManager.show(
            companionManager: companionManager,
            clickyUpdaterManager: clickyUpdaterManager
        )
    }
}

extension MenuBarPanelManager: NSMenuDelegate {
    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor [weak self] in
            self?.statusItem?.menu = nil
            self?.statusMenu = nil
        }
    }
}
