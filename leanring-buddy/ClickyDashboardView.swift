//
//  ClickyDashboardView.swift
//  leanring-buddy
//
//  Native SwiftUI control center for Clicky settings, computer-use context,
//  and operational logs.
//

import AppKit
import SwiftUI

private enum ClickyDashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case modelAndVoice
    case cursor
    case computerUse
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .modelAndVoice: return "Model & Voice"
        case .cursor: return "Cursor"
        case .computerUse: return "Computer Use"
        case .logs: return "Logs"
        }
    }

    var systemImageName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .modelAndVoice: return "cpu"
        case .cursor: return "cursorarrow.motionlines"
        case .computerUse: return "macwindow.on.rectangle"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

struct ClickyDashboardView: View {
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var clickyUpdaterManager: ClickyUpdaterManager
    @ObservedObject private var computerUseWindowContextController: CompanionComputerUseWindowContextController

    @State private var selectedSection: ClickyDashboardSection = .overview
    @State private var dashboardPromptInput = ""
    @State private var recentLogEntries: [ClickyMessageLogDisplayEntry] = []
    @State private var focusedWindowPreviewImage: NSImage?
    @State private var focusedWindowCaptureErrorMessage: String?

    init(companionManager: CompanionManager, clickyUpdaterManager: ClickyUpdaterManager) {
        self.companionManager = companionManager
        self.clickyUpdaterManager = clickyUpdaterManager
        self.computerUseWindowContextController = companionManager.computerUseWindowContextController
    }

    var body: some View {
        NavigationSplitView {
            ClickyDashboardSidebar(selectedSection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 188, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ClickyDashboardHeader(
                        title: resolvedSelectedSection.title,
                        subtitle: subtitle(for: resolvedSelectedSection),
                        statusText: dashboardStatusText,
                        statusColor: dashboardStatusColor
                    )

                    detailContent
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(ClickyDashboardBackground())
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 540)
        .task {
            refreshDashboardState()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch resolvedSelectedSection {
        case .overview:
            ClickyDashboardOverviewSection(
                companionManager: companionManager,
                clickyUpdaterManager: clickyUpdaterManager,
                dashboardPromptInput: $dashboardPromptInput,
                submitDashboardPrompt: submitDashboardPrompt,
                refreshAgentState: companionManager.refreshCodingAgentConnectionState,
                checkForUpdates: checkForUpdates
            )
        case .modelAndVoice:
            ClickyDashboardModelAndVoiceSection(companionManager: companionManager)
        case .cursor:
            ClickyDashboardCursorSection(companionManager: companionManager)
        case .computerUse:
            ClickyDashboardComputerUseSection(
                companionManager: companionManager,
                computerUseWindowContextController: computerUseWindowContextController,
                focusedWindowPreviewImage: focusedWindowPreviewImage,
                focusedWindowCaptureErrorMessage: focusedWindowCaptureErrorMessage,
                refreshComputerUseContext: refreshComputerUseContext,
                captureFocusedWindow: captureFocusedWindow
            )
        case .logs:
            ClickyDashboardLogsSection(
                recentLogEntries: recentLogEntries,
                logDirectory: ClickyMessageLogStore.shared.logDirectory,
                refreshLogs: refreshLogs,
                openLogsFolder: openLogsFolder
            )
        }
    }

    private var resolvedSelectedSection: ClickyDashboardSection { selectedSection }

    private var dashboardStatusText: String {
        guard companionManager.isAgentRunning else { return "Paused" }

        if !companionManager.isActiveCodingAgentReady {
            switch companionManager.codexConnectionState {
            case .checking:
                return "Checking Codex"
            case .needsSignIn:
                return "Sign in required"
            case .unavailable:
                return "Codex unavailable"
            case .ready:
                return companionManager.realtimeVoiceStatusText == "Ready" ? "Ready" : "Realtime unavailable"
            }
        }

        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Responding"
        }
    }

    private var dashboardStatusColor: Color {
        guard companionManager.isAgentRunning else { return DS.Colors.textTertiary }

        if !companionManager.isActiveCodingAgentReady {
            switch companionManager.codexConnectionState {
            case .checking:
                return DS.Colors.textTertiary
            case .needsSignIn:
                return DS.Colors.warning
            case .unavailable:
                return DS.Colors.destructiveText
            case .ready:
                return companionManager.realtimeVoiceStatusText == "Ready" ? DS.Colors.success : DS.Colors.warning
            }
        }

        switch companionManager.voiceState {
        case .idle: return DS.Colors.success
        case .listening, .processing, .responding: return DS.Colors.accentText
        }
    }

    private func subtitle(for section: ClickyDashboardSection) -> String {
        switch section {
        case .overview:
            return "Run state, Codex realtime health, and a desktop prompt entry point."
        case .modelAndVoice:
            return "Choose Codex model behavior and realtime voice without crowding the menu bar."
        case .cursor:
            return "Control Clicky's persistent and transient cursor behavior."
        case .computerUse:
            return "Inspect the focused window, AX targets, and native capture context."
        case .logs:
            return "Review structured local events for agent and computer-use debugging."
        }
    }

    private func refreshDashboardState() {
        clickyUpdaterManager.refreshUpdateAvailability()
        companionManager.refreshCodingAgentConnectionState()
        companionManager.refreshComputerUseMCPStatus()
        refreshComputerUseContext()
        refreshLogs()
    }

    private func refreshComputerUseContext() {
        computerUseWindowContextController.refresh(screenContentGranted: companionManager.hasScreenContentPermission)
    }

    private func captureFocusedWindow() {
        focusedWindowCaptureErrorMessage = nil
        Task { @MainActor in
            do {
                let capture = try await computerUseWindowContextController.captureFocusedWindowAsJPEG(
                    screenContentGranted: companionManager.hasScreenContentPermission
                )
                focusedWindowPreviewImage = NSImage(data: capture.imageData)
                refreshLogs()
            } catch {
                focusedWindowCaptureErrorMessage = error.localizedDescription
                refreshLogs()
            }
        }
    }

    private func refreshLogs() {
        recentLogEntries = ClickyMessageLogStore.shared.recentDisplayEntries(limit: 80)
    }

    private func openLogsFolder() {
        NSWorkspace.shared.open(ClickyMessageLogStore.shared.logDirectory)
    }

    private func checkForUpdates() {
        clickyUpdaterManager.checkForUpdates(nil)
    }

    private func submitDashboardPrompt() {
        let trimmedPrompt = dashboardPromptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        dashboardPromptInput = ""
        companionManager.submitTypedPrompt(trimmedPrompt)
        ClickyMessageLogStore.shared.append(
            lane: "dashboard",
            direction: "outgoing",
            event: "dashboard.prompt_submitted",
            fields: ["characterCount": "\(trimmedPrompt.count)"]
        )
    }
}

private struct ClickyDashboardSidebar: View {
    @Binding var selectedSection: ClickyDashboardSection

    var body: some View {
        List(selection: $selectedSection) {
            Section {
                ForEach(ClickyDashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImageName)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Clicky")
        .frame(minWidth: 188)
    }
}

private struct ClickyDashboardHeader: View {
    let title: String
    let subtitle: String
    let statusText: String
    let statusColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.4), radius: 5)

                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 0.5)
            )
        }
    }
}
