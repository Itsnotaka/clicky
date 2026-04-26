//
//  CompanionBackgroundAgent.swift
//  leanring-buddy
//
//  Background action planning models and reusable executors for Clicky.
//

import AppKit
import ApplicationServices
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
        case pressAXTarget = "press_ax_target"
        case focusAXTarget = "focus_ax_target"
        case setAXText = "set_ax_text"
        case scrollAXTarget = "scroll_ax_target"
        case performAXAction = "perform_ax_action"
        case wait = "wait"
    }

    enum AXActionName: String, Decodable {
        case press
        case increment
        case decrement
        case confirm
        case cancel
        case showMenu = "show_menu"
        case pick
    }

    let type: ActionType
    let url: URL?
    let ref: String?
    let text: String?
    let scrollX: Int?
    let scrollY: Int?
    let steps: Int?
    let axAction: AXActionName?
    let milliseconds: Int?
}

struct CompanionBackgroundActionResult {
    let spokenText: String
}

struct CompanionBackgroundComputerUseSnapshot {
    struct Target {
        let ref: String
        let element: AXUIElement
        let role: String
        let title: String
        let description: String
        let actions: [String]
        let isTextInput: Bool
        let canSetValue: Bool
        let canFocus: Bool
        let canPress: Bool
        let canScroll: Bool
        let canIncrement: Bool
        let canDecrement: Bool
        let frame: CGRect?

        func withRef(_ ref: String) -> Target {
            Target(
                ref: ref,
                element: element,
                role: role,
                title: title,
                description: description,
                actions: actions,
                isTextInput: isTextInput,
                canSetValue: canSetValue,
                canFocus: canFocus,
                canPress: canPress,
                canScroll: canScroll,
                canIncrement: canIncrement,
                canDecrement: canDecrement,
                frame: frame
            )
        }
    }

    let appName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let windowTitle: String
    let targets: [Target]

    var plannerContext: String {
        var lines = [
            "current controlled window:",
            "app: \(appName)",
            "bundle id: \(bundleIdentifier ?? "unknown")",
            "window title: \(windowTitle.isEmpty ? "untitled" : windowTitle)",
            "available accessibility targets:"
        ]

        if targets.isEmpty {
            lines.append("none")
            return lines.joined(separator: "\n")
        }

        for target in targets {
            var capabilities: [String] = []
            if target.canPress { capabilities.append("press") }
            if target.canFocus { capabilities.append("focus") }
            if target.canSetValue { capabilities.append("setText") }
            if target.canScroll { capabilities.append("scroll") }
            if target.canIncrement { capabilities.append("increment") }
            if target.canDecrement { capabilities.append("decrement") }

            let labelParts = [target.title, target.description]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let label = labelParts.isEmpty ? "unlabeled" : labelParts.joined(separator: " / ")
            let frameText: String
            if let frame = target.frame {
                frameText = " frame=(x:\(Int(frame.origin.x)), y:\(Int(frame.origin.y)), w:\(Int(frame.width)), h:\(Int(frame.height)))"
            } else {
                frameText = ""
            }

            lines.append("- @\(target.ref): role=\(target.role) label=\"\(label)\" capabilities=\(capabilities.joined(separator: ","))\(frameText)")
        }

        return lines.joined(separator: "\n")
    }

    func target(for plannerRef: String) -> Target? {
        var normalizedRef = plannerRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRef.hasPrefix("@") {
            normalizedRef.removeFirst()
        }
        return targets.first { $0.ref == normalizedRef }
    }
}

enum CompanionBackgroundActionError: LocalizedError {
    case invalidActionPayload(String)
    case noRunningSupportedBrowser
    case browserHasNoOpenWindow(String)
    case browserAutomationFailed(String)
    case noBackgroundComputerUseTarget
    case backgroundComputerUseTargetNotFound(String)
    case backgroundComputerUseActionFailed(String)

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
        case .noBackgroundComputerUseTarget:
            return "I need a visible app window with accessibility targets before I can do that quietly."
        case .backgroundComputerUseTargetNotFound(let ref):
            return "I couldn't find background target \(ref) anymore."
        case .backgroundComputerUseActionFailed(let message):
            return message
        }
    }
}

@MainActor
enum CompanionBackgroundActionExecutor {
    private struct ResolvedAXTarget {
        let target: CompanionBackgroundComputerUseSnapshot.Target
        let processIdentifier: pid_t
    }

    static func execute(
        plan: CompanionBackgroundActionPlan,
        computerUseSnapshot: CompanionBackgroundComputerUseSnapshot?
    ) async throws -> CompanionBackgroundActionResult {
        for (actionIndex, action) in plan.actions.enumerated() {
            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "background_action.action_started",
                fields: logFields(for: action, actionIndex: actionIndex)
            )
            try await execute(action: action, computerUseSnapshot: computerUseSnapshot)
            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "event",
                event: "background_action.action_finished",
                fields: logFields(for: action, actionIndex: actionIndex)
            )
        }

        let trimmedSpokenText = plan.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanionBackgroundActionResult(
            spokenText: trimmedSpokenText.isEmpty ? "done." : trimmedSpokenText
        )
    }

    private static func logFields(for action: CompanionBackgroundAction, actionIndex: Int) -> [String: String] {
        [
            "index": "\(actionIndex + 1)",
            "type": action.type.rawValue,
            "url": action.url?.absoluteString ?? "none",
            "ref": action.ref ?? "none",
            "textLength": "\(action.text?.count ?? 0)",
            "scrollX": "\(action.scrollX ?? 0)",
            "scrollY": "\(action.scrollY ?? 0)",
            "steps": "\(action.steps ?? 0)",
            "axAction": action.axAction?.rawValue ?? "none",
            "milliseconds": "\(action.milliseconds ?? 0)"
        ]
    }

    private static func execute(
        action: CompanionBackgroundAction,
        computerUseSnapshot: CompanionBackgroundComputerUseSnapshot?
    ) async throws {
        switch action.type {
        case .openURLInBackgroundBrowser:
            guard let url = action.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw CompanionBackgroundActionError.invalidActionPayload("I need a valid web URL for that background action.")
            }

            try await openURLInBackgroundBrowser(url)

        case .pressAXTarget:
            let resolvedTarget = try resolvedAXTarget(for: action, in: computerUseSnapshot)
            guard resolvedTarget.target.canPress else {
                throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("That background target can't be pressed safely.")
            }
            try performAXAction(.press, on: resolvedTarget)

        case .focusAXTarget:
            let resolvedTarget = try resolvedAXTarget(for: action, in: computerUseSnapshot)
            guard resolvedTarget.target.canFocus else {
                throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("That background target can't be focused safely.")
            }
            try setAXFocused(resolvedTarget.target)

        case .setAXText:
            let resolvedTarget = try resolvedAXTarget(for: action, in: computerUseSnapshot)
            guard resolvedTarget.target.canSetValue else {
                throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("That background target doesn't allow text replacement.")
            }
            guard let text = action.text else {
                throw CompanionBackgroundActionError.invalidActionPayload("Background text actions need text.")
            }
            try setAXValue(text, on: resolvedTarget.target)

        case .scrollAXTarget:
            let resolvedTarget = try resolvedAXTarget(for: action, in: computerUseSnapshot)
            guard resolvedTarget.target.canScroll else {
                throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("That background target can't scroll safely.")
            }
            let scrollX = action.scrollX ?? 0
            let scrollY = action.scrollY ?? 0
            guard scrollX != 0 || scrollY != 0 else {
                throw CompanionBackgroundActionError.invalidActionPayload("Background scroll actions need a non-zero scroll amount.")
            }
            try performAXScroll(scrollX: scrollX, scrollY: scrollY, steps: action.steps ?? 1, on: resolvedTarget)

        case .performAXAction:
            let resolvedTarget = try resolvedAXTarget(for: action, in: computerUseSnapshot)
            guard let axAction = action.axAction else {
                throw CompanionBackgroundActionError.invalidActionPayload("Background AX actions need an action name.")
            }
            try performAXAction(axAction, on: resolvedTarget)

        case .wait:
            let milliseconds = max(0, min(action.milliseconds ?? 500, 10_000))
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    private static func resolvedAXTarget(
        for action: CompanionBackgroundAction,
        in computerUseSnapshot: CompanionBackgroundComputerUseSnapshot?
    ) throws -> ResolvedAXTarget {
        guard let computerUseSnapshot else {
            throw CompanionBackgroundActionError.noBackgroundComputerUseTarget
        }
        guard let ref = action.ref else {
            throw CompanionBackgroundActionError.invalidActionPayload("Background computer-use actions need a target ref.")
        }
        guard let target = computerUseSnapshot.target(for: ref) else {
            throw CompanionBackgroundActionError.backgroundComputerUseTargetNotFound(ref)
        }
        return ResolvedAXTarget(target: target, processIdentifier: computerUseSnapshot.processIdentifier)
    }

    private static func setAXFocused(_ target: CompanionBackgroundComputerUseSnapshot.Target) throws {
        let status = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard status == .success else {
            throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("Failed to focus background target (AX error \(status.rawValue)).")
        }
    }

    private static func setAXValue(_ value: String, on target: CompanionBackgroundComputerUseSnapshot.Target) throws {
        let status = AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard status == .success else {
            throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("Failed to set background text (AX error \(status.rawValue)).")
        }
    }

    private static func performAXAction(
        _ axAction: CompanionBackgroundAction.AXActionName,
        on resolvedTarget: ResolvedAXTarget
    ) throws {
        let actionName = axActionName(axAction)
        var currentElement: AXUIElement? = resolvedTarget.target.element
        var depth = 0

        while let candidate = currentElement, depth < 10 {
            if let ownerProcessIdentifier = CompanionBackgroundComputerUseController.processIdentifier(for: candidate),
               ownerProcessIdentifier != resolvedTarget.processIdentifier {
                throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("The background target moved to another app.")
            }

            if CompanionBackgroundComputerUseController.actionNames(for: candidate).contains(actionName as String) {
                let status = AXUIElementPerformAction(candidate, actionName)
                if status == .success {
                    return
                }
            }

            currentElement = CompanionBackgroundComputerUseController.parentElement(for: candidate)
            depth += 1
        }

        throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("That background action is not available on the target.")
    }

    private static func performAXScroll(
        scrollX: Int,
        scrollY: Int,
        steps: Int,
        on resolvedTarget: ResolvedAXTarget
    ) throws {
        var actionNames: [CFString] = []
        if scrollY > 0 { actionNames.append("AXScrollDown" as CFString) }
        if scrollY < 0 { actionNames.append("AXScrollUp" as CFString) }
        if scrollX > 0 { actionNames.append("AXScrollRight" as CFString) }
        if scrollX < 0 { actionNames.append("AXScrollLeft" as CFString) }

        var didScroll = false
        let clampedSteps = max(1, min(steps, 8))
        var currentElement: AXUIElement? = resolvedTarget.target.element
        var depth = 0

        while let candidate = currentElement, depth < 10 {
            if let ownerProcessIdentifier = CompanionBackgroundComputerUseController.processIdentifier(for: candidate),
               ownerProcessIdentifier != resolvedTarget.processIdentifier {
                throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("The background target moved to another app.")
            }

            let candidateActionNames = CompanionBackgroundComputerUseController.actionNames(for: candidate)
            for _ in 0..<clampedSteps {
                for actionName in actionNames where candidateActionNames.contains(actionName as String) {
                    let status = AXUIElementPerformAction(candidate, actionName)
                    if status == .success {
                        didScroll = true
                    }
                }
            }

            if didScroll {
                return
            }

            currentElement = CompanionBackgroundComputerUseController.parentElement(for: candidate)
            depth += 1
        }

        throw CompanionBackgroundActionError.backgroundComputerUseActionFailed("That background target did not accept a scroll action.")
    }

    private static func axActionName(_ axAction: CompanionBackgroundAction.AXActionName) -> CFString {
        switch axAction {
        case .press:
            return kAXPressAction as CFString
        case .increment:
            return kAXIncrementAction as CFString
        case .decrement:
            return kAXDecrementAction as CFString
        case .confirm:
            return kAXConfirmAction as CFString
        case .cancel:
            return kAXCancelAction as CFString
        case .showMenu:
            return kAXShowMenuAction as CFString
        case .pick:
            return kAXPickAction as CFString
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
            PermisoAssistant.shared.present(panel: .automation(targetApplicationName: target.displayName))
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

@MainActor
enum CompanionBackgroundComputerUseController {
    private static let textInputRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXTextView",
        "AXSearchField",
        "AXComboBox",
        "AXEditableText",
        "AXSecureTextField"
    ]

    private static let structuralRoles: Set<String> = [
        "AXApplication",
        "AXWindow",
        "AXToolbar",
        "AXGroup",
        "AXScrollArea",
        "AXSplitGroup",
        "AXLayoutArea",
        "AXTabGroup",
        "AXWebArea"
    ]

    static func snapshotForCurrentVisibleWindow(limit: Int = 24) -> CompanionBackgroundComputerUseSnapshot? {
        guard AXIsProcessTrusted(),
              let runningApplication = frontmostControllableApplication() else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
        guard let windowElement = selectedWindowElement(for: applicationElement) else {
            return nil
        }

        let windowTitle = stringAttribute(windowElement, attribute: kAXTitleAttribute as CFString) ?? ""
        let windowFrame = frame(for: windowElement) ?? .zero
        let windowArea = max(1.0, windowFrame.width * windowFrame.height)
        let descendants = collectDescendants(startingAt: windowElement, maxDepth: 8)

        var uniqueTargets: [String: (target: CompanionBackgroundComputerUseSnapshot.Target, score: Double)] = [:]

        for element in descendants {
            guard let target = buildTarget(
                element: element,
                windowArea: windowArea
            ) else { continue }

            let normalizedLabel = [target.title, target.description]
                .joined(separator: "|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let frame = target.frame ?? .zero
            let uniquenessKey = "\(target.role)|\(normalizedLabel)|\(Int(frame.midX / 24))|\(Int(frame.midY / 24))"
            let score = score(target: target, windowArea: windowArea)
            guard score >= 80 else { continue }

            if let existing = uniqueTargets[uniquenessKey], existing.score >= score {
                continue
            }
            uniqueTargets[uniquenessKey] = (target, score)
        }

        let rankedTargets = uniqueTargets.values
            .sorted { $0.score > $1.score }
            .prefix(max(1, min(limit, 50)))
            .enumerated()
            .map { targetIndex, rankedTarget in
                rankedTarget.target.withRef("e\(targetIndex + 1)")
            }

        return CompanionBackgroundComputerUseSnapshot(
            appName: runningApplication.localizedName ?? "Unknown App",
            bundleIdentifier: runningApplication.bundleIdentifier,
            processIdentifier: runningApplication.processIdentifier,
            windowTitle: windowTitle,
            targets: Array(rankedTargets)
        )
    }

    static func actionNames(for element: AXUIElement) -> [String] {
        var actionsValue: CFArray?
        let status = AXUIElementCopyActionNames(element, &actionsValue)
        guard status == .success,
              let actionsArray = actionsValue as? [AnyObject] else {
            return []
        }
        return actionsArray.compactMap { $0 as? String }
    }

    static func parentElement(for element: AXUIElement) -> AXUIElement? {
        copyAttribute(element, attribute: kAXParentAttribute as CFString).flatMap(asAXElement)
    }

    static func processIdentifier(for element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        let status = AXUIElementGetPid(element, &processIdentifier)
        guard status == .success else { return nil }
        return processIdentifier
    }

    private static func frontmostControllableApplication() -> NSRunningApplication? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != ownBundleIdentifier,
              frontmostApplication.activationPolicy == .regular else {
            return nil
        }

        return frontmostApplication
    }

    private static func selectedWindowElement(for applicationElement: AXUIElement) -> AXUIElement? {
        if let focusedWindow = copyAttribute(applicationElement, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement) {
            return focusedWindow
        }

        let windows = axElementArray(applicationElement, attribute: kAXWindowsAttribute as CFString)
        return windows.sorted { leftWindow, rightWindow in
            score(window: leftWindow) > score(window: rightWindow)
        }.first
    }

    private static func score(window: AXUIElement) -> Int {
        var score = 0
        if boolAttribute(window, attribute: kAXFocusedAttribute as CFString) == true { score += 100 }
        if boolAttribute(window, attribute: kAXMainAttribute as CFString) == true { score += 80 }
        if boolAttribute(window, attribute: kAXMinimizedAttribute as CFString) == false { score += 40 }
        if frame(for: window) != nil { score += 20 }
        return score
    }

    private static func buildTarget(
        element: AXUIElement,
        windowArea: CGFloat
    ) -> CompanionBackgroundComputerUseSnapshot.Target? {
        let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        let title = sanitizedLabel(stringAttribute(element, attribute: kAXTitleAttribute as CFString))
        let description = sanitizedLabel(stringAttribute(element, attribute: kAXDescriptionAttribute as CFString))
        let actions = actionNames(for: element)
        let elementFrame = frame(for: element)

        var focusedSettable = DarwinBoolean(false)
        let focusStatus = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusedSettable)
        var valueSettable = DarwinBoolean(false)
        let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)

        let canFocus = focusStatus == .success && focusedSettable.boolValue
        let canSetValue = valueStatus == .success && valueSettable.boolValue
        let canPress = actions.contains(kAXPressAction as String)
        let canScroll = supportsAnyScrollAction(actions)
        let canIncrement = actions.contains(kAXIncrementAction as String)
        let canDecrement = actions.contains(kAXDecrementAction as String)
        let isTextInput = textInputRoles.contains(role) || canSetValue

        guard isTextInput || canPress || canFocus || canScroll || canIncrement || canDecrement else {
            return nil
        }

        if let elementFrame {
            guard elementFrame.width > 6, elementFrame.height > 6 else { return nil }
            let area = elementFrame.width * elementFrame.height
            if area > windowArea * 0.85, role != "AXScrollArea", role != "AXWebArea" {
                return nil
            }
        }

        let hasLabel = !title.isEmpty || !description.isEmpty
        if structuralRoles.contains(role), !canScroll, !hasLabel {
            return nil
        }
        if role == "AXButton", !hasLabel {
            return nil
        }
        if subrole == "AXCloseButton" {
            return nil
        }

        return CompanionBackgroundComputerUseSnapshot.Target(
            ref: "",
            element: element,
            role: role,
            title: title,
            description: description,
            actions: actions,
            isTextInput: isTextInput,
            canSetValue: canSetValue,
            canFocus: canFocus,
            canPress: canPress,
            canScroll: canScroll,
            canIncrement: canIncrement,
            canDecrement: canDecrement,
            frame: elementFrame
        )
    }

    private static func score(target: CompanionBackgroundComputerUseSnapshot.Target, windowArea: CGFloat) -> Double {
        var score = 0.0
        if target.isTextInput { score += target.canSetValue ? 180 : 90 }
        if target.canPress { score += 140 }
        if target.canFocus { score += 80 }
        if target.canScroll { score += 120 }
        if target.canIncrement || target.canDecrement { score += 110 }
        if !target.title.isEmpty { score += 50 }
        if !target.description.isEmpty { score += 30 }
        if structuralRoles.contains(target.role) { score -= target.canScroll ? 20 : 140 }
        if target.role == "AXScrollArea" { score += 120 }
        if let frame = target.frame, frame.width * frame.height > windowArea * 0.65 {
            score -= 120
        }
        return score
    }

    private static func supportsAnyScrollAction(_ actions: [String]) -> Bool {
        actions.contains("AXScrollDown")
            || actions.contains("AXScrollUp")
            || actions.contains("AXScrollLeft")
            || actions.contains("AXScrollRight")
    }

    private static func collectDescendants(startingAt root: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var output: [AXUIElement] = []
        var currentIndex = 0

        while currentIndex < queue.count {
            let current = queue[currentIndex]
            currentIndex += 1
            output.append(current.element)

            guard current.depth < maxDepth else { continue }
            for child in axElementArray(current.element, attribute: kAXChildrenAttribute as CFString) {
                queue.append((child, current.depth + 1))
            }
        }

        return output
    }

    private static func axElementArray(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        guard let value = copyAttribute(element, attribute: attribute) else { return [] }
        if let array = value as? [AnyObject] {
            return array.compactMap(asAXElement)
        }
        if let element = asAXElement(value) {
            return [element]
        }
        return []
    }

    private static func copyAttribute(_ element: AXUIElement, attribute: CFString) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value
    }

    private static func boolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        copyAttribute(element, attribute: attribute) as? Bool
    }

    private static func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        copyAttribute(element, attribute: attribute) as? String
    }

    private static func frame(for element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, attribute: kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, attribute: kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        guard let value = copyAttribute(element, attribute: attribute) else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        guard let value = copyAttribute(element, attribute: attribute) else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func asAXElement(_ value: AnyObject) -> AXUIElement? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(cfValue, to: AXUIElement.self)
    }

    private static func sanitizedLabel(_ value: String?) -> String {
        let trimmedValue = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmedValue.count > 120 else { return trimmedValue }
        return String(trimmedValue.prefix(117)) + "..."
    }
}
