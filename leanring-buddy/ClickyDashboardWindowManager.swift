//
//  ClickyDashboardWindowManager.swift
//  leanring-buddy
//
//  AppKit shell for the native SwiftUI Clicky dashboard.
//

import AppKit
import SwiftUI

private final class ClickyDashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ClickyDashboardWindowManager {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ClickyDashboardView>?

    func show(companionManager: CompanionManager, clickyUpdaterManager: ClickyUpdaterManager) {
        if panel == nil {
            panel = makePanel(companionManager: companionManager, clickyUpdaterManager: clickyUpdaterManager)
        } else {
            hostingView?.rootView = ClickyDashboardView(
                companionManager: companionManager,
                clickyUpdaterManager: clickyUpdaterManager
            )
        }

        positionPanelIfNeeded()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        ClickyMessageLogStore.shared.append(
            lane: "dashboard",
            direction: "event",
            event: "dashboard.opened"
        )
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroy() {
        panel?.close()
        panel = nil
        hostingView = nil
    }

    private func makePanel(companionManager: CompanionManager, clickyUpdaterManager: ClickyUpdaterManager) -> NSPanel {
        let rootView = ClickyDashboardView(
            companionManager: companionManager,
            clickyUpdaterManager: clickyUpdaterManager
        )
        let newHostingView = NSHostingView(rootView: rootView)
        hostingView = newHostingView

        let dashboardPanel = ClickyDashboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        dashboardPanel.title = "Clicky Dashboard"
        dashboardPanel.titleVisibility = .hidden
        dashboardPanel.titlebarAppearsTransparent = true
        dashboardPanel.isMovableByWindowBackground = true
        dashboardPanel.level = .floating
        dashboardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dashboardPanel.backgroundColor = .clear
        dashboardPanel.isOpaque = false
        dashboardPanel.hasShadow = true
        dashboardPanel.minSize = NSSize(width: 780, height: 540)
        dashboardPanel.contentMinSize = NSSize(width: 780, height: 540)
        dashboardPanel.contentView = newHostingView
        return dashboardPanel
    }

    private func positionPanelIfNeeded() {
        guard let panel else { return }
        guard panel.frame.origin == .zero else { return }
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let panelSize = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        ))
    }
}
