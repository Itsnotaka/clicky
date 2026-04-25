//
//  CompanionBrowserAutomationPermission.swift
//  leanring-buddy
//
//  Browser Automation permission helpers for background browser actions.
//

import AppKit
import CoreServices
import Foundation

struct CompanionBrowserAutomationTarget: Equatable, Sendable {
    enum BrowserFamily: Sendable {
        case chromium
        case safari
    }

    let bundleIdentifier: String
    let displayName: String
    let family: BrowserFamily

    static let supportedBrowsers: [CompanionBrowserAutomationTarget] = [
        CompanionBrowserAutomationTarget(bundleIdentifier: "com.google.Chrome", displayName: "Chrome", family: .chromium),
        CompanionBrowserAutomationTarget(bundleIdentifier: "com.brave.Browser", displayName: "Brave", family: .chromium),
        CompanionBrowserAutomationTarget(bundleIdentifier: "com.microsoft.edgemac", displayName: "Edge", family: .chromium),
        CompanionBrowserAutomationTarget(bundleIdentifier: "company.thebrowser.Browser", displayName: "Arc", family: .chromium),
        CompanionBrowserAutomationTarget(bundleIdentifier: "org.chromium.Chromium", displayName: "Chromium", family: .chromium),
        CompanionBrowserAutomationTarget(bundleIdentifier: "com.vivaldi.Vivaldi", displayName: "Vivaldi", family: .chromium),
        CompanionBrowserAutomationTarget(bundleIdentifier: "com.apple.Safari", displayName: "Safari", family: .safari)
    ]
}

enum CompanionBrowserAutomationPermissionStatus: Equatable {
    case checking
    case granted(browserName: String)
    case needsPermission(browserName: String)
    case denied(browserName: String)
    case noSupportedBrowserRunning
    case unavailable(browserName: String, statusCode: OSStatus)

    var isGranted: Bool {
        switch self {
        case .granted:
            return true
        case .checking, .needsPermission, .denied, .noSupportedBrowserRunning, .unavailable:
            return false
        }
    }

    var browserName: String? {
        switch self {
        case .checking, .noSupportedBrowserRunning:
            return nil
        case .granted(let browserName),
             .needsPermission(let browserName),
             .denied(let browserName),
             .unavailable(let browserName, _):
            return browserName
        }
    }

    var statusText: String {
        switch self {
        case .checking:
            return "Checking"
        case .granted(let browserName):
            return "\(browserName) granted"
        case .needsPermission(let browserName):
            return "\(browserName) needs access"
        case .denied(let browserName):
            return "\(browserName) blocked"
        case .noSupportedBrowserRunning:
            return "No supported browser running"
        case .unavailable(let browserName, _):
            return "\(browserName) needs setup"
        }
    }

    var detailText: String {
        switch self {
        case .checking:
            return "Checking browser control access."
        case .granted:
            return "Clicky can open background tabs in this browser."
        case .needsPermission(let browserName):
            return "Grant access so Clicky can control \(browserName) when you ask."
        case .denied(let browserName):
            return "Turn on Clicky under \(browserName) in Automation settings."
        case .noSupportedBrowserRunning:
            let supportedBrowserNames = CompanionBrowserAutomationTarget.supportedBrowsers.map(\.displayName).joined(separator: ", ")
            return "Open a supported browser to grant control: \(supportedBrowserNames)."
        case .unavailable(let browserName, let statusCode):
            return "\(browserName) returned Automation status \(statusCode)."
        }
    }

    var actionTitle: String {
        switch self {
        case .checking:
            return "Checking"
        case .granted:
            return "Granted"
        case .noSupportedBrowserRunning:
            return "Help"
        case .needsPermission, .denied, .unavailable:
            return "Grant"
        }
    }
}

enum CompanionBrowserAutomationPermissionManager {
    @MainActor
    static func preferredRunningBrowser() -> CompanionBrowserAutomationTarget? {
        let runningTargets = runningSupportedBrowsers()

        if let backgroundBrowser = runningTargets.first(where: { browserTarget in
            NSRunningApplication.runningApplications(withBundleIdentifier: browserTarget.bundleIdentifier)
                .contains(where: { !$0.isActive })
        }) {
            return backgroundBrowser
        }

        return runningTargets.first
    }

    @MainActor
    static func runningSupportedBrowsers() -> [CompanionBrowserAutomationTarget] {
        CompanionBrowserAutomationTarget.supportedBrowsers.filter { browserTarget in
            !NSRunningApplication.runningApplications(withBundleIdentifier: browserTarget.bundleIdentifier).isEmpty
        }
    }

    @MainActor
    static func currentPermissionStatus() async -> CompanionBrowserAutomationPermissionStatus {
        guard let target = preferredRunningBrowser() else {
            return .noSupportedBrowserRunning
        }

        return await permissionStatus(for: target, askUserIfNeeded: false)
    }

    @MainActor
    static func requestPermissionForPreferredRunningBrowser() async -> CompanionBrowserAutomationPermissionStatus {
        guard let target = preferredRunningBrowser() else {
            return .noSupportedBrowserRunning
        }

        return await permissionStatus(for: target, askUserIfNeeded: true)
    }

    static func permissionStatus(
        for target: CompanionBrowserAutomationTarget,
        askUserIfNeeded: Bool
    ) async -> CompanionBrowserAutomationPermissionStatus {
        let statusCode = await Task.detached(priority: .userInitiated) {
            determinePermissionStatusCode(for: target, askUserIfNeeded: askUserIfNeeded)
        }.value

        switch statusCode {
        case noErr:
            return .granted(browserName: target.displayName)
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .needsPermission(browserName: target.displayName)
        case OSStatus(errAEEventNotPermitted):
            return .denied(browserName: target.displayName)
        case OSStatus(procNotFound):
            return .noSupportedBrowserRunning
        default:
            return .unavailable(browserName: target.displayName, statusCode: statusCode)
        }
    }

    private static func determinePermissionStatusCode(
        for target: CompanionBrowserAutomationTarget,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        var targetDescriptor = AEAddressDesc()
        guard let bundleIdentifierData = target.bundleIdentifier.data(using: .utf8) else {
            return OSStatus(paramErr)
        }

        let createStatus = bundleIdentifierData.withUnsafeBytes { rawBuffer -> OSStatus in
            OSStatus(AECreateDesc(
                DescType(typeApplicationBundleID),
                rawBuffer.baseAddress,
                bundleIdentifierData.count,
                &targetDescriptor
            ))
        }
        guard createStatus == noErr else {
            return createStatus
        }
        defer {
            AEDisposeDesc(&targetDescriptor)
        }

        return AEDeterminePermissionToAutomateTarget(
            &targetDescriptor,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }
}
