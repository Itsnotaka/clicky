//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem and its compact native NSMenu.
//

import AppKit
import AVFoundation

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var dismissMenuObserver: NSObjectProtocol?

    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissMenuObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.statusMenu?.cancelTracking()
        }
    }

    deinit {
        if let dismissMenuObserver {
            NotificationCenter.default.removeObserver(dismissMenuObserver)
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let centerX = iconSize * 0.50
        let centerY = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: centerX, y: centerY + height / 1.5)
        let bottomLeft = CGPoint(x: centerX - triangleSize / 2, y: centerY - height / 3)
        let bottomRight = CGPoint(x: centerX + triangleSize / 2, y: centerY - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let deltaX = point.x - centerX
            let deltaY = point.y - centerY
            let cosAngle = CGFloat(cos(angle))
            let sinAngle = CGFloat(sin(angle))
            return CGPoint(
                x: centerX + cosAngle * deltaX - sinAngle * deltaY,
                y: centerY + sinAngle * deltaX + cosAngle * deltaY
            )
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    func showMenuOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showNativeStatusMenu()
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
        companionManager.refreshAllPermissions()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        addHeaderItems(to: menu)
        menu.addItem(.separator())
        addCodexItems(to: menu)
        menu.addItem(.separator())
        addPermissionItems(to: menu)
        menu.addItem(.separator())
        addLifecycleItems(to: menu)

        return menu
    }

    private func addHeaderItems(to menu: NSMenu) {
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let shortcutItem = NSMenuItem(
            title: "Hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to talk",
            action: nil,
            keyEquivalent: ""
        )
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        let showClickyItem = NSMenuItem(
            title: "Show Clicky",
            action: #selector(showClickyMenuItemSelected),
            keyEquivalent: ""
        )
        showClickyItem.target = self
        showClickyItem.state = companionManager.isClickyCursorEnabled ? .on : .off
        showClickyItem.isEnabled = true
        menu.addItem(showClickyItem)
    }

    private var statusTitle: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Clicky: Setup"
        }

        if !companionManager.isOverlayVisible {
            return "Clicky: Ready"
        }

        switch companionManager.voiceState {
        case .idle:
            return "Clicky: Ready"
        case .listening:
            return "Clicky: Listening"
        case .processing:
            return "Clicky: Thinking"
        case .responding:
            return "Clicky: Responding"
        }
    }

    private func addCodexItems(to menu: NSMenu) {
        switch companionManager.codexConnectionState {
        case .checking:
            let item = NSMenuItem(title: "Codex: Checking", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .needsSignIn:
            let item = NSMenuItem(title: "Sign In to Codex", action: #selector(signInToCodexMenuItemSelected), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        case .ready:
            let item = NSMenuItem(title: "Codex: Ready", action: #selector(refreshCodexMenuItemSelected), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        case .unavailable(let message):
            let item = NSMenuItem(title: "Codex: \(message)", action: #selector(refreshCodexMenuItemSelected), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }

        let modelItem = NSMenuItem(title: "Model: \(companionManager.selectedModelDisplayName)", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        if companionManager.availableModels.isEmpty {
            let emptyItem = NSMenuItem(title: "Refresh Codex to load models", action: #selector(refreshCodexMenuItemSelected), keyEquivalent: "")
            emptyItem.target = self
            emptyItem.isEnabled = true
            modelMenu.addItem(emptyItem)
        } else {
            for modelOption in companionManager.availableModels {
                let item = NSMenuItem(title: modelOption.displayName, action: #selector(modelMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = modelOption.id
                item.state = modelOption.id == companionManager.selectedModel ? .on : .off
                item.isEnabled = true
                modelMenu.addItem(item)
            }
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        if !companionManager.selectedModelReasoningEfforts.isEmpty {
            let effortItem = NSMenuItem(title: "Thinking", action: nil, keyEquivalent: "")
            let effortMenu = NSMenu()
            for reasoningEffortOption in companionManager.selectedModelReasoningEfforts {
                let item = NSMenuItem(title: reasoningEffortOption.displayName, action: #selector(reasoningEffortMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = reasoningEffortOption.id
                item.state = reasoningEffortOption.id == companionManager.selectedReasoningEffort ? .on : .off
                item.isEnabled = true
                effortMenu.addItem(item)
            }
            effortItem.submenu = effortMenu
            menu.addItem(effortItem)
        }

        if companionManager.hasFastModeCompatibleModel {
            let fastModeItem = NSMenuItem(title: fastModeMenuTitle, action: #selector(fastModeMenuItemSelected), keyEquivalent: "")
            fastModeItem.target = self
            fastModeItem.state = companionManager.isFastModeEnabled ? .on : .off
            fastModeItem.isEnabled = companionManager.selectedModelSupportsFastMode
            menu.addItem(fastModeItem)
        }
    }

    private var fastModeMenuTitle: String {
        companionManager.selectedModelSupportsFastMode ? "Fast Mode" : "Fast Mode: Not Available"
    }

    private func addPermissionItems(to menu: NSMenu) {
        let permissionsHeaderItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissionsHeaderItem.isEnabled = false
        menu.addItem(permissionsHeaderItem)

        addPermissionItem(
            title: "Microphone",
            isGranted: companionManager.hasMicrophonePermission,
            action: #selector(grantMicrophoneMenuItemSelected),
            to: menu
        )
        addPermissionItem(
            title: "Accessibility",
            isGranted: companionManager.hasAccessibilityPermission,
            action: #selector(grantAccessibilityMenuItemSelected),
            to: menu
        )
        addPermissionItem(
            title: "Screen Recording",
            isGranted: companionManager.hasScreenRecordingPermission,
            action: #selector(grantScreenRecordingMenuItemSelected),
            to: menu
        )
        if companionManager.hasScreenRecordingPermission {
            addPermissionItem(
                title: "Screen Content",
                isGranted: companionManager.hasScreenContentPermission,
                action: #selector(grantScreenContentMenuItemSelected),
                to: menu
            )
        }

        let refreshItem = NSMenuItem(title: "Refresh Permissions", action: #selector(refreshPermissionsMenuItemSelected), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = true
        menu.addItem(refreshItem)
    }

    private func addPermissionItem(title: String, isGranted: Bool, action: Selector, to menu: NSMenu) {
        let itemTitle = isGranted ? "\(title): Granted" : "Grant \(title)"
        let item = NSMenuItem(title: itemTitle, action: isGranted ? nil : action, keyEquivalent: "")
        item.target = isGranted ? nil : self
        item.state = isGranted ? .on : .off
        item.isEnabled = !isGranted
        menu.addItem(item)
    }

    private func addLifecycleItems(to menu: NSMenu) {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            let startItem = NSMenuItem(title: "Start Clicky", action: #selector(startClickyMenuItemSelected), keyEquivalent: "")
            startItem.target = self
            startItem.isEnabled = true
            menu.addItem(startItem)
        }

        if companionManager.hasCompletedOnboarding {
            let replayItem = NSMenuItem(title: "Watch Onboarding Again", action: #selector(replayOnboardingMenuItemSelected), keyEquivalent: "")
            replayItem.target = self
            replayItem.isEnabled = true
            menu.addItem(replayItem)
        }

        let quitItem = NSMenuItem(title: "Quit Clicky", action: #selector(quitMenuItemSelected), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }

    @objc private func showClickyMenuItemSelected() {
        companionManager.setClickyCursorEnabled(!companionManager.isClickyCursorEnabled)
    }

    @objc private func signInToCodexMenuItemSelected() {
        companionManager.beginCodexSignIn()
    }

    @objc private func refreshCodexMenuItemSelected() {
        companionManager.refreshCodexConnectionState()
    }

    @objc private func modelMenuItemSelected(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }
        companionManager.setSelectedModel(modelID)
    }

    @objc private func reasoningEffortMenuItemSelected(_ sender: NSMenuItem) {
        guard let reasoningEffort = sender.representedObject as? String else { return }
        companionManager.setSelectedReasoningEffort(reasoningEffort)
    }

    @objc private func fastModeMenuItemSelected() {
        companionManager.setFastModeEnabled(!companionManager.isFastModeEnabled)
    }

    @objc private func grantMicrophoneMenuItemSelected() {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authorizationStatus == .notDetermined {
            let companionManager = companionManager
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in
                    companionManager.refreshAllPermissions()
                }
            }
            return
        }

        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    @objc private func grantAccessibilityMenuItemSelected() {
        WindowPositionManager.requestAccessibilityPermission()
    }

    @objc private func grantScreenRecordingMenuItemSelected() {
        WindowPositionManager.requestScreenRecordingPermission()
    }

    @objc private func grantScreenContentMenuItemSelected() {
        companionManager.requestScreenContentPermission()
    }

    @objc private func refreshPermissionsMenuItemSelected() {
        companionManager.refreshAllPermissions()
    }

    @objc private func startClickyMenuItemSelected() {
        companionManager.triggerOnboarding()
    }

    @objc private func replayOnboardingMenuItemSelected() {
        companionManager.replayOnboarding()
    }

    @objc private func quitMenuItemSelected() {
        NSApp.terminate(nil)
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
