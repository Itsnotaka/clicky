//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the floating Clicky settings panel.
//  Keeps setup, model, prompt, and quick settings in a native macOS-style panel.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var typedPromptInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                codexInlineBanner

                if !companionManager.browserAutomationPermissionStatus.isGranted {
                    VStack(spacing: 0) {
                        browserAutomationPermissionRow
                    }
                    .nativeSettingsGroup()
                }

                typedPromptRow

                preferencesSection
            } else {
                permissionsCopySection

                if !companionManager.allPermissionsGranted {
                    settingsSection
                }

                if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                    startButton
                }
            }

            footerSection
        }
        .padding(14)
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clicky Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Text(headerStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)

                Text(companionManager.isAgentRunning ? "On" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var headerModelPicker: some View {
        Menu {
            ForEach(companionManager.availableModels) { modelOption in
                Button(action: {
                    companionManager.setSelectedModel(modelOption.id)
                }) {
                    HStack {
                        Text(modelOption.displayName)
                        if modelOption.id == companionManager.selectedModel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(companionManager.selectedModelDisplayName)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .pointerCursor()
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)

                Text("Some permissions were revoked. Grant the permissions below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Clicky can run small background actions when you ask, like opening web stuff in an existing browser. Screenshots are still only captured when you talk or type to Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button(action: {
            companionManager.triggerOnboarding()
        }) {
            Text("Start")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .pointerCursor()
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        VStack(spacing: 0) {
            nativeRow(label: "Model", iconName: "cpu") {
                headerModelPicker
            }

            Divider()

            showClickyCursorToggleRow
        }
        .nativeSettingsGroup()
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                microphonePermissionRow

                Divider()

                accessibilityPermissionRow

                Divider()

                screenRecordingPermissionRow

                if companionManager.hasScreenRecordingPermission {
                    Divider()

                    screenContentPermissionRow
                }

                Divider()

                browserAutomationPermissionRow
            }
            .nativeSettingsGroup()
        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? .secondary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? .secondary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text(isGranted
                         ? "Screenshots are captured when you talk or type"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? .secondary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? .secondary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var browserAutomationPermissionRow: some View {
        let permissionStatus = companionManager.browserAutomationPermissionStatus
        let isGranted = permissionStatus.isGranted
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? .secondary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Browser Automation")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text(permissionStatus.statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: {
                    switch permissionStatus {
                    case .checking:
                        break
                    case .noSupportedBrowserRunning:
                        companionManager.openBrowserAutomationPermissionHelper()
                    case .needsPermission, .denied, .unavailable:
                        companionManager.requestBrowserAutomationPermission()
                    case .granted:
                        break
                    }
                }) {
                    Text(permissionStatus.actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
                .disabled(permissionStatus == .checking)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        nativeRow(label: "Show Clicky", iconName: "cursorarrow") {
            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func nativeRow<TrailingContent: View>(
        label: String,
        iconName: String,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            trailingContent()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Codex Banner

    @ViewBuilder
    private var codexInlineBanner: some View {
        switch companionManager.codexConnectionState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                Text("Checking Codex\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .nativeSettingsGroup()

        case .needsSignIn:
            Button(action: { companionManager.beginCodexSignIn() }) {
                HStack {
                    Text("Sign in to Codex")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .pointerCursor()

        case .unavailable(let message):
            HStack {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .nativeSettingsGroup()

        case .ready(_):
            EmptyView()
        }
    }

    // MARK: - Typed Prompt

    private var typedPromptRow: some View {
        let inputIsEmpty = typedPromptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            TextField("Type or hold \u{2303}\u{2325} to talk", text: $typedPromptInput)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitTypedPrompt()
                }

            Button(action: submitTypedPrompt) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .pointerCursor()
            .disabled(inputIsEmpty)
        }
    }

    private func submitTypedPrompt() {
        let prompt = typedPromptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        typedPromptInput = ""
        companionManager.submitTypedPrompt(prompt)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                        Text("Replay onboarding")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.20), radius: 18, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
    }

    private var headerStatusText: String {
        if !companionManager.isAgentRunning {
            return "Agent paused"
        }

        switch companionManager.codexConnectionState {
        case .checking:
            return "Checking Codex"
        case .needsSignIn:
            return "Sign in required"
        case .unavailable:
            return "Codex unavailable"
        case .ready:
            switch companionManager.voiceState {
            case .idle:
                return "Ready"
            case .listening:
                return "Listening"
            case .processing:
                return "Thinking"
            case .responding:
                return "Responding"
            }
        }
    }

    private var statusDotColor: Color {
        guard companionManager.isAgentRunning else {
            return .secondary
        }

        switch companionManager.codexConnectionState {
        case .checking:
            return .secondary
        case .needsSignIn:
            return DS.Colors.warning
        case .unavailable(_):
            return DS.Colors.destructive
        case .ready(_):
            switch companionManager.voiceState {
            case .idle:
                return DS.Colors.success
            case .listening, .processing, .responding:
                return DS.Colors.accentText
            }
        }
    }
}

private extension View {
    func nativeSettingsGroup() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            )
    }
}
