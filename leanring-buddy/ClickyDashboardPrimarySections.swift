//
//  ClickyDashboardPrimarySections.swift
//  leanring-buddy
//
//  Overview, model, voice, and cursor sections for the Clicky dashboard.
//

import AVFoundation
import Speech
import SwiftUI

struct ClickyDashboardOverviewSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var clickyUpdaterManager: ClickyUpdaterManager
    @Binding var dashboardPromptInput: String
    let submitDashboardPrompt: () -> Void
    let refreshCodexState: () -> Void
    let checkForUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClickyDashboardCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Native control center")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(DS.Colors.textPrimary)

                            Text("The menu bar stays fast. The dashboard owns deep configuration, computer-use visibility, and debugging.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Toggle("Agent running", isOn: Binding(
                            get: { companionManager.isAgentRunning },
                            set: { companionManager.setAgentRunning($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .pointerCursor()
                    }

                    HStack(spacing: 8) {
                        TextField("Ask Clicky from the dashboard", text: $dashboardPromptInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit(submitDashboardPrompt)

                        Button(action: submitDashboardPrompt) {
                            Label("Send", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(dashboardPromptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor(isEnabled: !dashboardPromptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ClickyDashboardMetricCard(title: "Codex", value: codexStatusText, systemImageName: "sparkles")
                ClickyDashboardMetricCard(title: "Model", value: companionManager.selectedModelDisplayName, systemImageName: "cpu")
                ClickyDashboardMetricCard(title: "Voice", value: companionManager.speechOutputDisplayName, systemImageName: "speaker.wave.2")
                ClickyDashboardMetricCard(title: "Cursor", value: companionManager.isOverlayVisible ? "Visible" : "Hidden", systemImageName: "cursorarrow")
                ClickyDashboardMetricCard(title: "Updates", value: clickyUpdaterManager.updateStatusText, systemImageName: "arrow.triangle.2.circlepath")
                ClickyDashboardMetricCard(title: "Permissions", value: companionManager.allPermissionsGranted ? "Ready" : "Needs setup", systemImageName: "checkmark.shield")
            }

            ClickyDashboardPermissionsCard(companionManager: companionManager)

            ClickyDashboardCard {
                HStack(spacing: 10) {
                    Button(action: refreshCodexState) {
                        Label("Refresh Codex", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()

                    Button(action: checkForUpdates) {
                        Label("Check For Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!clickyUpdaterManager.canCheckForUpdates)
                    .pointerCursor(isEnabled: clickyUpdaterManager.canCheckForUpdates)

                    Spacer()
                }
            }
        }
    }

    private var codexStatusText: String {
        switch companionManager.codexConnectionState {
        case .checking:
            return "Checking"
        case .needsSignIn:
            return "Sign in"
        case .ready(let planType):
            return planType?.isEmpty == false ? "Ready (\(planType!))" : "Ready"
        case .unavailable:
            return "Unavailable"
        }
    }
}

private struct ClickyDashboardPermissionRequirement: Identifiable {
    let id: String
    let iconName: String
    let permissionName: String
    let permissionStatusText: String
    let detailText: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void
}

private struct ClickyDashboardPermissionsCard: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ClickyDashboardCard(title: "Setup & permissions", subtitle: "Grant or repair everything Clicky needs from the dashboard.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(permissionRequirements.enumerated()), id: \.element.id) { permissionRequirementIndex, permissionRequirement in
                    if permissionRequirementIndex > 0 {
                        Divider()
                    }

                    ClickyDashboardPermissionRow(permissionRequirement: permissionRequirement)
                }

                Divider()

                Button(action: companionManager.refreshAllPermissions) {
                    Label("Refresh Permissions", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 12)
                .pointerCursor()

                if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                    Divider()

                    Button(action: companionManager.triggerOnboarding) {
                        Label("Start Clicky", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 12)
                    .pointerCursor()
                }
            }
        }
    }

    private var permissionRequirements: [ClickyDashboardPermissionRequirement] {
        let browserAutomationPermissionStatus = companionManager.browserAutomationPermissionStatus

        return [
            ClickyDashboardPermissionRequirement(
                id: "accessibility",
                iconName: "hand.raised",
                permissionName: "Accessibility",
                permissionStatusText: companionManager.hasAccessibilityPermission ? "Granted" : "Missing",
                detailText: "Global hotkey and UI control",
                isGranted: companionManager.hasAccessibilityPermission,
                actionTitle: "Grant",
                action: {
                    WindowPositionManager.requestAccessibilityPermission()
                    companionManager.refreshAllPermissions()
                }
            ),
            ClickyDashboardPermissionRequirement(
                id: "screen-recording",
                iconName: "rectangle.dashed.badge.record",
                permissionName: "Screen Recording",
                permissionStatusText: companionManager.hasScreenRecordingPermission ? "Granted" : "Missing",
                detailText: "Screenshots after prompts",
                isGranted: companionManager.hasScreenRecordingPermission,
                actionTitle: "Grant",
                action: {
                    WindowPositionManager.requestScreenRecordingPermission()
                    companionManager.refreshAllPermissions()
                }
            ),
            ClickyDashboardPermissionRequirement(
                id: "microphone",
                iconName: "mic",
                permissionName: "Microphone",
                permissionStatusText: companionManager.hasMicrophonePermission ? "Granted" : "Missing",
                detailText: "Push-to-talk audio input",
                isGranted: companionManager.hasMicrophonePermission,
                actionTitle: "Grant",
                action: {
                    let microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    if microphoneAuthorizationStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in
                                companionManager.refreshAllPermissions()
                            }
                        }
                    } else if let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(microphoneSettingsURL)
                        companionManager.refreshAllPermissions()
                    }
                }
            ),
            ClickyDashboardPermissionRequirement(
                id: "screen-content",
                iconName: "eye",
                permissionName: "Screen Content",
                permissionStatusText: companionManager.hasScreenContentPermission ? "Granted" : "Missing",
                detailText: "ScreenCaptureKit access",
                isGranted: companionManager.hasScreenContentPermission,
                actionTitle: "Grant",
                action: {
                    companionManager.requestScreenContentPermission()
                }
            ),
            ClickyDashboardPermissionRequirement(
                id: "speech-recognition",
                iconName: "waveform.and.mic",
                permissionName: "Speech Recognition",
                permissionStatusText: companionManager.hasSpeechRecognitionPermission ? "Granted" : "Missing",
                detailText: "Voice transcription",
                isGranted: companionManager.hasSpeechRecognitionPermission,
                actionTitle: "Grant",
                action: {
                    let speechRecognitionAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
                    if speechRecognitionAuthorizationStatus == .notDetermined {
                        SFSpeechRecognizer.requestAuthorization { _ in
                            Task { @MainActor in
                                companionManager.refreshAllPermissions()
                            }
                        }
                    } else if let speechRecognitionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                        NSWorkspace.shared.open(speechRecognitionSettingsURL)
                        companionManager.refreshAllPermissions()
                    }
                }
            ),
            ClickyDashboardPermissionRequirement(
                id: "browser-automation",
                iconName: "globe",
                permissionName: "Browser Automation",
                permissionStatusText: browserAutomationPermissionStatus.statusText,
                detailText: browserAutomationPermissionStatus.isGranted ? "Background browser control" : browserAutomationPermissionStatus.detailText,
                isGranted: browserAutomationPermissionStatus.isGranted,
                actionTitle: browserAutomationPermissionStatus.actionTitle,
                action: {
                    switch browserAutomationPermissionStatus {
                    case .checking, .granted:
                        break
                    case .noSupportedBrowserRunning:
                        companionManager.openBrowserAutomationPermissionHelper()
                    case .needsPermission, .denied, .unavailable:
                        companionManager.requestBrowserAutomationPermission()
                    }
                }
            )
        ]
    }
}

private struct ClickyDashboardPermissionRow: View {
    let permissionRequirement: ClickyDashboardPermissionRequirement

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: permissionRequirement.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(permissionRequirement.isGranted ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(permissionRequirement.permissionName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(permissionRequirement.detailText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if permissionRequirement.isGranted {
                Text(permissionRequirement.permissionStatusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button(action: permissionRequirement.action) {
                    Text(permissionRequirement.actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(permissionRequirement.actionTitle == "Checking")
                .pointerCursor(isEnabled: permissionRequirement.actionTitle != "Checking")
            }
        }
        .padding(.vertical, 10)
    }
}

struct ClickyDashboardModelAndVoiceSection: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClickyDashboardCodexStatusCard(companionManager: companionManager)

            ClickyDashboardCard(title: "Model behavior", subtitle: "These controls affect Codex app-server turns for voice and typed prompts.") {
                VStack(spacing: 0) {
                    ClickyDashboardControlRow(title: "Model", subtitle: "Use the models returned by your local Codex account.", systemImageName: "cpu") {
                        Picker("Model", selection: Binding(
                            get: { companionManager.selectedModel },
                            set: { companionManager.setSelectedModel($0) }
                        )) {
                            if companionManager.availableModels.isEmpty {
                                Text("Default").tag("")
                            }

                            ForEach(companionManager.availableModels) { modelOption in
                                Text(modelOption.displayName).tag(modelOption.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                        .pointerCursor()
                    }

                    if !companionManager.selectedModelReasoningEfforts.isEmpty {
                        Divider()
                        ClickyDashboardControlRow(title: "Thinking", subtitle: "Choose the model's reasoning effort when the app-server exposes it.", systemImageName: "brain") {
                            Picker("Thinking", selection: Binding(
                                get: { companionManager.selectedReasoningEffort },
                                set: { companionManager.setSelectedReasoningEffort($0) }
                            )) {
                                ForEach(companionManager.selectedModelReasoningEfforts) { reasoningEffortOption in
                                    Text(reasoningEffortOption.displayName).tag(reasoningEffortOption.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 160)
                            .pointerCursor()
                        }
                    }

                    if companionManager.selectedModelSupportsFastMode {
                        Divider()
                        ClickyDashboardControlRow(title: "Fast mode", subtitle: "Ask Codex for the fast service tier when available.", systemImageName: "bolt") {
                            Toggle("", isOn: Binding(
                                get: { companionManager.isFastModeEnabled },
                                set: { companionManager.setFastModeEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }
                }
            }

            ClickyDashboardCard(title: "Voice", subtitle: "Local voice remains native so the app does not need speech API keys.") {
                VStack(spacing: 0) {
                    ClickyDashboardInfoRow(title: "Speech output", value: companionManager.speechOutputDisplayName, systemImageName: "speaker.wave.2")
                    Divider()
                    ClickyDashboardInfoRow(title: "Push to talk", value: BuddyPushToTalkShortcut.pushToTalkDisplayText, systemImageName: "keyboard")
                }
            }
        }
    }
}

struct ClickyDashboardCodexStatusCard: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ClickyDashboardCard {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusSystemImageName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(statusColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(statusColor.opacity(0.13)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(statusSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if case .needsSignIn = companionManager.codexConnectionState {
                    Button(action: companionManager.beginCodexSignIn) {
                        Label("Sign In", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .pointerCursor()
                } else {
                    Button(action: companionManager.refreshCodexConnectionState) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()
                }
            }
        }
    }

    private var statusTitle: String {
        switch companionManager.codexConnectionState {
        case .checking:
            return "Checking Codex"
        case .needsSignIn:
            return "Sign in needed"
        case .ready:
            return "Codex ready"
        case .unavailable:
            return "Codex unavailable"
        }
    }

    private var statusSubtitle: String {
        switch companionManager.codexConnectionState {
        case .checking:
            return "Clicky is querying the local app-server."
        case .needsSignIn:
            return "Authenticate through Codex with your ChatGPT subscription."
        case .ready(let planType):
            return planType?.isEmpty == false ? "Authenticated with plan \(planType!)." : "Authenticated and ready for local app-server turns."
        case .unavailable(let message):
            return message
        }
    }

    private var statusSystemImageName: String {
        switch companionManager.codexConnectionState {
        case .checking: return "clock"
        case .needsSignIn: return "person.crop.circle.badge.exclamationmark"
        case .ready: return "checkmark.seal.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch companionManager.codexConnectionState {
        case .checking: return DS.Colors.textTertiary
        case .needsSignIn: return DS.Colors.warning
        case .ready: return DS.Colors.success
        case .unavailable: return DS.Colors.destructiveText
        }
    }
}

struct ClickyDashboardCursorSection: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClickyDashboardCard(title: "Cursor behavior", subtitle: "The menu bar no longer owns these detailed controls.") {
                VStack(spacing: 0) {
                    ClickyDashboardControlRow(title: "Show Clicky", subtitle: "Keep the cursor companion visible while the agent runs.", systemImageName: "cursorarrow") {
                        Toggle("", isOn: Binding(
                            get: { companionManager.isClickyCursorEnabled },
                            set: { companionManager.setClickyCursorEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .pointerCursor()
                    }

                    Divider()

                    ClickyDashboardControlRow(title: "Hide when idle", subtitle: "Fade Clicky after the Mac cursor stops moving; reveal it on movement.", systemImageName: "eye.slash") {
                        Toggle("", isOn: Binding(
                            get: { companionManager.shouldHideClickyWhenMacCursorIsIdle },
                            set: { companionManager.setClickyHidesWhenMacCursorIsIdle($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ClickyDashboardMetricCard(title: "Overlay", value: companionManager.isOverlayVisible ? "Visible" : "Hidden", systemImageName: "rectangle.on.rectangle")
                ClickyDashboardMetricCard(title: "Idle fade", value: companionManager.isClickyHiddenBecauseMacCursorIsIdle ? "Hidden by idle" : "Not idle-hidden", systemImageName: "moon")
                ClickyDashboardMetricCard(title: "Voice state", value: voiceStateText, systemImageName: "waveform")
            }
        }
    }

    private var voiceStateText: String {
        switch companionManager.voiceState {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Responding"
        }
    }
}
