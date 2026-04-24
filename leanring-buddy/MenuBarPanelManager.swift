//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var statusMenu: NSMenu?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let clickyUpdaterManager: ClickyUpdaterManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager, clickyUpdaterManager: ClickyUpdaterManager) {
        self.companionManager = companionManager
        self.clickyUpdaterManager = clickyUpdaterManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideClickyMenuScreen()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showClickyMenuScreen()
        }
    }

    @objc private func statusItemClicked() {
        showNativeStatusMenu()
    }

    private func showNativeStatusMenu() {
        guard let button = statusItem?.button else { return }

        let menu = createNativeStatusMenu()
        statusMenu = menu
        button.highlight(true)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 2),
            in: button
        )
    }

    private func createNativeStatusMenu() -> NSMenu {
        clickyUpdaterManager.refreshUpdateAvailability()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let toggleMenuItem = NSMenuItem()
        let toggleView = ClickyAgentToggleMenuRow(companionManager: companionManager)
            .frame(width: 280, height: 54)
        toggleMenuItem.view = NSHostingView(rootView: toggleView)
        menu.addItem(toggleMenuItem)

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

        let settingsMenuItem = NSMenuItem(
            title: "Settings",
            action: #selector(settingsMenuItemSelected),
            keyEquivalent: ","
        )
        settingsMenuItem.target = self
        settingsMenuItem.isEnabled = true
        menu.addItem(settingsMenuItem)

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

    @objc private func settingsMenuItemSelected() {
        DispatchQueue.main.async {
            self.showClickyMenuScreen()
        }
    }

    @objc private func quitMenuItemSelected() {
        NSApp.terminate(nil)
    }

    // MARK: - Panel Lifecycle

    private func showClickyMenuScreen() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hideClickyMenuScreen() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hideClickyMenuScreen()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

extension MenuBarPanelManager: NSMenuDelegate {
    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor [weak self] in
            self?.statusItem?.button?.highlight(false)
            self?.statusMenu = nil
        }
    }
}

private struct ClickyAgentToggleMenuRow: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        Button(action: {
            companionManager.setAgentRunning(!companionManager.isAgentRunning)
        }) {
            HStack(spacing: 14) {
                Text("Clicky")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer(minLength: 12)

                Text("⌃⌥")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.55))

                AgentRunningSwitch(isOn: companionManager.isAgentRunning)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AgentRunningSwitch: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(isOn ? Color(red: 0.0, green: 0.48, blue: 1.0) : DS.Colors.surface3)
            .frame(width: 60, height: 34)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(Color.white)
                    .frame(width: 29, height: 29)
                    .padding(.horizontal, 3)
                    .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
            }
            .animation(.easeOut(duration: 0.18), value: isOn)
    }
}
