//
//  ClickyDashboardComputerUseSection.swift
//  leanring-buddy
//
//  Native computer-use inspection section for the Clicky dashboard.
//

import AppKit
import SwiftUI

struct ClickyDashboardComputerUseSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var computerUseWindowContextController: CompanionComputerUseWindowContextController
    let focusedWindowPreviewImage: NSImage?
    let focusedWindowCaptureErrorMessage: String?
    let refreshComputerUseContext: () -> Void
    let captureFocusedWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClickyDashboardCard {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DS.Colors.accentSubtle))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Native AX + window context")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(DS.Colors.textPrimary)

                        Text(computerUseWindowContextController.status.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                    }

                    Spacer()

                    Button(action: refreshComputerUseContext) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()

                    Button(action: captureFocusedWindow) {
                        Label("Capture Window", systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .pointerCursor()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ClickyDashboardPermissionMetricCard(title: "Accessibility", isGranted: computerUseWindowContextController.status.permissions.accessibilityGranted)
                ClickyDashboardPermissionMetricCard(title: "Screen Recording", isGranted: computerUseWindowContextController.status.permissions.screenRecordingGranted)
                ClickyDashboardPermissionMetricCard(title: "Screen Content", isGranted: computerUseWindowContextController.status.permissions.screenContentGranted)
                ClickyDashboardMetricCard(title: "Visible windows", value: "\(computerUseWindowContextController.status.visibleWindowCount)", systemImageName: "macwindow")
                ClickyDashboardMetricCard(title: "AX targets", value: "\(computerUseWindowContextController.status.axTargetCount)", systemImageName: "scope")
            }

            if !computerUseWindowContextController.status.permissions.isReadyForWindowContext {
                ClickyDashboardCard(title: "Permission actions") {
                    HStack(spacing: 10) {
                        Button(action: requestAccessibilityPermission) {
                            Label("Accessibility", systemImage: "hand.raised")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button(action: requestScreenRecordingPermission) {
                            Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button(action: companionManager.requestScreenContentPermission) {
                            Label("Screen Content", systemImage: "eye")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button(action: refreshPermissionState) {
                            Label("Refresh Permissions", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()
                    }
                }
            }

            ClickyDashboardCard(title: "Focused window", subtitle: "This is the window-level context Clicky can now inspect separately from full-screen capture.") {
                if let focusedWindow = computerUseWindowContextController.focusedWindow {
                    VStack(alignment: .leading, spacing: 10) {
                        ClickyDashboardInfoRow(title: "Window", value: focusedWindow.displayTitle, systemImageName: "macwindow")
                        Divider()
                        ClickyDashboardInfoRow(title: "Bundle", value: focusedWindow.bundleIdentifier ?? "unknown", systemImageName: "shippingbox")
                        Divider()
                        ClickyDashboardInfoRow(title: "PID / Window ID", value: "\(focusedWindow.processIdentifier) / \(focusedWindow.id)", systemImageName: "number")
                        Divider()
                        ClickyDashboardInfoRow(title: "Bounds", value: focusedWindow.bounds.dashboardSummary, systemImageName: "ruler")
                    }
                } else {
                    ClickyDashboardEmptyState(text: "No focused app window is available yet. Refresh while another app window is frontmost.")
                }
            }

            ClickyDashboardFocusedWindowPreviewCard(
                focusedWindowPreviewImage: focusedWindowPreviewImage,
                lastWindowCapture: computerUseWindowContextController.lastWindowCapture,
                focusedWindowCaptureErrorMessage: focusedWindowCaptureErrorMessage
            )

            ClickyDashboardAXTargetsCard(axTargetSummaries: computerUseWindowContextController.axTargetSummaries)
            ClickyDashboardVisibleWindowsCard(visibleWindows: computerUseWindowContextController.visibleWindows)
        }
    }

    private func requestAccessibilityPermission() {
        _ = WindowPositionManager.requestAccessibilityPermission()
    }

    private func requestScreenRecordingPermission() {
        _ = WindowPositionManager.requestScreenRecordingPermission()
    }

    private func refreshPermissionState() {
        companionManager.refreshAllPermissions()
        refreshComputerUseContext()
    }
}

struct ClickyDashboardFocusedWindowPreviewCard: View {
    let focusedWindowPreviewImage: NSImage?
    let lastWindowCapture: CompanionComputerUseWindowCapture?
    let focusedWindowCaptureErrorMessage: String?

    var body: some View {
        ClickyDashboardCard(title: "Focused-window capture", subtitle: "A dedicated ScreenCaptureKit capture for debugging and future agent context.") {
            if let focusedWindowCaptureErrorMessage {
                Text(focusedWindowCaptureErrorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let focusedWindowPreviewImage, let lastWindowCapture {
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: focusedWindowPreviewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Text("\(lastWindowCapture.window.displayTitle) · \(lastWindowCapture.screenshotWidthInPixels)x\(lastWindowCapture.screenshotHeightInPixels) · \(lastWindowCapture.imageData.count) bytes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            } else {
                ClickyDashboardEmptyState(text: "Capture a focused window to preview the native computer-use context.")
            }
        }
    }
}

struct ClickyDashboardAXTargetsCard: View {
    let axTargetSummaries: [CompanionComputerUseAXTargetSummary]

    var body: some View {
        ClickyDashboardCard(title: "Accessibility targets", subtitle: "The same refs power Clicky's safe background action planner.") {
            if axTargetSummaries.isEmpty {
                ClickyDashboardEmptyState(text: "No actionable AX targets found for the current focused window.")
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(axTargetSummaries.prefix(18)) { targetSummary in
                        HStack(alignment: .top, spacing: 10) {
                            Text("@\(targetSummary.id)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(DS.Colors.accentText)
                                .frame(width: 42, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(targetSummary.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .lineLimit(2)

                                Text("\(targetSummary.role) · \(targetSummary.capabilitySummary)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(2)

                                if let frameSummary = targetSummary.frameSummary {
                                    Text(frameSummary)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.045))
                        )
                    }
                }
            }
        }
    }
}

struct ClickyDashboardVisibleWindowsCard: View {
    let visibleWindows: [CompanionComputerUseWindowInfo]

    var body: some View {
        ClickyDashboardCard(title: "Visible app windows", subtitle: "Front-to-back native window discovery from CoreGraphics.") {
            if visibleWindows.isEmpty {
                ClickyDashboardEmptyState(text: "No visible app windows were found.")
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(visibleWindows.prefix(12)) { windowInfo in
                        HStack(spacing: 10) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(windowInfo.displayTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .lineLimit(1)

                                Text("pid \(windowInfo.processIdentifier) · window \(windowInfo.id) · \(windowInfo.bounds.dashboardSummary)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}
