//
//  CompanionBackgroundAgent.swift
//  leanring-buddy
//
//  Background action planning models and reusable executors for Clicky.
//

import AppKit
import Foundation

struct CompanionBackgroundActionPlan: Decodable {
    let spokenText: String
    let actions: [CompanionBackgroundAction]

    var hasExecutableActions: Bool {
        !actions.isEmpty
    }
}

struct CompanionBackgroundAction: Decodable {
    enum ActionType: String, Decodable {
        case openURLInBackgroundBrowser = "open_url_in_background_browser"
    }

    let type: ActionType
    let url: URL?
}

struct CompanionBackgroundActionResult {
    let spokenText: String
}

enum CompanionBackgroundActionError: LocalizedError {
    case invalidActionPayload(String)
    case noRunningSupportedBrowser
    case browserHasNoOpenWindow(String)
    case browserAutomationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidActionPayload(let message):
            return message
        case .noRunningSupportedBrowser:
            return "I need a supported browser already running before I can do that quietly."
        case .browserHasNoOpenWindow(let browserName):
            return "I need an open \(browserName) window before I can do that in the background."
        case .browserAutomationFailed(let message):
            return message
        }
    }
}

@MainActor
enum CompanionBackgroundActionExecutor {
    static func execute(plan: CompanionBackgroundActionPlan) async throws -> CompanionBackgroundActionResult {
        for action in plan.actions {
            try await execute(action: action)
        }

        let trimmedSpokenText = plan.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanionBackgroundActionResult(
            spokenText: trimmedSpokenText.isEmpty ? "done." : trimmedSpokenText
        )
    }

    private static func execute(action: CompanionBackgroundAction) async throws {
        switch action.type {
        case .openURLInBackgroundBrowser:
            guard let url = action.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw CompanionBackgroundActionError.invalidActionPayload("I need a valid web URL for that background action.")
            }

            try await openURLInBackgroundBrowser(url)
        }
    }

    private static func openURLInBackgroundBrowser(_ url: URL) async throws {
        guard let target = CompanionBrowserAutomationPermissionManager.preferredRunningBrowser() else {
            throw CompanionBackgroundActionError.noRunningSupportedBrowser
        }

        let automationPermissionStatus = await CompanionBrowserAutomationPermissionManager.permissionStatus(
            for: target,
            askUserIfNeeded: true
        )
        guard automationPermissionStatus.isGranted else {
            CompanionPermissionAssistant.shared.present(panel: .automation(targetApplicationName: target.displayName))
            throw CompanionBackgroundActionError.browserAutomationFailed(automationPermissionStatus.detailText)
        }

        let previousFrontmostApplication = NSWorkspace.shared.frontmostApplication

        do {
            switch target.family {
            case .chromium:
                try runAppleScript(chromiumOpenBackgroundTabScript(bundleIdentifier: target.bundleIdentifier, url: url))
            case .safari:
                try runAppleScript(safariOpenBackgroundTabScript(bundleIdentifier: target.bundleIdentifier, url: url))
            }
        } catch CompanionBackgroundActionError.browserAutomationFailed(let message) where message.contains("no_browser_window") {
            throw CompanionBackgroundActionError.browserHasNoOpenWindow(target.displayName)
        } catch {
            throw error
        }

        restoreFrontmostApplicationIfNeeded(previousFrontmostApplication)
    }

    private static func restoreFrontmostApplicationIfNeeded(_ previousFrontmostApplication: NSRunningApplication?) {
        guard let previousFrontmostApplication,
              previousFrontmostApplication.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return
        }

        previousFrontmostApplication.activate()
    }

    private static func chromiumOpenBackgroundTabScript(bundleIdentifier: String, url: URL) -> String {
        """
        tell application id \(appleScriptStringLiteral(bundleIdentifier))
            if (count of windows) is 0 then error "no_browser_window"
            make new tab at end of tabs of front window with properties {URL:\(appleScriptStringLiteral(url.absoluteString))}
        end tell
        """
    }

    private static func safariOpenBackgroundTabScript(bundleIdentifier: String, url: URL) -> String {
        """
        tell application id \(appleScriptStringLiteral(bundleIdentifier))
            if (count of windows) is 0 then error "no_browser_window"
            tell front window to make new tab at end of tabs with properties {URL:\(appleScriptStringLiteral(url.absoluteString))}
        end tell
        """
    }

    private static func runAppleScript(_ script: String) throws {
        guard let appleScript = NSAppleScript(source: script) else {
            throw CompanionBackgroundActionError.browserAutomationFailed("Browser automation script could not be created.")
        }

        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo, errorInfo.count > 0 else { return }

        let message = errorInfo[NSAppleScript.errorMessage] as? String
        let number = errorInfo[NSAppleScript.errorNumber] as? NSNumber
        let diagnosticText: String
        if let message, let number {
            diagnosticText = "\(message) (\(number.intValue))"
        } else if let message {
            diagnosticText = message
        } else {
            diagnosticText = "Browser automation failed."
        }

        throw CompanionBackgroundActionError.browserAutomationFailed(diagnosticText)
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escapedValue)\""
    }
}
