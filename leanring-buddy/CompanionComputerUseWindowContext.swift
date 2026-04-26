//
//  CompanionComputerUseWindowContext.swift
//  leanring-buddy
//
//  Native window-level computer-use context for the dashboard and agent prompts.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import ScreenCaptureKit

struct CompanionComputerUseWindowBounds: Hashable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var dashboardSummary: String {
        "x \(Int(x)), y \(Int(y)), \(Int(width)) x \(Int(height))"
    }

    var promptContextFragment: String {
        "x:\(Int(x)) y:\(Int(y)) width:\(Int(width)) height:\(Int(height))"
    }
}

struct CompanionComputerUseWindowInfo: Identifiable, Hashable {
    let id: Int
    let processIdentifier: pid_t
    let ownerName: String
    let windowTitle: String
    let bounds: CompanionComputerUseWindowBounds
    let zIndex: Int
    let isOnScreen: Bool
    let layer: Int
    let bundleIdentifier: String?

    var displayTitle: String {
        let trimmedOwnerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedOwnerName.isEmpty && trimmedWindowTitle.isEmpty { return "Unknown window" }
        if trimmedWindowTitle.isEmpty { return trimmedOwnerName }
        if trimmedOwnerName.isEmpty { return trimmedWindowTitle }
        return "\(trimmedOwnerName) - \(trimmedWindowTitle)"
    }

    var compactDisplayTitle: String {
        let trimmedOwnerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOwnerName.isEmpty ? displayTitle : trimmedOwnerName
    }

    var promptContextDescription: String {
        let trimmedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedWindowTitle.isEmpty ? "untitled" : trimmedWindowTitle
        return "focused window: owner \(ownerName), title \(title), pid \(processIdentifier), window id \(id), bounds \(bounds.promptContextFragment), bundle id \(bundleIdentifier ?? "unknown")."
    }
}

struct CompanionComputerUsePermissionSnapshot: Hashable {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let screenContentGranted: Bool

    var isReadyForWindowContext: Bool {
        accessibilityGranted && screenRecordingGranted && screenContentGranted
    }
}

struct CompanionComputerUseAXTargetSummary: Identifiable, Hashable {
    let id: String
    let role: String
    let label: String
    let capabilities: [String]
    let frameSummary: String?

    var capabilitySummary: String {
        capabilities.isEmpty ? "none" : capabilities.joined(separator: ", ")
    }
}

struct CompanionComputerUseWindowContextStatus: Hashable {
    let permissions: CompanionComputerUsePermissionSnapshot
    let visibleWindowCount: Int
    let focusedWindow: CompanionComputerUseWindowInfo?
    let axTargetCount: Int
    let lastRefreshDate: Date?
    let lastErrorMessage: String?

    var summary: String {
        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            return lastErrorMessage
        }

        if let focusedWindow {
            return "\(focusedWindow.compactDisplayTitle) · \(axTargetCount) AX targets"
        }

        return "No focused app window"
    }
}

struct CompanionComputerUseWindowCapture {
    let imageData: Data
    let window: CompanionComputerUseWindowInfo
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let capturedAt: Date

    var label: String {
        "focused window (\(window.displayTitle), image dimensions: \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels)"
    }

    var promptContextDescription: String {
        "\(window.promptContextDescription) focused-window screenshot dimensions \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels."
    }
}

@MainActor
final class CompanionComputerUseWindowContextController: ObservableObject {
    @Published private(set) var visibleWindows: [CompanionComputerUseWindowInfo] = []
    @Published private(set) var focusedWindow: CompanionComputerUseWindowInfo?
    @Published private(set) var axTargetSummaries: [CompanionComputerUseAXTargetSummary] = []
    @Published private(set) var status: CompanionComputerUseWindowContextStatus
    @Published private(set) var lastWindowCapture: CompanionComputerUseWindowCapture?

    init() {
        let permissions = Self.currentPermissionSnapshot(screenContentGranted: false)
        self.status = CompanionComputerUseWindowContextStatus(
            permissions: permissions,
            visibleWindowCount: 0,
            focusedWindow: nil,
            axTargetCount: 0,
            lastRefreshDate: nil,
            lastErrorMessage: nil
        )
    }

    func refresh(screenContentGranted: Bool) {
        let permissions = Self.currentPermissionSnapshot(screenContentGranted: screenContentGranted)
        let windows = Self.visibleWindows()
        let resolvedFocusedWindow = Self.frontmostTargetWindow(from: windows)
        let resolvedAXTargetSummaries = Self.axTargetSummariesForCurrentVisibleWindow()

        visibleWindows = windows
        focusedWindow = resolvedFocusedWindow
        axTargetSummaries = resolvedAXTargetSummaries
        status = CompanionComputerUseWindowContextStatus(
            permissions: permissions,
            visibleWindowCount: windows.count,
            focusedWindow: resolvedFocusedWindow,
            axTargetCount: resolvedAXTargetSummaries.count,
            lastRefreshDate: Date(),
            lastErrorMessage: nil
        )

        ClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "event",
            event: "window_context.refreshed",
            fields: [
                "focusedWindow": resolvedFocusedWindow?.displayTitle ?? "none",
                "visibleWindowCount": "\(windows.count)",
                "axTargetCount": "\(resolvedAXTargetSummaries.count)",
                "accessibilityGranted": "\(permissions.accessibilityGranted)",
                "screenRecordingGranted": "\(permissions.screenRecordingGranted)",
                "screenContentGranted": "\(permissions.screenContentGranted)"
            ]
        )
    }

    func focusedWindowPromptContext() -> String {
        let window = Self.frontmostTargetWindow(from: Self.visibleWindows())
        return window?.promptContextDescription ?? "focused window: unknown."
    }

    func captureFocusedWindowAsJPEG(screenContentGranted: Bool) async throws -> CompanionComputerUseWindowCapture {
        refresh(screenContentGranted: screenContentGranted)

        guard let focusedWindow else {
            let message = "No focused app window is available for capture."
            status = CompanionComputerUseWindowContextStatus(
                permissions: status.permissions,
                visibleWindowCount: visibleWindows.count,
                focusedWindow: nil,
                axTargetCount: axTargetSummaries.count,
                lastRefreshDate: Date(),
                lastErrorMessage: message
            )
            throw NSError(domain: "CompanionComputerUseWindowContext", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        do {
            let capture = try await Self.capture(window: focusedWindow)
            lastWindowCapture = capture
            status = CompanionComputerUseWindowContextStatus(
                permissions: status.permissions,
                visibleWindowCount: visibleWindows.count,
                focusedWindow: focusedWindow,
                axTargetCount: axTargetSummaries.count,
                lastRefreshDate: Date(),
                lastErrorMessage: nil
            )
            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "event",
                event: "window_context.focused_window_captured",
                fields: [
                    "window": focusedWindow.displayTitle,
                    "windowID": "\(focusedWindow.id)",
                    "pid": "\(focusedWindow.processIdentifier)",
                    "pixelWidth": "\(capture.screenshotWidthInPixels)",
                    "pixelHeight": "\(capture.screenshotHeightInPixels)",
                    "byteCount": "\(capture.imageData.count)"
                ]
            )
            return capture
        } catch {
            status = CompanionComputerUseWindowContextStatus(
                permissions: status.permissions,
                visibleWindowCount: visibleWindows.count,
                focusedWindow: focusedWindow,
                axTargetCount: axTargetSummaries.count,
                lastRefreshDate: Date(),
                lastErrorMessage: error.localizedDescription
            )
            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "window_context.focused_window_capture_failed",
                fields: [
                    "window": focusedWindow.displayTitle,
                    "windowID": "\(focusedWindow.id)",
                    "error": error.localizedDescription
                ]
            )
            throw error
        }
    }

    private static func currentPermissionSnapshot(screenContentGranted: Bool) -> CompanionComputerUsePermissionSnapshot {
        CompanionComputerUsePermissionSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(),
            screenContentGranted: screenContentGranted
        )
    }

    private static func visibleWindows() -> [CompanionComputerUseWindowInfo] {
        enumerateWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
            .filter { windowInfo in
                windowInfo.isOnScreen
                    && windowInfo.layer == 0
                    && windowInfo.bounds.width > 80
                    && windowInfo.bounds.height > 60
            }
    }

    private static func frontmostTargetWindow(from windows: [CompanionComputerUseWindowInfo]) -> CompanionComputerUseWindowInfo? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = windows.filter { windowInfo in
            windowInfo.bundleIdentifier != ownBundleIdentifier
        }

        if let frontmostBundleIdentifier, frontmostBundleIdentifier != ownBundleIdentifier {
            let frontmostCandidates = candidates.filter { windowInfo in
                windowInfo.bundleIdentifier == frontmostBundleIdentifier
            }
            if let frontmostWindow = frontmostCandidates.max(by: { $0.zIndex < $1.zIndex }) {
                return frontmostWindow
            }
        }

        return candidates.max(by: { $0.zIndex < $1.zIndex })
    }

    private static func enumerateWindows(options: CGWindowListOption) -> [CompanionComputerUseWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let totalWindowCount = rawWindows.count
        return rawWindows.enumerated().compactMap { windowIndex, entry in
            parseWindowInfo(entry, zIndex: totalWindowCount - windowIndex)
        }
    }

    private static func parseWindowInfo(_ entry: [String: Any], zIndex: Int) -> CompanionComputerUseWindowInfo? {
        guard let windowID = entry[kCGWindowNumber as String] as? Int,
              let processIdentifierValue = entry[kCGWindowOwnerPID as String] as? Int,
              let processIdentifier = pid_t(exactly: processIdentifierValue),
              let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }

        let bounds = CompanionComputerUseWindowBounds(
            x: numberValue(boundsDictionary["X"]),
            y: numberValue(boundsDictionary["Y"]),
            width: numberValue(boundsDictionary["Width"]),
            height: numberValue(boundsDictionary["Height"])
        )
        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)

        return CompanionComputerUseWindowInfo(
            id: windowID,
            processIdentifier: processIdentifier,
            ownerName: entry[kCGWindowOwnerName as String] as? String ?? runningApplication?.localizedName ?? "",
            windowTitle: entry[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            zIndex: zIndex,
            isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
            layer: entry[kCGWindowLayer as String] as? Int ?? 0,
            bundleIdentifier: runningApplication?.bundleIdentifier
        )
    }

    private static func numberValue(_ value: Any?) -> CGFloat {
        if let doubleValue = value as? Double { return CGFloat(doubleValue) }
        if let intValue = value as? Int { return CGFloat(intValue) }
        if let numberValue = value as? NSNumber { return CGFloat(truncating: numberValue) }
        return 0
    }

    private static func axTargetSummariesForCurrentVisibleWindow() -> [CompanionComputerUseAXTargetSummary] {
        guard let snapshot = CompanionBackgroundComputerUseController.snapshotForCurrentVisibleWindow(limit: 40) else {
            return []
        }

        return snapshot.targets.map { target in
            var capabilities: [String] = []
            if target.canPress { capabilities.append("press") }
            if target.canFocus { capabilities.append("focus") }
            if target.canSetValue { capabilities.append("set text") }
            if target.canScroll { capabilities.append("scroll") }
            if target.canIncrement { capabilities.append("increment") }
            if target.canDecrement { capabilities.append("decrement") }

            let labelParts = [target.title, target.description]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let label = labelParts.isEmpty ? "unlabeled" : labelParts.joined(separator: " / ")
            let frameSummary = target.frame.map { frame in
                "x \(Int(frame.minX)), y \(Int(frame.minY)), \(Int(frame.width)) x \(Int(frame.height))"
            }

            return CompanionComputerUseAXTargetSummary(
                id: target.ref,
                role: target.role,
                label: label,
                capabilities: capabilities,
                frameSummary: frameSummary
            )
        }
    }

    private static func capture(window targetWindow: CompanionComputerUseWindowInfo) async throws -> CompanionComputerUseWindowCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let screenCaptureWindow = content.windows.first(where: { Int($0.windowID) == targetWindow.id }) else {
            throw NSError(domain: "CompanionComputerUseWindowContext", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Focused window is no longer available to ScreenCaptureKit."
            ])
        }

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let windowWidth = max(1, Int(screenCaptureWindow.frame.width))
        let windowHeight = max(1, Int(screenCaptureWindow.frame.height))
        let aspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)

        if windowWidth >= windowHeight {
            configuration.width = maxDimension
            configuration.height = max(1, Int(CGFloat(maxDimension) / aspectRatio))
        } else {
            configuration.height = maxDimension
            configuration.width = max(1, Int(CGFloat(maxDimension) * aspectRatio))
        }

        let filter = SCContentFilter(desktopIndependentWindow: screenCaptureWindow)
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let imageData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw NSError(domain: "CompanionComputerUseWindowContext", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Focused window image could not be encoded."
            ])
        }

        return CompanionComputerUseWindowCapture(
            imageData: imageData,
            window: targetWindow,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height,
            capturedAt: Date()
        )
    }
}
